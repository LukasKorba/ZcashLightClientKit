#!/bin/bash
# Initialize local FFI development environment
# Usage: ./Scripts/init-local-ffi.sh [option]
#
# Options:
#   (no option)   Build the full XCFramework (all 5 architectures) from your rust/.
#   --arm-macos   Build only the arm64 macOS slice (aarch64-apple-darwin).
#   --arm-ios     Build only the arm64 iOS slices: simulator (aarch64-apple-ios-sim)
#                 and device (aarch64-apple-ios).
#   --arm-all     Build all arm64 slices: iOS simulator + device + macOS.
#   --cached      Download the pre-built release XCFramework instead of building.
#   --cached-full [<version>]
#                 Download a prebuilt FULL-flavor XCFramework from the private FFI
#                 asset repo ($PRIVATE_FFI_REPO, see Scripts/private-ffi-common.sh)
#                 instead of building. Collaborator path: no Rust toolchain, no netrc --
#                 just `gh auth` access to the private repo. <version> defaults to the
#                 VERSION recorded in BuildSupport/products/private-release.env (written
#                 by release-private-ffi.sh) when omitted. Downloads from that version's
#                 release tag `ffi-<version>` (honoring the RELEASE_TAG recorded in
#                 private-release.env when present, in case that convention ever
#                 changes; otherwise derived as `ffi-<version>`).
#
#                 Checksum verification: if private-release.env is present AND its
#                 VERSION matches, the download is verified against its CHECKSUM.
#                 Otherwise (no env file, or it's for a different version) there is
#                 nothing trusted to check against, so this prints the computed sha256
#                 and proceeds on a TOFU (trust-on-first-use) basis -- record that value
#                 if you want future downloads of this version verified.
#
# The --arm-* options skip the x86_64 simulator/Mac slices, which you cannot run on
# Apple Silicon anyway, so local iteration is faster. They always build the aarch64
# targets regardless of host architecture.
#
# This creates LocalPackages/ with a locally-built xcframework.
# Package.swift automatically detects LocalPackages/ and switches
# from the release binary to the local build.
#
# To switch back to the release binary: rm -rf LocalPackages/

set -e
cd "$(dirname "$0")/.."

echo "slipstream-ffi mode: $(./Scripts/slipstream-ffi-mode.sh status || echo UNKNOWN)"

# Ensure cargo/rustup are on PATH (needed when invoked from Xcode)
if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
fi

XCFRAMEWORK_DIR="LocalPackages/libzcashlc.xcframework"

usage() {
    if [[ -n "${1:-}" ]]; then
        echo "Error: $1" >&2
        echo "" >&2
    fi
    cat >&2 << 'USAGEEOF'
Usage: ./Scripts/init-local-ffi.sh [option]

Options:
  (no option)   Build the full XCFramework (all 5 architectures) from your rust/.
  --arm-macos   Build only the arm64 macOS slice (aarch64-apple-darwin).
  --arm-ios     Build only the arm64 iOS slices: simulator + device.
  --arm-all     Build all arm64 slices: iOS simulator + device + macOS.
  --cached      Download the pre-built release XCFramework instead of building.
  --cached-full [<version>]
                Download a prebuilt FULL-flavor XCFramework from the private FFI asset
                repo's `ffi-<version>` release tag instead of building (requires gh
                access; no Rust toolchain, no netrc). <version> defaults to
                BuildSupport/products/private-release.env when omitted. Verifies
                against that file's CHECKSUM if it matches the requested version, else
                proceeds TOFU and prints the computed sha256.

Creates LocalPackages/ with a locally-built xcframework. Package.swift detects
LocalPackages/ and uses it instead of the released binary.
USAGEEOF
    exit 1
}

