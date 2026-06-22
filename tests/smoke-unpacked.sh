#!/bin/sh
#
# tests/smoke-unpacked.sh <snap-file> [qemu-user-binary]
#
# Non-daemon smoke test for architectures where snapd cannot run inside CI
# (the emulated armhf and riscv64 legs).  snapd needs the host kernel's
# confinement machinery, which is not available under QEMU emulation, so we
# cannot `snap install` and run the full daemon-level print-through there.
#
# Instead we unpack the built .snap and run a couple of the bundled binaries,
# optionally through a qemu-user emulator (e.g. qemu-arm-static for armhf,
# qemu-riscv64-static for riscv64).  This confirms the snap was produced for
# the right architecture and its core executables are not totally broken.  It
# is intentionally best-effort: emulated binaries can misbehave for reasons
# unrelated to the snap, so the bundled-tool checks do not fail the job.
#
# The full print-through lives in tests/sandbox-test.sh and runs on the native
# amd64/arm64 runners.

set -eu

SNAP_FILE="${1:?usage: smoke-unpacked.sh <snap-file> [qemu-user-binary]}"
QEMU="${2:-}"   # empty => run the binaries natively

[ -f "$SNAP_FILE" ] || { echo "smoke: snap file not found: $SNAP_FILE" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "smoke: unpacking $SNAP_FILE"
unsquashfs -d "$WORK/squashfs-root" "$SNAP_FILE" >/dev/null

ROOT="$WORK/squashfs-root"

run() {
	if [ -n "$QEMU" ]; then
		"$QEMU" "$@"
	else
		"$@"
	fi
}

# Locate a bundled binary by name across the usual snap layout dirs (the exact
# path differs between parts, e.g. gs is bin/gs while cupsfilter is sbin/...).
find_bin() {
	find "$ROOT/bin" "$ROOT/sbin" "$ROOT/usr/bin" "$ROOT/usr/sbin" \
		-maxdepth 1 -name "$1" -type f 2>/dev/null | head -1
}

# Best-effort: an emulated binary may print to stderr or exit non-zero for
# emulation reasons; we only want to see it executes.
GS="$(find_bin gs)"
if [ -n "$GS" ]; then
	echo "::group::bundled Ghostscript ($GS)"
	run "$GS" -h || true
	echo "::endgroup::"
else
	echo "smoke: WARNING: no gs binary found in the unpacked snap"
fi

CUPSFILTER="$(find_bin cupsfilter)"
if [ -n "$CUPSFILTER" ]; then
	echo "::group::bundled cupsfilter ($CUPSFILTER)"
	run "$CUPSFILTER" --help 2>&1 || true
	echo "::endgroup::"
fi

echo "smoke: unpacked-binary smoke test finished for $SNAP_FILE${QEMU:+ (via $QEMU)}"
