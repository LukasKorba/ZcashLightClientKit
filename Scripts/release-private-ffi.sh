#!/bin/bash
# Build the FULL-flavor libzcashlc XCFramework and publish it as a GitHub release on
# the private FFI asset repo ($PRIVATE_FFI_REPO, see private-ffi-common.sh).
# Usage: ./Scripts/release-private-ffi.sh [--force-overwrite-existing-release] <version>
#
# This is the private-distribution twin of prepare-release.sh: same build + zip +
# checksum shape, but it publishes to a private, asset-only repo instead of the public
# SDK repo. Unlike prepare-release.sh, it does NOT create a release branch or touch
# this repo's Package.swift -- wiring up a consumer branch is cut-private-release.sh's
# job, run separately (it's the thing that actually points at a specific asset).
#
# Flow:
#   1. Verify access to $PRIVATE_FFI_REPO (require_private_ffi_access) -- before
#      anything else changes, so a missing-access failure never starts a build.
#   2. Record the current slipstream-ffi mode (STUB or FULL) and switch to FULL
#      (slipstream-ffi-mode.sh enable), restoring whatever mode was active beforehand
#      on exit via a trap -- the tree never stays in FULL mode by accident, even if
#      this script fails partway through.
#   3. Ensure the 5 Apple Rust targets are installed (idempotent).
#   4. make clean && make xcframework in BuildSupport/ (all 5 architectures; FULL
#      flavor, since the manifest now pulls in the real slipstream-core engine).
#   5. zip + sha256 the xcframework.
#   6. gh release create (or --clobber upload with --force-overwrite-existing-release)
#      on $PRIVATE_FFI_REPO, tag == version.
#   7. Read back the numeric asset ID -- the URL SwiftPM needs encodes this ID, not the
#      tag or filename, and it changes on every re-upload (spec risk 7).
#   8. Write BuildSupport/products/private-release.env and print the Package.swift
#      snippet plus the cut-private-release.sh next step.
#
# Options:
#   --force-overwrite-existing-release  Allow overwriting an existing release (--clobber).
#
# Prerequisites:
#   - gh CLI installed and authenticated, with access to $PRIVATE_FFI_REPO
#   - git access to the private slipstream ENGINE repo (slipstream-ffi-mode.sh enable) --
#     a different repo than $PRIVATE_FFI_REPO
#   - Rust toolchain with all Apple targets

set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/private-ffi-common.sh

# Ensure cargo/rustup are on PATH (needed when invoked from CI or Xcode)
if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
fi

FORCE_OVERWRITE=false
if [[ "${1:-}" == "--force-overwrite-existing-release" ]]; then
    FORCE_OVERWRITE=true
    shift
fi

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 [--force-overwrite-existing-release] <version>"
    echo "Example: $0 2.6.0-alpha.6"
    exit 1
fi

VERSION="$1"
PRODUCTS_DIR="BuildSupport/products"
ZIP_FILE="libzcashlc.xcframework.zip"
ENV_FILE="$PRODUCTS_DIR/private-release.env"

echo "=== Preparing private FULL-flavor release ${VERSION} (repo: $PRIVATE_FFI_REPO) ==="
echo ""

require_private_ffi_access

# A repo with no commits cannot host releases (a release tag needs a commit to point
# at) -- gh release create would only fail with an HTTP 422 AFTER the long build, so
# check now, while failing is still cheap.
if ! gh api "repos/$PRIVATE_FFI_REPO/commits?per_page=1" >/dev/null 2>&1; then
    echo "Error: $PRIVATE_FFI_REPO has no commits; GitHub cannot create a release on an empty repository." >&2
    echo "Push an initial commit to it (e.g. a README) and re-run." >&2
    exit 1
fi

# --- Switch to FULL mode, restoring whatever mode was active on exit ---
PRIOR_MODE=$(./Scripts/slipstream-ffi-mode.sh status)
restore_ffi_mode() {
    local exit_code=$?
    echo ""
    echo "Restoring prior slipstream-ffi mode (${PRIOR_MODE})..."
    if [[ "$PRIOR_MODE" == "FULL" ]]; then
        ./Scripts/slipstream-ffi-mode.sh enable || echo "Warning: failed to restore FULL mode." >&2
    else
        ./Scripts/slipstream-ffi-mode.sh disable || echo "Warning: failed to restore STUB mode." >&2
    fi
    exit $exit_code
}
trap restore_ffi_mode EXIT

