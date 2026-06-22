#!/bin/sh
#
# tests/sandbox-test.sh <standalone|proxy|parallel> <snap-file>
#
# Integration test for the CUPS Snap, exercising the three operating modes its
# run-cupsd selects between (see scripts/run-cupsd):
#
#   standalone  no system CUPS on the host -> the snap's cupsd is THE system
#               CUPS (port 631 + standard socket).  Queue on the snapped cupsd.
#   proxy       a classic system CUPS is installed and there is no `no-proxy`
#               marker -> the snap runs cups-proxyd and mirrors the host's
#               queues; snapped clients' jobs are proxied to the host CUPS.
#               Queue on the HOST cupsd.
#   parallel    a classic system CUPS is installed AND the `no-proxy` marker
#               exists -> the snap's cupsd runs independently on an alternative
#               port/socket alongside the host's.  Queue on the snapped cupsd.
#
# A Snap bundles its whole printing stack at pinned versions, so the multi-CUPS
# build matrix used by the Autotools repos does not apply; what matters here is
# that the snapped cupsd behaves correctly in each mode.  This runs only on the
# native runners (snapd needs the host kernel); the emulated armhf/riscv64 legs
# use tests/smoke-unpacked.sh instead.
#
# Invoked by CI as root:  sudo sh tests/sandbox-test.sh <mode> <snap-file>
# Each mode runs in its own fresh job, so this script provisions whatever that
# mode needs (host CUPS / no-proxy marker / Avahi) and installs the snap itself.
#
# NB: the snap's scripts/run-util execs the utilities via unquoted `$*`, so it
# word-splits every argument -- no value passed to a cups.* command may contain
# spaces.

set -eu

MODE="${1:?usage: sandbox-test.sh <standalone|proxy|parallel> <snap-file>}"
SNAP_FILE="${2:?usage: sandbox-test.sh <standalone|proxy|parallel> <snap-file>}"

QUEUE="ci-test"
# Generic PostScript PPD shipped next to this script.  cups-proxyd cannot clone
# a raw queue (it needs a PPD), so the proxy test creates the host queue with it.
GENERIC_PPD="$(dirname "$0")/ci-generic.ppd"
NOPROXY_MARKER="/var/snap/cups/common/no-proxy"
IPPEVE_PORT=8631
IPPEVE_NAME="CITestPrinter"
IPPEVE_LOG="$(mktemp)"
IPPEVE_PID=""

# Minimal "network printer": nc captures the AppSocket/JetDirect data the queue
# sends on this port into PRINT_OUTPUT.  This replaces the file: backend, which
# newer CUPS (2.4.x onwards) no longer provides.
SOCKET_PORT=9100
PRINTER_URI="socket://localhost:${SOCKET_PORT}/"
PRINT_OUTPUT="$(mktemp)"
NC_PID=""

export DEBIAN_FRONTEND=noninteractive

log()  { echo "sandbox-test[$MODE]: $*"; }

dump_diagnostics() {
	echo "::group::diagnostics ($MODE)"
	echo "--- snap services ---";    snap services cups    2>&1 || true
	echo "--- snap connections ---"; snap connections cups 2>&1 || true
	echo "--- snap logs ---";        snap logs cups -n 200 2>&1 || true
	echo "--- snapped lpstat -t ---"; cups.lpstat -t       2>&1 || true
	echo "--- snap cupsd error_log ---"
	tail -n 150 /var/snap/cups/current/var/log/error_log 2>/dev/null || true
	if [ "$MODE" != standalone ]; then
		echo "--- host lpstat -t ---"; lpstat -t           2>&1 || true
		echo "--- host cupsd error_log ---"
		tail -n 150 /var/log/cups/error_log 2>/dev/null || true
		echo "--- cups-proxyd log ---"
		tail -n 150 /var/snap/cups/current/var/log/cups-proxyd_log 2>/dev/null || true
	fi
	if [ "$MODE" = standalone ]; then
		echo "--- ippeveprinter log ---"; tail -n 150 "$IPPEVE_LOG" 2>/dev/null || true
	fi
	echo "::endgroup::"
}

