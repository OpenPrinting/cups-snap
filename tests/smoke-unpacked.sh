#!/bin/sh
#
# tests/smoke-unpacked.sh <snap-file> [qemu-user-binary]
#
# Non-daemon verification for the architectures where the full print-through
# cannot run inside CI: the emulated armhf and riscv64 legs.  Two things block
# the daemon-level test there:
#   1. snapd needs the host kernel's confinement machinery, unavailable under
#      QEMU emulation, so we cannot `snap install` and run the bundled cupsd.
#   2. The snap's executables are dynamically linked against the base-snap
#      (core22) runtime, which is not inside the .snap, so they cannot even be
#      run reliably under qemu-user (the loader/libs are missing) -- attempts
#      just fail with "Could not open .../ld-linux-*.so".
#
# So instead of pretending to "run" them (which silently no-ops), we verify the
# artifact STATICALLY: the snap unpacks, the key executables are present, and
# they are ELF binaries of the expected cross-architecture.  That reliably
# catches a build that produced the wrong architecture or is missing core
# components -- which is the real risk for an emulated build.
#
# The full daemon-level print-through lives in tests/sandbox-test.sh and runs on
# the native amd64/arm64 runners.

set -eu

SNAP_FILE="${1:?usage: smoke-unpacked.sh <snap-file> [qemu-user-binary]}"
QEMU="${2:-}"   # used only to derive the expected arch + a best-effort run

[ -f "$SNAP_FILE" ] || { echo "smoke: snap file not found: $SNAP_FILE" >&2; exit 1; }

# Expected architecture token in file(1) output, derived from the qemu-user name.
case "$QEMU" in
	*riscv64*)        ARCH_TOKEN="RISC-V" ;;
	*aarch64*|*arm64*) ARCH_TOKEN="aarch64" ;;
	*arm*)            ARCH_TOKEN="ARM" ;;
	*)                ARCH_TOKEN="" ;;   # native / unknown: don't assert a token
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "smoke: unpacking $SNAP_FILE"
unsquashfs -d "$WORK/squashfs-root" "$SNAP_FILE" >/dev/null
ROOT="$WORK/squashfs-root"

# Locate a bundled binary by name across the usual snap layout dirs (the exact
# path differs between parts, e.g. gs is bin/gs while cupsd is sbin/cupsd).
find_bin() {
	find "$ROOT/bin" "$ROOT/sbin" "$ROOT/usr/bin" "$ROOT/usr/sbin" \
		-maxdepth 1 -name "$1" -type f 2>/dev/null | head -1
}

# Verify a bundled binary exists and is an ELF of the expected architecture.
# Fails the job on a missing binary, a non-ELF, or a wrong-architecture build.
check_bin() {
	name="$1"; required="$2"
	path="$(find_bin "$name")"
	if [ -z "$path" ]; then
		if [ "$required" = required ]; then
			echo "smoke: ERROR: required binary '$name' not found in the snap" >&2
			exit 1
		fi
		echo "smoke: note: optional binary '$name' not present"
		return 0
	fi

	desc="$(file -b "$path")"
	echo "smoke: $name -> $desc"

	case "$desc" in
		*ELF*) : ;;
		*) echo "smoke: ERROR: '$name' is not an ELF executable" >&2; exit 1 ;;
	esac

	# These are cross-architecture legs, so the bundled binary must NOT be the
	# x86-64 host architecture.
	case "$desc" in
		*x86-64*) echo "smoke: ERROR: '$name' is x86-64, expected a cross build" >&2; exit 1 ;;
	esac

	if [ -n "$ARCH_TOKEN" ]; then
		case "$desc" in
			*"$ARCH_TOKEN"*) : ;;
			*) echo "smoke: ERROR: '$name' is not $ARCH_TOKEN as expected" >&2; exit 1 ;;
		esac
	fi
}

echo "::group::architecture verification${ARCH_TOKEN:+ (expecting $ARCH_TOKEN)}"
check_bin gs        required    # bundled Ghostscript
check_bin cupsd     required    # the CUPS scheduler
check_bin cupsfilter optional   # a representative filter-chain entry point
echo "::endgroup::"

# Best-effort, informational only: if a matching userspace happens to be present
# the binary may run; we never fail the job on this (the loader is normally
# absent under qemu-user for a snap's binaries).
if [ -n "$QEMU" ] && command -v "$QEMU" >/dev/null 2>&1; then
	GS="$(find_bin gs)"
	if [ -n "$GS" ]; then
		echo "::group::best-effort: $QEMU gs -h"
		"$QEMU" "$GS" -h 2>&1 | head -5 || true
		echo "::endgroup::"
	fi
fi

echo "smoke: verification passed for $SNAP_FILE${QEMU:+ ($ARCH_TOKEN)}"