# Build an arm64-only xcframework containing exactly the requested slices, then
# atomically swap it into place. Each argument is one of: ios-sim, ios-device, macos.
#
# The slices reuse the same LibraryIdentifiers as the full build (e.g.
# macos-arm64_x86_64) but declare only arm64 in SupportedArchitectures, matching
# what rebuild-local-ffi.sh produces, so the two tools stay interchangeable.
build_arm_xcframework() {
    local targets=("$@")

    local temp_dir temp_xcfw
    temp_dir=$(mktemp -d)
    temp_xcfw="$temp_dir/libzcashlc.xcframework"
    mkdir -p "$temp_xcfw"

    # One JSON object per slice, accumulated for the xcframework Info.plist.
    local libraries_json=""

    local target
    for target in "${targets[@]}"; do
        local rust_target slice platform variant
        case "$target" in
            ios-sim)
                rust_target="aarch64-apple-ios-sim"
                slice="ios-arm64_x86_64-simulator"
                platform="ios"
                variant="simulator"
                ;;
            ios-device)
                rust_target="aarch64-apple-ios"
                slice="ios-arm64"
                platform="ios"
                variant=""
                ;;
            macos)
                rust_target="aarch64-apple-darwin"
                slice="macos-arm64_x86_64"
                platform="macos"
                variant=""
                ;;
            *)
                echo "Internal error: unknown arm target '$target'" >&2
                exit 1
                ;;
        esac

        echo "Building $rust_target -> $slice ..."

        # Ensure the Rust target is available (idempotent), then build it.
        # cargo is incremental, so repeat builds after small edits are fast.
        rustup target add "$rust_target"
        cargo build --target "$rust_target" --release

        # Populate the framework for this slice.
        local framework="$temp_xcfw/$slice/libzcashlc.framework"
        mkdir -p "$framework/Modules" "$framework/Headers"
        cp "target/$rust_target/release/libzcashlc.a" "$framework/libzcashlc"
        cp BuildSupport/module.modulemap "$framework/Modules/"
        cp BuildSupport/platform-Info.plist "$framework/Info.plist"
        if [[ -d "target/Headers" ]]; then
            cp -R target/Headers/* "$framework/Headers/"
        fi

        # Assemble this slice's AvailableLibraries entry as JSON (arm64 only).
        local variant_json=""
        if [[ -n "$variant" ]]; then
            variant_json=", \"SupportedPlatformVariant\": \"$variant\""
        fi
        local entry="{\"LibraryIdentifier\": \"$slice\", \"LibraryPath\": \"libzcashlc.framework\", \"SupportedArchitectures\": [\"arm64\"], \"SupportedPlatform\": \"$platform\"$variant_json}"
        if [[ -n "$libraries_json" ]]; then
            libraries_json="$libraries_json, $entry"
        else
            libraries_json="$entry"
        fi
    done

    # Generate the xcframework Info.plist from JSON; plutil emits canonical XML
    # and validates it in one step, so we avoid hand-writing plist whitespace.
    printf '{"AvailableLibraries": [%s], "CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0"}' "$libraries_json" \
        | plutil -convert xml1 -o "$temp_xcfw/Info.plist" -

    # Atomically swap the freshly built xcframework into place.
    mkdir -p LocalPackages
    rm -rf "$XCFRAMEWORK_DIR"
    mv "$temp_xcfw" "$XCFRAMEWORK_DIR"
    rm -rf "$temp_dir"
}

# Parse the single optional flag. Only --cached-full takes a further value (a version).
if [[ $# -gt 2 ]] || { [[ $# -eq 2 ]] && [[ "$1" != "--cached-full" ]]; }; then
    usage "Too many arguments; pass at most one option (only --cached-full takes a version)."
fi

BUILD_MODE="full"
ARM_TARGETS=()
CACHED_FULL_VERSION=""
case "${1:-}" in
    "")
        BUILD_MODE="full"
        ;;
    --cached)
        BUILD_MODE="cached"
        ;;
    --cached-full)
        BUILD_MODE="cached-full"
        CACHED_FULL_VERSION="${2:-}"
        ;;
    --arm-macos)
        BUILD_MODE="arm"
        ARM_TARGETS=(macos)
        ;;
    --arm-ios)
        BUILD_MODE="arm"
        ARM_TARGETS=(ios-sim ios-device)
        ;;
    --arm-all)
        BUILD_MODE="arm"
        ARM_TARGETS=(ios-sim ios-device macos)
        ;;
    *)
        usage "Unknown option: $1"
        ;;
esac

if [[ "$BUILD_MODE" == "arm" ]]; then
    echo "Initializing local FFI for arm64 (${ARM_TARGETS[*]})..."
    build_arm_xcframework "${ARM_TARGETS[@]}"
elif [[ "$BUILD_MODE" == "cached" ]]; then
    echo "Downloading pre-built xcframework..."
    REPO="zcash/zcash-swift-wallet-sdk"

    # Extract the version from the download URL in Package.swift
    SDK_VERSION=$(grep -oE 'releases/download/[0-9]+\.[0-9]+\.[0-9]+' Package.swift | head -1 | sed 's|releases/download/||')
    if [[ -z "$SDK_VERSION" ]]; then
        echo "Error: Could not determine SDK version from Package.swift"
        exit 1
    fi

    # Extract the expected checksum from Package.swift
    EXPECTED_CHECKSUM=$(grep -A1 'libzcashlc.xcframework.zip' Package.swift | grep 'checksum:' | sed -E 's/.*checksum: "([a-f0-9]+)".*/\1/')
    if [[ -z "$EXPECTED_CHECKSUM" ]]; then
        echo "Error: Could not extract checksum from Package.swift"
        exit 1
    fi

    mkdir -p LocalPackages
    # Use gh CLI to download release assets (works for both draft and published releases)
    gh release download "$SDK_VERSION" \
        --repo "$REPO" \
        --pattern "libzcashlc.xcframework.zip" \
        --dir LocalPackages

    # Verify checksum
    ACTUAL_CHECKSUM=$(shasum -a 256 LocalPackages/libzcashlc.xcframework.zip | awk '{print $1}')
    if [[ "$ACTUAL_CHECKSUM" != "$EXPECTED_CHECKSUM" ]]; then
        echo "Error: Checksum mismatch!"
        echo "  Expected: $EXPECTED_CHECKSUM"
        echo "  Actual:   $ACTUAL_CHECKSUM"
        rm -f LocalPackages/libzcashlc.xcframework.zip
        exit 1
    fi
    echo "Checksum verified."

    unzip -o LocalPackages/libzcashlc.xcframework.zip -d LocalPackages/
    rm LocalPackages/libzcashlc.xcframework.zip
    echo ""
    echo "Note: Downloaded pre-built xcframework may not match your local source."
    echo "      Run './Scripts/rebuild-local-ffi.sh' to rebuild for your target platform."