cleanup() {
	[ -n "$IPPEVE_PID" ] && kill "$IPPEVE_PID" >/dev/null 2>&1 || true
	pkill -f ippeveprinter >/dev/null 2>&1 || true
	[ -n "$NC_PID" ] && kill "$NC_PID" >/dev/null 2>&1 || true
	pkill -f "nc -l -k $SOCKET_PORT" >/dev/null 2>&1 || true
	cups.cancel -a "$QUEUE"  >/dev/null 2>&1 || true
	cups.lpadmin -x "$QUEUE" >/dev/null 2>&1 || true
	cancel -a "$QUEUE"       >/dev/null 2>&1 || true
	lpadmin -x "$QUEUE"      >/dev/null 2>&1 || true
	rm -f "$IPPEVE_LOG" "$PRINT_OUTPUT"
}

trap 'rc=$?; [ "$rc" -ne 0 ] && { log "FAILED (exit $rc)"; dump_diagnostics; }; cleanup; exit $rc' EXIT

# wait_scheduler <lpstat-command> -- poll until the scheduler is reachable.
# Use the exit code of `lpstat -r` (0 when the scheduler is running), not its
# printed message, which may change in future CUPS versions.
wait_scheduler() {
	cmd="$1"
	i=0
	while [ "$i" -lt 60 ]; do
		if $cmd -r >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1)); sleep 1
	done
	log "scheduler ($cmd) did not become ready in time"
	return 1
}

install_host_cups() {
	log "installing the host (classic) CUPS..."
	apt-get update -y >/dev/null
	apt-get install -y cups cups-client >/dev/null
	systemctl restart cups 2>/dev/null || service cups restart || true
	wait_scheduler "lpstat"
}

install_snap() {
	log "installing the snap under test: $SNAP_FILE"
	snap install --dangerous "$SNAP_FILE"
	snap list cups
	# network/network-bind auto-connect; the rest are best-effort.
	for plug in avahi-control raw-usb etc-cups cups-control cups-host home; do
		snap connect "cups:$plug" >/dev/null 2>&1 || true
	done
}

# start_socket_printer -- a one-line network printer: accept the (filtered) job
# data on SOCKET_PORT with nc and save it to PRINT_OUTPUT.  Gives the test a real,
# hardware-free print sink plus a verifiable artifact, and avoids the file:
# backend (gone in newer CUPS) entirely.
start_socket_printer() {
	command -v nc >/dev/null 2>&1 || apt-get install -y netcat-openbsd >/dev/null
	log "starting socket printer on port $SOCKET_PORT (nc)..."
	nc -l -k "$SOCKET_PORT" > "$PRINT_OUTPUT" 2>/dev/null &
	NC_PID=$!
	i=0
	while [ "$i" -lt 30 ]; do
		ss -ltn 2>/dev/null | grep -q ":$SOCKET_PORT" && return 0
		kill -0 "$NC_PID" 2>/dev/null || { log "socket printer (nc) exited at startup"; return 1; }
		i=$((i + 1)); sleep 1
	done
	log "socket printer did not start listening in time"
	return 1
}

# verify_output -- confirm the socket printer actually received print data.
verify_output() {
	if [ -s "$PRINT_OUTPUT" ]; then
		log "socket printer captured $(wc -c < "$PRINT_OUTPUT") bytes of print data"
	else
		log "WARNING: socket printer captured no data"
	fi
}

