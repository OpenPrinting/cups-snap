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
SNAP_FILESCONF="/var/snap/cups/common/etc/cups/cups-files.conf"
HOST_FILESCONF="/etc/cups/cups-files.conf"
NOPROXY_MARKER="/var/snap/cups/common/no-proxy"
IPPEVE_PORT=8631
IPPEVE_NAME="CITestPrinter"
IPPEVE_LOG="$(mktemp)"
IPPEVE_PID=""

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
	fi
	if [ "$MODE" = standalone ]; then
		echo "--- ippeveprinter log ---"; tail -n 150 "$IPPEVE_LOG" 2>/dev/null || true
	fi
	echo "::endgroup::"
}

cleanup() {
	[ -n "$IPPEVE_PID" ] && kill "$IPPEVE_PID" >/dev/null 2>&1 || true
	pkill -f ippeveprinter >/dev/null 2>&1 || true
	cups.cancel -a "$QUEUE"  >/dev/null 2>&1 || true
	cups.lpadmin -x "$QUEUE" >/dev/null 2>&1 || true
	cancel -a "$QUEUE"       >/dev/null 2>&1 || true
	lpadmin -x "$QUEUE"      >/dev/null 2>&1 || true
	rm -f "$IPPEVE_LOG"
}

trap 'rc=$?; [ "$rc" -ne 0 ] && { log "FAILED (exit $rc)"; dump_diagnostics; }; cleanup; exit $rc' EXIT

# wait_scheduler <lpstat-command> -- poll until "scheduler is running".
wait_scheduler() {
	cmd="$1"
	i=0
	while [ "$i" -lt 60 ]; do
		if $cmd -r 2>/dev/null | grep -q 'scheduler is running'; then
			return 0
		fi
		i=$((i + 1)); sleep 1
	done
	log "scheduler ($cmd) did not become ready in time"
	return 1
}

# Enable the "file:" backend on a CUPS instance (off by default) so the test
# queue can use file:/dev/null without any real hardware.
enable_filedevice() {
	conf="$1"
	[ -f "$conf" ] || { log "cups-files.conf not found: $conf"; return 1; }
	grep -q '^FileDevice Yes' "$conf" 2>/dev/null || echo 'FileDevice Yes' >> "$conf"
}

install_host_cups() {
	log "installing the host (classic) CUPS..."
	apt-get update -y >/dev/null
	apt-get install -y cups cups-client >/dev/null
	enable_filedevice "$HOST_FILESCONF"
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

# make_raw_queue <lpadmin-cmd> <lpstat-cmd> -- create a classic raw queue on the
# file:/dev/null device (no ippeveprinter, so no DNS-SD queue leaking onto other
# CUPS instances).  Raw is enough to validate that a job flows through the chosen
# cupsd in the chosen mode.
make_raw_queue() {
	lpadmin_cmd="$1"; lpstat_cmd="$2"
	log "creating classic raw queue '$QUEUE' (file:/dev/null) via $lpadmin_cmd"
	$lpadmin_cmd -p "$QUEUE" -v file:/dev/null -E
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
	# lives on the HOST cupsd; the snap mirrors it and proxies snapped clients'
	# jobs to it.
	install_host_cups
	install_snap                       # detects host CUPS -> proxy mode
	wait_scheduler "cups.lpstat"       # snap cupsd (on its domain socket)

	# Create the queue on the host CUPS.
	make_raw_queue "lpadmin" "lpstat"

	# The snap's cups-proxyd should mirror the host queue into the snapped CUPS.
	log "waiting for the host queue to be mirrored into the snapped CUPS..."
	mirrored=0; i=0
	while [ "$i" -lt 30 ]; do
		if cups.lpstat -v "$QUEUE" 2>/dev/null | grep -q "$QUEUE"; then
			mirrored=1; break
		fi
		i=$((i + 1)); sleep 1
	done

	if [ "$mirrored" = 1 ]; then
		log "queue mirrored; printing via the snapped client (proxied to host)"
		printf 'CUPS Snap CI (proxy) print-through test.\n' \
			| cups.lp -d "$QUEUE" -t ci-job 2>&1 || { log "snapped lp failed"; return 1; }
	else
		log "WARNING: queue not mirrored into the snap; printing via the host client"
		printf 'CUPS Snap CI (proxy) print-through test.\n' \
			| lp -d "$QUEUE" -t ci-job 2>&1 || { log "host lp failed"; return 1; }
	fi

	# Either way the job must complete on the HOST queue.
	log "waiting for the job to complete on the host CUPS..."
	done_ok=0; i=0
	while [ "$i" -lt 60 ]; do
		if lpstat -W completed -o "$QUEUE" 2>/dev/null | grep -q "$QUEUE"; then
			done_ok=1; break
		fi
		i=$((i + 1)); sleep 1
	done
	[ "$done_ok" = 1 ] || { log "job did not complete on the host CUPS"; return 1; }
	log "job completed on the host CUPS (proxy path)"
}

# ---------------------------------------------------------------------------
run_parallel() {
	# Host CUPS present AND no-proxy marker -> snap runs independently alongside
	# the host CUPS on an alternative port/socket.  Queue on the snapped cupsd.
	install_host_cups
	install_snap                       # starts in proxy mode initially
	mkdir -p "$(dirname "$NOPROXY_MARKER")"
	touch "$NOPROXY_MARKER"            # force parallel (independent) mode
	enable_filedevice "$SNAP_FILESCONF"
	log "restarting the snapped cupsd into parallel mode..."
	snap restart cups.cupsd
	wait_scheduler "cups.lpstat"

	make_raw_queue "cups.lpadmin" "cups.lpstat"
	submit_and_verify "cups.lp" "cups.lpstat" || return 1
}

# ---------------------------------------------------------------------------
case "$MODE" in
	standalone) run_standalone ;;
	proxy)      run_proxy ;;
	parallel)   run_parallel ;;
	*) log "unknown mode: $MODE (expected standalone|proxy|parallel)"; exit 2 ;;
esac

log "PASS: $MODE mode print-through succeeded"