elif [[ "$BUILD_MODE" == "cached-full" ]]; then
    source Scripts/private-ffi-common.sh
    require_private_ffi_access

    echo "Downloading pre-built FULL-flavor xcframework from $PRIVATE_FFI_REPO..."

    # A prebuilt FULL-flavor binary is orthogonal to the source-level slipstream-ffi
    # mode (which only matters when building from Cargo source) -- this branch never
    # touches Cargo.toml/Cargo.lock.
    ENV_FILE="BuildSupport/products/private-release.env"
    ENV_VERSION=""
    ENV_CHECKSUM=""
    ENV_RELEASE_TAG=""
    if [[ -f "$ENV_FILE" ]]; then
        ENV_VERSION=$(grep '^VERSION=' "$ENV_FILE" | cut -d= -f2-)
        ENV_CHECKSUM=$(grep '^CHECKSUM=' "$ENV_FILE" | cut -d= -f2-)
        ENV_RELEASE_TAG=$(grep '^RELEASE_TAG=' "$ENV_FILE" | cut -d= -f2-)
    fi

    FULL_VERSION="$CACHED_FULL_VERSION"
    if [[ -z "$FULL_VERSION" ]]; then
        FULL_VERSION="$ENV_VERSION"
    fi
    if [[ -z "$FULL_VERSION" ]]; then
        usage "No version given and $ENV_FILE not found. Usage: --cached-full <version>, or run release-private-ffi.sh first to populate $ENV_FILE."
    fi

    # The asset lives on the release tag "ffi-<version>", not "<version>" itself (that
    # plain tag is the separate SPM-consumable one cut-private-release.sh creates).
    # Honor the RELEASE_TAG recorded in private-release.env when it matches the
    # requested version, in case the "ffi-" prefix convention ever changes; otherwise
    # derive it.
    RELEASE_TAG="ffi-${FULL_VERSION}"
    if [[ -n "$ENV_RELEASE_TAG" && "$ENV_VERSION" == "$FULL_VERSION" ]]; then
        RELEASE_TAG="$ENV_RELEASE_TAG"
    fi

    echo "Version: $FULL_VERSION (release tag: $RELEASE_TAG)"

    mkdir -p LocalPackages
    gh release download "$RELEASE_TAG" \
        --repo "$PRIVATE_FFI_REPO" \
        --pattern "libzcashlc.xcframework.zip" \
        --dir LocalPackages

    ACTUAL_CHECKSUM=$(shasum -a 256 LocalPackages/libzcashlc.xcframework.zip | awk '{print $1}')

    if [[ -n "$ENV_CHECKSUM" && "$ENV_VERSION" == "$FULL_VERSION" ]]; then
        if [[ "$ACTUAL_CHECKSUM" != "$ENV_CHECKSUM" ]]; then
            echo "Error: Checksum mismatch!"
            echo "  Expected (from $ENV_FILE): $ENV_CHECKSUM"
            echo "  Actual:                    $ACTUAL_CHECKSUM"
            rm -f LocalPackages/libzcashlc.xcframework.zip
            exit 1
        fi
        echo "Checksum verified against $ENV_FILE."
    else
        echo ""
        echo "Warning: no recorded checksum for $FULL_VERSION to verify against"
        echo "($ENV_FILE is absent, or records a different version)."
        echo "TOFU (trust-on-first-use): proceeding with the downloaded artifact. sha256:"
        echo "  $ACTUAL_CHECKSUM"
        echo "Record this value if you want future downloads of this version verified."
    fi

    unzip -o LocalPackages/libzcashlc.xcframework.zip -d LocalPackages/
    rm LocalPackages/libzcashlc.xcframework.zip
    echo ""
    echo "Downloaded FULL-flavor xcframework (private release $FULL_VERSION)."