# make_raw_queue <lpadmin-cmd> <lpstat-cmd> -- create a classic raw queue on the
# socket printer (no ippeveprinter, so no DNS-SD queue leaking onto other CUPS
# instances).  Raw is enough to validate that a job flows through the chosen
# cupsd in the chosen mode.
make_raw_queue() {
	lpadmin_cmd="$1"; lpstat_cmd="$2"
	log "creating classic raw queue '$QUEUE' ($PRINTER_URI) via $lpadmin_cmd"
	$lpadmin_cmd -p "$QUEUE" -v "$PRINTER_URI" -E
	$lpstat_cmd -p "$QUEUE" || true
	$lpstat_cmd -v "$QUEUE" || true
}

# submit_and_verify <lp-cmd> <lpstat-cmd> -- print a stdin job and confirm it
# reaches the completed list (an aborted/stuck job never appears there).
submit_and_verify() {
	lp_cmd="$1"; lpstat_cmd="$2"
	log "submitting a print job via $lp_cmd..."
	jobout="$(printf 'CUPS Snap CI (%s) print-through test.\n' "$MODE" \
		| $lp_cmd -d "$QUEUE" -t ci-job 2>&1)" || { log "lp failed: $jobout"; return 1; }
	echo "$jobout"

	i=0
	while [ "$i" -lt 60 ]; do
		if $lpstat_cmd -W completed -o "$QUEUE" 2>/dev/null | grep -q "$QUEUE"; then
			log "job completed on $lp_cmd's queue"
			return 0
		fi
		i=$((i + 1)); sleep 1
	done
	log "job did not complete in time"
	return 1
}

# ---------------------------------------------------------------------------
run_standalone() {
	# Single CUPS instance -> ippeveprinter is safe (no other CUPS to pollute),
	# so use it for a richer driverless print-through through the filter chain.
	apt-get update -y >/dev/null
	apt-get install -y avahi-daemon avahi-utils dbus >/dev/null
	systemctl start dbus 2>/dev/null || service dbus start || true
	systemctl start avahi-daemon 2>/dev/null || service avahi-daemon start || true

	install_snap
	wait_scheduler "cups.lpstat"

	log "starting ippeveprinter '$IPPEVE_NAME' on port $IPPEVE_PORT..."
	cups.ippeveprinter -p "$IPPEVE_PORT" "$IPPEVE_NAME" >"$IPPEVE_LOG" 2>&1 &
	IPPEVE_PID=$!

	log "creating everywhere queue '$QUEUE'..."
	created=0; i=0
	while [ "$i" -lt 30 ]; do
		if ! kill -0 "$IPPEVE_PID" 2>/dev/null; then
			log "ippeveprinter exited unexpectedly; its output was:"
			cat "$IPPEVE_LOG" 2>/dev/null || true
			return 1
		fi
		if cups.lpadmin -p "$QUEUE" -v "ipp://localhost:$IPPEVE_PORT/ipp/print" \
				-m everywhere -E >/dev/null 2>&1; then
			created=1; break
		fi
		i=$((i + 1)); sleep 1
	done
	[ "$created" = 1 ] || { log "could not create the everywhere queue"; return 1; }

	submit_and_verify "cups.lp" "cups.lpstat" || return 1

	if grep -Eqi 'job|print|document' "$IPPEVE_LOG"; then
		log "ippeveprinter received the job"
	else
		log "WARNING: no job activity seen in the ippeveprinter log"
	fi
}

