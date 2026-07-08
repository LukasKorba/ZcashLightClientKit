#!/bin/bash
# Cut a private-release/<version> branch that points Package.swift's libzcashlc
# binaryTarget at a FULL-flavor release published by release-private-ffi.sh.
# Usage: ./Scripts/cut-private-release.sh <version> [--base <ref>] [--no-push]
#
# This does NOT rebuild anything -- it downloads the already-published zip (to compute
# an independently-verified checksum; NEVER trust the checksum in release notes or API
# metadata), reads back the asset's numeric ID (the URL SwiftPM needs), and rewrites
# the two Package.swift lines that matter onto a dedicated branch.
#
# Consumers depend on the fork like this:
#   .package(url: "<this fork's URL>", branch: "private-release/<version>")
# Branches, not semver tags: SwiftPM's handling of build-metadata tags (e.g.
# "2.6.0-alpha.6+slipstream") is quirky, so a branch is the robust form.
# `Package.resolved` pins the exact commit, so re-cutting the branch (e.g. after a
# checksum-affecting re-upload -- spec risk 7) requires consumers to re-resolve.
#
# Options:
#   --base <ref>   Branch point for private-release/<version> (default: HEAD, i.e. the
#                  branch you're currently on).
#   --no-push      Rewrite + commit locally but don't push to origin.
#
# This script always returns to the branch you started on, even on failure -- the
# private-release/<version> branch is a byproduct, never your working branch.
#
# Prerequisites:
#   - gh CLI installed and authenticated, with access to $PRIVATE_FFI_REPO
#   - no uncommitted changes to tracked files (untracked files are fine)

set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/private-ffi-common.sh

usage() {
    if [[ -n "${1:-}" ]]; then
        echo "Error: $1" >&2
        echo "" >&2
    fi
    cat >&2 << 'USAGEEOF'
Usage: ./Scripts/cut-private-release.sh <version> [--base <ref>] [--no-push]

  <version>      Tag of an existing release on $PRIVATE_FFI_REPO (published by
                 release-private-ffi.sh).
  --base <ref>   Branch point for private-release/<version> (default: HEAD).
  --no-push      Rewrite + commit locally but don't push to origin.
USAGEEOF
    exit 1
}

if [[ -z "${1:-}" ]]; then
    usage "Missing <version>."
fi
VERSION="$1"
shift

BASE_REF="HEAD"
NO_PUSH=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)
            if [[ -z "${2:-}" ]]; then
                usage "--base requires a value."
            fi
            BASE_REF="$2"
            shift 2
            ;;
        --no-push)
            NO_PUSH=true
            shift
            ;;
        *)
            usage "Unknown argument: $1"
            ;;
    esac
done

ZIP_FILE="libzcashlc.xcframework.zip"
BRANCH="private-release/${VERSION}"

echo "=== Cutting ${BRANCH} (repo: $PRIVATE_FFI_REPO) ==="
echo ""

require_private_ffi_access

# Uncommitted TRACKED changes could pollute the branch commit (Package.swift) or ride
# along onto the new branch invisibly, so refuse them. Untracked files are fine: they
# can't reach the commit (only Package.swift is staged) and git preserves them across
# the checkouts (refusing on its own if one would be overwritten).
if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
    echo "Error: working tree has uncommitted changes. Commit or stash them first." >&2
    git status --short --untracked-files=no >&2
    exit 1
fi

# --- Always return to the branch we started on, success or failure ---
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$ORIGINAL_BRANCH" == "HEAD" ]]; then
    # Detached HEAD: --abbrev-ref can't name it, so pin the exact commit instead.
    ORIGINAL_BRANCH=$(git rev-parse HEAD)
fi
DOWNLOAD_DIR=""
return_to_original_branch() {
    local exit_code=$?
    # Clean up the download dir and any half-written rewrite output.
    if [[ -n "$DOWNLOAD_DIR" ]]; then
        rm -rf "$DOWNLOAD_DIR"
    fi
    rm -f Package.swift.tmp
    # If we died between the rewrite and a successful commit (e.g. a failing commit
    # hook), Package.swift -- worktree and possibly index -- still carries the private
    # asset URL. Discard that from HEAD before switching, so the rewrite can never ride
    # back to the original branch. On the success path both this and the forced branch
    # switch are no-ops (the rewrite is committed on $BRANCH, the tree is clean).
    if ! git checkout HEAD -- Package.swift 2>/dev/null; then
        echo "Warning: failed to reset Package.swift from HEAD before switching back." >&2
    fi
    if ! git checkout -f "$ORIGINAL_BRANCH" >/dev/null 2>&1; then
        echo "Warning: failed to check out ${ORIGINAL_BRANCH} to restore your original branch." >&2
    fi
    exit $exit_code
}
trap return_to_original_branch EXIT

