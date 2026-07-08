#!/bin/bash
# Switch the root Cargo manifest/lock between the public STUB default and the private-access
# FULL overlay.
# Usage: ./Scripts/private-ffi-mode.sh {enable|disable|status}
#
# STUB (default, committed state): Cargo.toml/Cargo.lock have zero references to the
# private https://github.com/LukasKorba/slipstream repository. `slipstream_ffi_stubs.rs`
# stands in for `slipstream_ffi.rs` -- every zcashlc_slipstream_* FFI entry point reports
# "engine not available", nothing else changes. Anyone can build this without credentials.
#
# FULL (opt-in, requires git access to the private repo): swaps in Cargo-slipstream.toml /
# Cargo-slipstream.lock, which add the `slipstream-core` dependency, the [patch.crates-io]
# vendored-fork patches, and the `slipstream`/`gpu` cargo features. Only people/CI with
# access to the private repo can resolve or build in this mode.
#
# Commands:
#   enable   Verify private-repo git access, then switch Cargo.toml/Cargo.lock to FULL.
#   disable  Restore the committed public/STUB Cargo.toml/Cargo.lock (git checkout --).
#            This discards any uncommitted edits to those two files, by design -- the
#            committed state IS the public state.
#   status   Print FULL or STUB depending on the current Cargo.toml.
#
# Tripwire: never commit with FULL mode enabled. There is no pre-commit hook enforcing
# this -- the natural enforcement is that zcash CI clones fresh (no private-repo
# credentials) and goes red the moment Cargo.toml/Cargo.lock reference the private repo.
# Run `status` before committing manifest/lock changes if you're unsure which mode you're in.

set -euo pipefail
cd "$(dirname "$0")/.."

PUBLIC_REPO_MARKER="LukasKorba/slipstream"
PRIVATE_REMOTE="git@github.com:LukasKorba/slipstream"
OVERLAY_TOML="Cargo-slipstream.toml"
OVERLAY_LOCK="Cargo-slipstream.lock"

usage() {
    if [[ -n "${1:-}" ]]; then
        echo "Error: $1" >&2
        echo "" >&2
    fi
    cat >&2 << 'USAGEEOF'
Usage: ./Scripts/private-ffi-mode.sh {enable|disable|status}

  enable   Verify private-repo git access, then switch Cargo.toml/Cargo.lock to FULL
           (Cargo-slipstream.toml / Cargo-slipstream.lock).
  disable  Restore the committed public/STUB Cargo.toml/Cargo.lock (git checkout --).
  status   Print FULL or STUB depending on the current Cargo.toml.
USAGEEOF
    exit 1
}

cmd_enable() {
    if [[ ! -f "$OVERLAY_TOML" || ! -f "$OVERLAY_LOCK" ]]; then
        echo "Error: $OVERLAY_TOML / $OVERLAY_LOCK not found in $(pwd)." >&2
        echo "This checkout may predate the manifest split, or you're not at the repo root." >&2
        exit 1
    fi

    echo "Checking git access to the private slipstream engine repository..."
    if ! git ls-remote "$PRIVATE_REMOTE" >/dev/null; then
        echo "" >&2
        echo "Error: no git access to $PRIVATE_REMOTE." >&2
        echo "FULL mode requires SSH access to the private slipstream engine repository." >&2
        echo "If you don't have access, stay on STUB mode (the default) -- the SDK builds," >&2
        echo "tests, and releases fully without it." >&2
        exit 1
    fi

    cp "$OVERLAY_TOML" Cargo.toml
    cp "$OVERLAY_LOCK" Cargo.lock
    echo "Switched to FULL mode (Cargo.toml/Cargo.lock now reference the private engine repo)."
    echo "Run './Scripts/private-ffi-mode.sh disable' before committing to return to STUB."
}

cmd_disable() {
    git checkout -- Cargo.toml Cargo.lock
    echo "Switched to STUB mode (restored the committed public Cargo.toml/Cargo.lock)."
}

cmd_status() {
    if grep -q "$PUBLIC_REPO_MARKER" Cargo.toml; then
        echo "FULL"
    else
        echo "STUB"
    fi
}

if [[ $# -ne 1 ]]; then
    usage
fi

case "$1" in
    enable)
        cmd_enable
        ;;
    disable)
        cmd_disable
        ;;
    status)
        cmd_status
        ;;
    *)
        usage "Unknown command: $1"
        ;;
esac
