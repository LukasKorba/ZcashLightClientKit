#!/bin/bash
# Push a version tag (SwiftPM-consumable) to the private FFI asset repo
# ($PRIVATE_FFI_REPO, see private-ffi-common.sh) that points this fork's Package.swift
# libzcashlc binaryTarget at a FULL-flavor release published by release-private-ffi.sh.
# Usage: ./Scripts/cut-private-release.sh <version> [--base <ref>] [--no-push] [--force-retag]
#
# This does NOT rebuild anything -- it downloads the already-published zip (to compute
# an independently-verified checksum; NEVER trust the checksum in release notes or API
# metadata), reads back the asset's numeric ID (the URL SwiftPM needs), and rewrites the
# two Package.swift lines that matter onto a commit pushed directly to refs/tags/<version>
# on $PRIVATE_FFI_GIT_URL -- no local branch, and no push to this repo's own origin.
#
# $PRIVATE_FFI_REPO carries two kinds of tag per version, created by two different
# scripts:
#   ffi-<version>   Release/asset-anchor tag (release-private-ffi.sh). Hosts the zip.
#   <version>       Plain semver git tag (this script). SPM-consumable; points at a
#                   commit with this fork's tree, Package.swift patched to reference the
#                   ffi-<version> release asset.
# Consumers depend on this fork like this:
#   .package(url: "https://github.com/<org>/<private-ffi-repo>.git", exact: "<version>")
# `Package.resolved` pins the exact commit, so this is as reproducible as any other
# SwiftPM tag dependency. Re-cutting after a checksum-affecting re-upload (asset
# re-upload changes the numeric asset ID -- spec risk 7) requires --force-retag: this
# script refuses to overwrite an existing remote <version> tag otherwise.
#
# Options:
#   --base <ref>     Commit to base the patched commit on (default: HEAD, i.e. the
#                     branch you're currently on). The patched commit is created
#                     detached -- never as a local branch -- and left to be garbage
#                     collected once you're switched away from it (either after a
#                     successful push, or after copying the printed SHA under --no-push).
#   --no-push         Rewrite + commit locally but don't push anywhere. Prints the
#                     commit SHA and the exact push command to run manually.
#   --force-retag     Overwrite an existing remote <version> tag. Required if it already
#                     exists (see the re-upload note above); refused otherwise.
#
# This script always returns to the branch you started on, even on failure -- the
# patched commit is a byproduct, never your working branch.
#
# Prerequisites:
#   - gh CLI installed and authenticated, with access to $PRIVATE_FFI_REPO
#   - git push access (ssh) to $PRIVATE_FFI_GIT_URL, unless --no-push
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
Usage: ./Scripts/cut-private-release.sh <version> [--base <ref>] [--no-push] [--force-retag]

  <version>        Tag of an existing release `ffi-<version>` on $PRIVATE_FFI_REPO
                   (published by release-private-ffi.sh).
  --base <ref>     Commit to base the patched commit on (default: HEAD).
  --no-push        Rewrite + commit locally but don't push.
  --force-retag    Overwrite an existing remote <version> tag.
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
FORCE_RETAG=false
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
        --force-retag)
            FORCE_RETAG=true
            shift
            ;;
        *)
            usage "Unknown argument: $1"
            ;;
    esac
done

ZIP_FILE="libzcashlc.xcframework.zip"
RELEASE_TAG="ffi-${VERSION}"

echo "=== Cutting tag ${VERSION} from release ${RELEASE_TAG} (repo: $PRIVATE_FFI_REPO) ==="
echo ""

# --- Hard refuse the public upstream, no override flag -- before any network call ---
# Version tags carry a private asset URL and belong on the private FFI asset repo only.
# Checked first (and unconditionally, --no-push included) so a misconfigured
# PRIVATE_FFI_REPO/PRIVATE_FFI_GIT_URL fails before this script so much as touches the
# network, let alone pushes.
if [[ "$PRIVATE_FFI_REPO" == *"zcash/zcash-swift-wallet-sdk"* ]] || [[ "$PRIVATE_FFI_GIT_URL" == *"zcash/zcash-swift-wallet-sdk"* ]]; then
    echo "" >&2
    echo "Error: PRIVATE_FFI_REPO/PRIVATE_FFI_GIT_URL resolves to the public upstream." >&2
    echo "  PRIVATE_FFI_REPO=${PRIVATE_FFI_REPO}" >&2
    echo "  PRIVATE_FFI_GIT_URL=${PRIVATE_FFI_GIT_URL}" >&2
    echo "<version> tags must never be pushed to zcash/zcash-swift-wallet-sdk." >&2
    echo "Point PRIVATE_FFI_REPO (and/or PRIVATE_FFI_GIT_URL) at the private FFI asset repo instead." >&2
    exit 1
fi

require_private_ffi_access

# Uncommitted TRACKED changes could pollute the patched commit (Package.swift) or ride
# along onto it invisibly, so refuse them. Untracked files are fine: they can't reach
# the commit (only Package.swift is staged) and git preserves them across the
# checkouts (refusing on its own if one would be overwritten).
if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
    echo "Error: working tree has uncommitted changes. Commit or stash them first." >&2
    git status --short --untracked-files=no >&2
    exit 1
fi

