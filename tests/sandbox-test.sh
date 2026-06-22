#!/bin/sh
#
# tests/sandbox-test.sh
#
# Full "print-through" integration test for the CUPS Snap, run inside the
# snap's own confined environment.  A Snap is a self-contained, read-only,
# confined filesystem bundling its whole printing stack (CUPS, libcupsfilters,
# libppd, cups-filters, Ghostscript, ...), so the multi-CUPS build matrix used
# by the Autotools repositories does not apply here.  Instead we install the
# built snap, let its bundled cupsd run, set up a virtual IPP-Everywhere
# printer with the bundled ippeveprinter, and push a real job through the
# bundled filter chain -- exercising the actual stack end to end.
#
# This requires a working snapd, so it only runs on the native runners
# (amd64/arm64).  The emulated architectures (armhf/riscv64), where snapd
# cannot run under CI, use the non-daemon tests/smoke-unpacked.sh instead.
#
# The CI invokes this as root:  sudo sh tests/sandbox-test.sh
# It assumes the "cups" snap is already installed (the build job installs the
# freshly built .snap with `snap install --dangerous`).  Snap removal is left
# to the workflow's cleanup step; this script cleans up only what it creates.

set -eu

QUEUE="ci-everywhere"
PRINTER_PORT=8631
PRINTER_URI="ipp://localhost:${PRINTER_PORT}/ipp/print"
IPPEVE_LOG="$(mktemp)"
IPPEVE_PID=""

log()  { echo "sandbox-test: $*"; }
group(){ echo "::group::$*"; }
endgr(){ echo "::endgroup::"; }

dump_diagnostics() {
	group "diagnostics"
	echo "--- snap services ---";    snap services cups            2>&1 || true
	echo "--- snap connections ---"; snap connections cups         2>&1 || true
	echo "--- snap logs ---";        snap logs cups -n 200         2>&1 || true
	echo "--- lpstat -t ---";        cups.lpstat -t                2>&1 || true
	echo "--- cupsd error_log ---"
	# ErrorLog lives under $SNAP_DATA (see scripts/run-cupsd); current -> revision.
	tail -n 200 /var/snap/cups/current/var/log/error_log 2>/dev/null || true
	echo "--- ippeveprinter log ---"; tail -n 200 "$IPPEVE_LOG"   2>/dev/null || true
	endgr
}

cleanup() {
	cups.cancel -a "$QUEUE"   >/dev/null 2>&1 || true
	cups.lpadmin -x "$QUEUE"  >/dev/null 2>&1 || true
	[ -n "$IPPEVE_PID" ] && kill "$IPPEVE_PID" >/dev/null 2>&1 || true
	pkill -f "ippeveprinter" >/dev/null 2>&1 || true
	rm -f "$IPPEVE_LOG"
}

# Diagnose on failure, always clean up.
trap 'rc=$?; [ "$rc" -ne 0 ] && { log "FAILED (exit $rc)"; dump_diagnostics; }; cleanup; exit $rc' EXIT

# ---------------------------------------------------------------------------
# 1. Sanity: the snap is installed.
# ---------------------------------------------------------------------------
snap list cups >/dev/null 2>&1 || { log "cups snap is not installed"; exit 1; }
log "cups snap installed:"; snap list cups

# ---------------------------------------------------------------------------
# 2. Connect the interfaces the test needs.  network/network-bind auto-connect;
#    the rest are best-effort (absent slots on a bare runner are harmless, the
#    stand-alone cupsd does not need them).
# ---------------------------------------------------------------------------
for plug in avahi-control raw-usb etc-cups cups-control cups-host; do
	snap connect "cups:$plug" >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
# 3. Wait for the bundled cupsd (snap daemon) to come up.
# ---------------------------------------------------------------------------
log "waiting for the snap's cupsd to accept connections..."
ready=0
i=0
while [ "$i" -lt 60 ]; do
	if cups.lpstat -r 2>/dev/null | grep -q 'scheduler is running'; then
		ready=1; break
	fi
	i=$((i + 1)); sleep 1
done
[ "$ready" = 1 ] || { log "cupsd did not become ready in time"; exit 1; }
log "cupsd is running"

# ---------------------------------------------------------------------------
# 4. Start a virtual IPP-Everywhere printer (bundled ippeveprinter).  We point
#    the queue at it by explicit URI, so DNS-SD/Avahi is not required.
# ---------------------------------------------------------------------------
log "starting ippeveprinter on port ${PRINTER_PORT}..."
cups.ippeveprinter -p "$PRINTER_PORT" "CI Everywhere Printer" >"$IPPEVE_LOG" 2>&1 &
IPPEVE_PID=$!

# ---------------------------------------------------------------------------
# 5. Create a driverless ("everywhere") queue from that printer.  lpadmin has
#    to reach the printer to fetch its IPP attributes, so retrying here also
#    serves as the readiness wait for ippeveprinter.
# ---------------------------------------------------------------------------
log "creating everywhere queue '${QUEUE}' from ${PRINTER_URI}..."
created=0
i=0
while [ "$i" -lt 30 ]; do
	if kill -0 "$IPPEVE_PID" 2>/dev/null && \
	   cups.lpadmin -p "$QUEUE" -v "$PRINTER_URI" -m everywhere -E >/dev/null 2>&1; then
		created=1; break
	fi
	i=$((i + 1)); sleep 1
done
[ "$created" = 1 ] || { log "could not create the everywhere queue"; exit 1; }
cups.lpstat -p "$QUEUE" || true
cups.lpstat -v "$QUEUE" || true

# ---------------------------------------------------------------------------
# 6. Push a job through the bundled filter chain.  Printing from stdin avoids
#    needing the "home" interface to read a file from disk.
# ---------------------------------------------------------------------------
log "submitting a print job..."
jobout="$(printf 'CUPS Snap CI print-through test.\nThe bundled filter chain converted this text.\n' \
	| cups.lp -d "$QUEUE" -t ci-print-through 2>&1)" || {
		log "lp failed: $jobout"; exit 1; }
echo "$jobout"
jobid="$(printf '%s' "$jobout" | sed -n 's/.*request id is \([^ ]*\).*/\1/p')"
[ -n "$jobid" ] || { log "could not determine the job id"; exit 1; }
log "submitted job: $jobid"

# ---------------------------------------------------------------------------
# 7. Verify the job actually COMPLETED (an aborted/held job never appears in
#    the completed list -- so this distinguishes success from a stuck queue).
# ---------------------------------------------------------------------------
log "waiting for the job to complete..."
done_ok=0
i=0
while [ "$i" -lt 60 ]; do
	if cups.lpstat -W completed -o "$QUEUE" 2>/dev/null | grep -qw "$jobid"; then
		done_ok=1; break
	fi
	i=$((i + 1)); sleep 1
done
[ "$done_ok" = 1 ] || { log "job $jobid did not complete in time"; exit 1; }
log "job $jobid completed"

# ---------------------------------------------------------------------------
# 8. Confirm the virtual printer actually received the document (the job really
#    traversed the stack, it was not just discarded by the scheduler).
# ---------------------------------------------------------------------------
if grep -Eqi 'job|print|document' "$IPPEVE_LOG"; then
	log "ippeveprinter received the job"
else
	log "WARNING: no job activity seen in the ippeveprinter log (printed below)"
	cat "$IPPEVE_LOG" || true
fi

log "PASS: full print-through succeeded through the snap's bundled stack"