# --- Download the zip and verify it ourselves; never trust release-note checksums ---
DOWNLOAD_DIR=$(mktemp -d)
echo "Downloading ${ZIP_FILE} from release ${VERSION}..."
gh release download "$VERSION" \
    --repo "$PRIVATE_FFI_REPO" \
    --pattern "$ZIP_FILE" \
    --dir "$DOWNLOAD_DIR"

CHECKSUM=$(shasum -a 256 "$DOWNLOAD_DIR/$ZIP_FILE" | awk '{print $1}')
echo "Computed checksum: ${CHECKSUM}"

ASSET_ID=$(gh api "repos/$PRIVATE_FFI_REPO/releases/tags/$VERSION" --jq '.assets[] | select(.name=="'"$ZIP_FILE"'") | .id')
if [[ -z "$ASSET_ID" ]]; then
    echo "Error: could not find the asset ID for $ZIP_FILE on release $VERSION of $PRIVATE_FFI_REPO." >&2
    exit 1
fi
ASSET_URL="https://api.github.com/repos/${PRIVATE_FFI_REPO}/releases/assets/${ASSET_ID}.zip"
echo "Asset URL: ${ASSET_URL}"

echo ""
echo "=== Creating ${BRANCH} from ${BASE_REF} ==="
git checkout -B "$BRANCH" "$BASE_REF"

# Surgical rewrite of exactly the libzcashlc binaryTarget's url/checksum lines. Package.swift
# also has two unrelated `.package(url: ...)` dependency URLs (grpc-swift, SQLite.swift),
# so we scope the substitution to the `.binaryTarget(` block instead of matching `url:`
# globally -- in_block turns on at `.binaryTarget(` and back off right after the
# checksum line, which today is the only binaryTarget in the file.
awk -v new_url="$ASSET_URL" -v new_checksum="$CHECKSUM" '
    /\.binaryTarget\(/ { in_block = 1 }
    in_block && /url:/ {
        sub(/url: "[^"]*"/, "url: \"" new_url "\"")
    }
    in_block && /checksum:/ {
        sub(/checksum: "[^"]*"/, "checksum: \"" new_checksum "\"")
        in_block = 0
    }
    { print }
' Package.swift > Package.swift.tmp
mv Package.swift.tmp Package.swift

# Verify the rewrite actually took before committing it.
if ! grep -qF "$ASSET_URL" Package.swift; then
    echo "Error: failed to rewrite Package.swift's binaryTarget url." >&2
    exit 1
fi
if ! grep -qF "checksum: \"$CHECKSUM\"" Package.swift; then
    echo "Error: failed to rewrite Package.swift's binaryTarget checksum." >&2
    exit 1
fi

git add Package.swift
git commit -m "$(cat <<EOF
Point libzcashlc at private FULL-flavor release ${VERSION}

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"

ORIGIN_URL=$(git remote get-url origin)

if [[ "$NO_PUSH" != "true" ]]; then
    # private-release/* branches carry private asset URLs and belong on the private
    # fork only -- hard-refuse the public upstream, no override flag.
    if [[ "$ORIGIN_URL" == *"zcash/zcash-swift-wallet-sdk"* ]]; then
        echo "" >&2
        echo "Error: origin points at the public upstream (${ORIGIN_URL})." >&2
        echo "private-release/* branches must never be pushed to zcash/zcash-swift-wallet-sdk." >&2
        echo "Re-point origin at the private fork, or re-run with --no-push and push manually." >&2
        exit 1
    fi
    echo ""
    echo "=== Pushing ${BRANCH} to origin (${ORIGIN_URL}) ==="
    if ! git push -u origin "$BRANCH"; then
        echo "" >&2
        echo "Error: push rejected. If ${BRANCH} already exists on origin with different" >&2
        echo "content (e.g. you're recutting after a checksum-affecting re-upload -- spec" >&2
        echo "risk 7), force-push deliberately once you're sure:" >&2
        echo "  git push --force-with-lease origin ${BRANCH}" >&2
        exit 1
    fi
else
    echo ""
    echo "Skipping push (--no-push). Local branch ${BRANCH} is ready."
fi

echo ""
echo "=========================================="
echo "  ${BRANCH} ready (base: ${BASE_REF})"
echo "=========================================="
echo ""
echo "Consumers depend on it like this:"
echo ""
echo "   .package(url: \"${ORIGIN_URL}\", branch: \"${BRANCH}\"),"
echo ""
echo "and need a ~/.netrc entry (or macOS keychain internet-password) authorizing"
echo "api.github.com with a fine-grained PAT scoped to Contents:read on"
echo "$PRIVATE_FFI_REPO ONLY -- see docs/LOCAL_DEVELOPMENT.md:"
echo ""
echo "   machine api.github.com login <github-user> password <PAT>"
echo ""