# --- Verify the release and asset exist before doing anything else ---
echo "Verifying release ${RELEASE_TAG} exists..."
if ! gh release view "$RELEASE_TAG" --repo "$PRIVATE_FFI_REPO" >/dev/null 2>&1; then
    echo "Error: release ${RELEASE_TAG} not found on $PRIVATE_FFI_REPO." >&2
    echo "Run release-private-ffi.sh ${VERSION} first." >&2
    exit 1
fi

ASSET_ID=$(gh api "repos/$PRIVATE_FFI_REPO/releases/tags/$RELEASE_TAG" --jq '.assets[] | select(.name=="'"$ZIP_FILE"'") | .id')
if [[ -z "$ASSET_ID" ]]; then
    echo "Error: could not find the asset ID for $ZIP_FILE on release $RELEASE_TAG of $PRIVATE_FFI_REPO." >&2
    exit 1
fi
ASSET_URL="https://api.github.com/repos/${PRIVATE_FFI_REPO}/releases/assets/${ASSET_ID}.zip"
echo "Asset URL: ${ASSET_URL}"

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
    # switch are no-ops (the rewrite is committed on the detached commit, the tree is
    # clean, and that commit has no local branch pointing at it to carry anything back).
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
echo "Downloading ${ZIP_FILE} from release ${RELEASE_TAG}..."
gh release download "$RELEASE_TAG" \
    --repo "$PRIVATE_FFI_REPO" \
    --pattern "$ZIP_FILE" \
    --dir "$DOWNLOAD_DIR"

CHECKSUM=$(shasum -a 256 "$DOWNLOAD_DIR/$ZIP_FILE" | awk '{print $1}')
echo "Computed checksum: ${CHECKSUM}"

echo ""
echo "=== Creating the patched commit (detached, from ${BASE_REF}) ==="
git checkout --detach "$BASE_REF"

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

NEW_COMMIT_SHA=$(git rev-parse HEAD)

if [[ "$NO_PUSH" != "true" ]]; then
    # Refuse to silently overwrite an existing remote <version> tag -- a re-cut after an
    # asset re-upload changes the checksum/asset ID (spec risk 7), so overwriting is
    # sometimes exactly right, but it must be deliberate.
    EXISTING_TAG_SHA=$(git ls-remote "$PRIVATE_FFI_GIT_URL" "refs/tags/${VERSION}" | awk '{print $1}')
    if [[ -n "$EXISTING_TAG_SHA" && "$FORCE_RETAG" != "true" ]]; then
        echo "" >&2
        echo "Error: tag ${VERSION} already exists on ${PRIVATE_FFI_GIT_URL} (${EXISTING_TAG_SHA})." >&2
        echo "Re-cutting after an asset re-upload changes the checksum/asset ID, so the existing" >&2
        echo "tag would go on pointing at stale content. Pass --force-retag to overwrite it" >&2
        echo "deliberately." >&2
        exit 1
    fi

    echo ""
    echo "=== Pushing ${NEW_COMMIT_SHA} to ${PRIVATE_FFI_GIT_URL} as refs/tags/${VERSION} ==="
    PUSH_ARGS=()
    if [[ "$FORCE_RETAG" == "true" ]]; then
        PUSH_ARGS+=("--force")
    fi
    PUSH_ARGS+=("$PRIVATE_FFI_GIT_URL" "${NEW_COMMIT_SHA}:refs/tags/${VERSION}")
    if ! git push "${PUSH_ARGS[@]}"; then
        echo "" >&2
        echo "Error: push rejected." >&2
        if [[ "$FORCE_RETAG" != "true" ]]; then
            echo "If ${VERSION} already exists on ${PRIVATE_FFI_GIT_URL} with different content" >&2
            echo "(e.g. you're recutting after a checksum-affecting re-upload -- spec risk 7)," >&2
            echo "re-run with --force-retag." >&2
        fi
        exit 1
    fi
else
    echo ""
    echo "Skipping push (--no-push)."
    echo "Commit ready locally (detached, not attached to any branch): ${NEW_COMMIT_SHA}"
    echo "Push it manually with:"
    if [[ "$FORCE_RETAG" == "true" ]]; then
        echo "  git push --force ${PRIVATE_FFI_GIT_URL} ${NEW_COMMIT_SHA}:refs/tags/${VERSION}"
    else
        echo "  git push ${PRIVATE_FFI_GIT_URL} ${NEW_COMMIT_SHA}:refs/tags/${VERSION}"
        echo "(add --force before the URL if ${VERSION} already exists remotely and this is a deliberate re-cut)"
    fi
fi

echo ""
echo "=========================================="
if [[ "$NO_PUSH" != "true" ]]; then
    echo "  Tag ${VERSION} pushed to ${PRIVATE_FFI_GIT_URL}"
else
    echo "  Commit ${NEW_COMMIT_SHA} ready (not pushed -- --no-push)"
fi
echo "=========================================="
echo ""
echo "Consumers depend on it like this:"
echo ""
echo "   .package(url: \"https://github.com/${PRIVATE_FFI_REPO}.git\", exact: \"${VERSION}\"),"
echo ""
echo "and need a ~/.netrc entry (or macOS keychain internet-password) authorizing"
echo "api.github.com with a fine-grained PAT scoped to Contents:read on"
echo "$PRIVATE_FFI_REPO ONLY -- see docs/LOCAL_DEVELOPMENT.md:"
echo ""
echo "   machine api.github.com login <github-user> password <PAT>"
echo ""
