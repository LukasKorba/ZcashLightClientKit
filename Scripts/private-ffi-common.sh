# Shared config for the private FFI distribution scripts.
# Sourced by: release-private-ffi.sh, publish-private-sdk-tag.sh, init-local-ffi.sh (--cached-private).
# Not meant to be executed directly -- it has no shebang and is not chmod +x.
#
# This file must NOT set shell options (set -e/-u/pipefail) itself: sourcing it must
# not silently change the calling script's strictness. Each caller is responsible for
# its own `set` line.
#
# PRIVATE_FFI_REPO is the private GitHub repo that hosts prebuilt FULL-flavor
# libzcashlc.xcframework.zip releases (the "private-ffi asset repo" -- distinct from
# the private slipstream ENGINE source repo that private-ffi-mode.sh talks to).
# LukasKorba/zcash-sdk-private-ffi is a PLACEHOLDER: it does not exist yet. This is the
# only place the name is hardcoded, and it's env-overridable so the P5 gates (and any
# future rename) never need to touch the scripts themselves.
PRIVATE_FFI_REPO="${PRIVATE_FFI_REPO:-LukasKorba/zcash-sdk-private-ffi}"

# PRIVATE_FFI_GIT_URL is where publish-private-sdk-tag.sh pushes the SPM-consumable
# <version> tag. It defaults to the ssh form of PRIVATE_FFI_REPO -- git push needs a
# URL, not an "owner/repo" pair, and ssh matches how a maintainer's `gh`/git is already
# authenticated. Override independently of PRIVATE_FFI_REPO when a gate (or a future
# HTTPS-remote setup) needs a different push URL than the gh-api owner/repo pair.
PRIVATE_FFI_GIT_URL="${PRIVATE_FFI_GIT_URL:-git@github.com:${PRIVATE_FFI_REPO}.git}"

# require_private_ffi_access
#
# Verifies the authenticated `gh` account can see $PRIVATE_FFI_REPO, and exits with a
# clear, actionable error if not. A 404 from the GitHub API is ambiguous by design
# (GitHub does not distinguish "exists but you lack access" from "does not exist" for
# private repos, to avoid leaking their existence) -- so the error names both possible
# causes instead of guessing.
require_private_ffi_access() {
    echo "Checking access to the private FFI asset repo ($PRIVATE_FFI_REPO)..."
    if ! gh api "repos/$PRIVATE_FFI_REPO" >/dev/null 2>&1; then
        echo "" >&2
        echo "Error: cannot reach $PRIVATE_FFI_REPO with the current gh account." >&2
        echo "" >&2
        echo "This means one of:" >&2
        echo "  1. Your gh account does not have access to this private repo." >&2
        echo "  2. The repo does not exist yet (PRIVATE_FFI_REPO may still be a placeholder)." >&2
        echo "" >&2
        echo "Ask for access, or override PRIVATE_FFI_REPO with a repo you can reach." >&2
        exit 1
    fi
    echo "Access confirmed."
}