echo ""
echo "=== Switching to FULL mode ==="
./Scripts/slipstream-ffi-mode.sh enable

echo ""
echo "=== Ensuring Rust targets are installed ==="
rustup target add aarch64-apple-ios x86_64-apple-ios aarch64-apple-ios-sim x86_64-apple-darwin aarch64-apple-darwin

echo ""
echo "=== Building FULL-flavor xcframework (all architectures; this takes a while) ==="
cd BuildSupport
make clean
make xcframework
cd ..

echo ""
echo "=== Creating release archive ==="
cd "$PRODUCTS_DIR"
rm -f "$ZIP_FILE"
zip -r "$ZIP_FILE" libzcashlc.xcframework
CHECKSUM=$(shasum -a 256 "$ZIP_FILE" | awk '{print $1}')
cd ../..

echo ""
echo "=== Uploading to GitHub ($PRIVATE_FFI_REPO) ==="

if gh release view "$VERSION" --repo "$PRIVATE_FFI_REPO" &>/dev/null; then
    if [[ "$FORCE_OVERWRITE" != "true" ]]; then
        echo "Error: Release $VERSION already exists on $PRIVATE_FFI_REPO."
        echo "Use --force-overwrite-existing-release to update an existing release."
        exit 1
    fi
    echo "Release $VERSION already exists. Updating assets (--force-overwrite-existing-release)..."
    gh release upload "$VERSION" \
        "$PRODUCTS_DIR/$ZIP_FILE" \
        --repo "$PRIVATE_FFI_REPO" \
        --clobber
else
    gh release create "$VERSION" \
        "$PRODUCTS_DIR/$ZIP_FILE" \
        --repo "$PRIVATE_FFI_REPO" \
        --title "$VERSION" \
        --notes "libzcashlc FULL-flavor xcframework ${VERSION}"
fi

# The numeric asset ID is what the SwiftPM-consumable URL encodes. Re-uploading
# (--clobber) changes it, which is why cut-private-release.sh always re-reads it
# rather than assuming it's stable across releases (spec risk 7).
ASSET_ID=$(gh api "repos/$PRIVATE_FFI_REPO/releases/tags/$VERSION" --jq '.assets[] | select(.name=="'"$ZIP_FILE"'") | .id')
if [[ -z "$ASSET_ID" ]]; then
    echo "Error: could not find the uploaded asset ID for $ZIP_FILE on release $VERSION." >&2
    exit 1
fi
ASSET_URL="https://api.github.com/repos/${PRIVATE_FFI_REPO}/releases/assets/${ASSET_ID}.zip"

mkdir -p "$PRODUCTS_DIR"
cat > "$ENV_FILE" << EOF
VERSION=${VERSION}
ASSET_ID=${ASSET_ID}
ASSET_URL=${ASSET_URL}
CHECKSUM=${CHECKSUM}
EOF

RELEASE_URL="https://github.com/${PRIVATE_FFI_REPO}/releases/tag/${VERSION}"

echo ""
echo "=========================================="
echo "  Private FULL-flavor release created: ${RELEASE_URL}"
echo "  Asset ID: ${ASSET_ID}"
echo "  Wrote ${ENV_FILE}"
echo "=========================================="
echo ""
echo "Package.swift binaryTarget snippet (for reference only -- cut-private-release.sh"
echo "writes this onto a private-release/* branch for you):"
echo ""
echo "   .binaryTarget("
echo "       name: \"libzcashlc\","
echo "       url: \"${ASSET_URL}\","
echo "       checksum: \"${CHECKSUM}\""
echo "   ),"
echo ""
echo "Next step:"
echo "   PRIVATE_FFI_REPO=${PRIVATE_FFI_REPO} ./Scripts/cut-private-release.sh ${VERSION}"
echo ""