else
    echo "Building full xcframework from source (this takes a while)..."
    cd BuildSupport
    make xcframework
    cd ..
    mkdir -p LocalPackages
    cp -R BuildSupport/products/libzcashlc.xcframework "$XCFRAMEWORK_DIR"
fi

# Create local SPM package wrapper
cp BuildSupport/LocalPackages-Package.swift LocalPackages/Package.swift

echo ""
echo "Local FFI initialized at LocalPackages/"
echo "Package.swift will automatically use the local build."
echo ""
echo "Next steps:"
echo "  1. Open ZcashSDK.xcworkspace in Xcode (or run: swift build)"
echo "  2. The workspace scheme rebuilds FFI automatically on each build."
echo "     If opening Package.swift directly, run ./Scripts/rebuild-local-ffi.sh after Rust changes."
if [[ "$BUILD_MODE" == "arm" ]]; then
    echo ""
    echo "Note: this produced an arm64-only XCFramework (${ARM_TARGETS[*]})."
    echo "      Building for an x86_64 simulator/Mac or a slice you didn't include will fail"
    echo "      until you build it. Run ./Scripts/rebuild-local-ffi.sh <target> for a single"
    echo "      arch, or ./Scripts/init-local-ffi.sh (no flags) for the full 5-architecture build."
fi
echo ""
echo "To switch back to the release binary: rm -rf LocalPackages/"