# ---------------------------------------------------------------------------
run_proxy() {
	# Host CUPS present, no no-proxy marker -> snap runs as a proxy.  The queue
	# lives on the HOST cupsd; the snap's cups-proxyd mirrors it into the snapped
	# CUPS and the snapped client's job is proxied to the host.
	install_host_cups
	# dbus lets the host CUPS deliver live add/remove notifications to
	# cups-proxyd (belt and suspenders alongside its start-up sync below).
	systemctl start dbus 2>/dev/null || service dbus start || true
	start_socket_printer

	# Create the queue on the host CUPS *before* cups-proxyd starts, so its
	# start-up "sync with current state" (see cups-proxyd.c) mirrors an already
	# existing queue -- rather than relying on a live notification.  Use a PPD
	# (not a raw queue): cups-proxyd cannot clone raw queues ("Unable to load
	# PPD ... Bad Request"), it needs the PPD to replicate the queue.
	log "creating classic PPD queue '$QUEUE' on the host ($PRINTER_URI)..."
	[ -f "$GENERIC_PPD" ] || { log "generic PPD not found: $GENERIC_PPD"; return 1; }
	lpadmin -p "$QUEUE" -P "$GENERIC_PPD" -v "$PRINTER_URI" -E
	lpstat -p "$QUEUE" || true
	lpstat -v "$QUEUE" || true

	install_snap                       # snap detects host CUPS -> proxy mode
	# cups-proxyd is spawned by run-cupsd, but at first install it started before
	# the cups-host plug was connected (so it could not reach the host CUPS).
	# Restart now that cups-host is connected and the host queue exists, so its
	# start-up sync mirrors the queue.
	log "restarting the snapped cupsd so cups-proxyd syncs the host queues..."
	snap restart cups.cupsd
	wait_scheduler "cups.lpstat"       # snap cupsd (on its domain socket)

	# Require the host queue to be mirrored into the snapped CUPS (proxy:// device).
	log "waiting for the host queue to be mirrored into the snapped CUPS..."
	mirrored=0; i=0
	while [ "$i" -lt 60 ]; do
		if cups.lpstat -v "$QUEUE" 2>/dev/null | grep -q "$QUEUE"; then
			mirrored=1; break
		fi
		i=$((i + 1)); sleep 1
	done
	[ "$mirrored" = 1 ] || { log "host queue was not mirrored into the snap by cups-proxyd"; return 1; }
	log "queue mirrored into the snapped CUPS:"; cups.lpstat -v "$QUEUE" || true

	# Print via the SNAPPED client; the job must traverse the proxy to the host.
	log "printing via the snapped client (job is proxied to the host CUPS)..."
	printf 'CUPS Snap CI (proxy) print-through test.\n' \
		| cups.lp -d "$QUEUE" -t ci-job 2>&1 || { log "snapped lp failed"; return 1; }

	# The job must complete on the HOST queue (proves the proxy path end to end).
	log "waiting for the proxied job to complete on the host CUPS..."
	done_ok=0; i=0
	while [ "$i" -lt 60 ]; do
		if lpstat -W completed -o "$QUEUE" 2>/dev/null | grep -q "$QUEUE"; then
			done_ok=1; break
		fi
		i=$((i + 1)); sleep 1
	done
	[ "$done_ok" = 1 ] || { log "proxied job did not complete on the host CUPS"; return 1; }
	log "proxied job completed on the host CUPS (proxy path verified)"
	verify_output
}

# ---------------------------------------------------------------------------
run_parallel() {
	# Host CUPS present AND no-proxy marker -> snap runs independently alongside
	# the host CUPS on an alternative port/socket.  Queue on the snapped cupsd.
	install_host_cups
	install_snap                       # starts in proxy mode initially
	# Wait for the snap's first-run init to create cups-files.conf before we edit
	# it (the file appears only once the snapped cupsd has started).
	wait_scheduler "cups.lpstat"
	mkdir -p "$(dirname "$NOPROXY_MARKER")"
	touch "$NOPROXY_MARKER"            # force parallel (independent) mode
	log "restarting the snapped cupsd into parallel mode..."
	snap restart cups.cupsd
	wait_scheduler "cups.lpstat"

	start_socket_printer
	make_raw_queue "cups.lpadmin" "cups.lpstat"
	submit_and_verify "cups.lp" "cups.lpstat" || return 1
	verify_output
}

# ---------------------------------------------------------------------------
case "$MODE" in
	standalone) run_standalone ;;
	proxy)      run_proxy ;;
	parallel)   run_parallel ;;
	*) log "unknown mode: $MODE (expected standalone|proxy|parallel)"; exit 2 ;;
esac

log "PASS: $MODE mode print-through succeeded"
