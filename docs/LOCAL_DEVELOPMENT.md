# Local FFI Development

This guide explains how to work on the Rust FFI code alongside the Swift SDK.

## Overview

The SDK uses a pre-built XCFramework (`libzcashlc`) for the Rust FFI layer. For most SDK development, you don't need to rebuild the FFI — SPM automatically downloads the pre-built binary from GitHub Releases.

However, if you need to modify the Rust code in `rust/`, you'll need to set up local FFI development.

## How It Works

`Package.swift` automatically detects the presence of `LocalPackages/Package.swift` (created by the init script). When it exists, the SDK builds against your locally-built FFI instead of downloading the release binary. When it doesn't exist, the release binary is used as usual.

This means switching modes is as simple as:
- **Enable local FFI:** `./Scripts/init-local-ffi.sh`
- **Disable local FFI:** `rm -rf LocalPackages/` (or `./Scripts/reset-local-ffi.sh`)

No manual `Package.swift` edits are needed.

## Prerequisites

1. **Rust toolchain** — Install via [rustup](https://rustup.rs/):
   ```bash
   curl --proto '=https' --tlsv1.3 -sSf https://sh.rustup.rs | sh
   ```

2. **Apple platform targets** — Install the required Rust targets:
   ```bash
   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
   rustup target add aarch64-apple-darwin x86_64-apple-darwin
   ```

## Quick Start

### One-Time Setup

You **must** run `init-local-ffi.sh` before opening the project in Xcode. Without it, SPM will attempt to download the release binary, which may not exist for development branches.

```bash
# Clone the repository
git clone https://github.com/zcash/zcash-swift-wallet-sdk
cd zcash-swift-wallet-sdk

# Initialize local FFI (builds from source)
./Scripts/init-local-ffi.sh
```

The `--cached` flag downloads a pre-built release instead of building from source. This only works when `Package.swift` points to a published release:

```bash
./Scripts/init-local-ffi.sh --cached
```

**Warning:** Only use `--cached` if there have been no FFI changes on your branch since the last release. Using a stale pre-built binary with modified Swift bindings could cause silent data corruption and loss of funds. Additionally, `--cached` skips the Rust build entirely, so the first call to `rebuild-local-ffi.sh` will be a full (non-incremental) build.

If you have access to the private slipstream engine and want a prebuilt **FULL-flavor** binary (engine compiled in) without building from source, `--cached-full` is the equivalent collaborator path — see [Prebuilt FULL-flavor binary (access holders)](#prebuilt-full-flavor-binary-access-holders) below.

For faster iteration on Apple Silicon you can build only the arm64 slices you need, skipping the x86_64 simulator/Mac slices you can't run there anyway:

```bash
./Scripts/init-local-ffi.sh --arm-macos # macOS (swift build / swift test on the Mac)
./Scripts/init-local-ffi.sh --arm-ios   # iOS simulator + device
./Scripts/init-local-ffi.sh --arm-all   # iOS simulator + device + macOS
```

Building for a slice you didn't include will fail until you build it (via `rebuild-local-ffi.sh` or a full `init-local-ffi.sh`).

### Opening in Xcode

You can open the project two ways:

- **Workspace** (recommended for FFI development) — includes the FFIBuilder target that automatically rebuilds the FFI when you build in Xcode:
  ```bash
  open ZcashSDK.xcworkspace
  ```
- **Package directly** — simpler, but you'll need to run `rebuild-local-ffi.sh` manually after Rust changes:
  ```bash
  open Package.swift
  ```

If Xcode was already open before you ran `init-local-ffi.sh`, reset package caches: File > Packages > Reset Package Caches.

### Development Loop

```bash
# 1. Edit Rust code
vim rust/src/lib.rs

# 2. Fast incremental rebuild (seconds, not minutes!)
./Scripts/rebuild-local-ffi.sh              # iOS Simulator (default)
./Scripts/rebuild-local-ffi.sh ios-device   # iOS Device
./Scripts/rebuild-local-ffi.sh macos        # macOS

# 3. Build/test in Xcode
#    Clean build folder if Xcode doesn't pick up changes: Cmd+Shift+K
```

### Switching Back to Release Binary

```bash
./Scripts/reset-local-ffi.sh
```

If using Xcode, you may also need to reset package caches: File > Packages > Reset Package Caches.

## Scripts Reference

### `init-local-ffi.sh`

One-time setup that creates the local development environment.

```bash
./Scripts/init-local-ffi.sh             # Build from source, all 5 architectures (recommended)
./Scripts/init-local-ffi.sh --arm-macos # arm64 macOS slice only
./Scripts/init-local-ffi.sh --arm-ios   # arm64 iOS simulator + device slices
./Scripts/init-local-ffi.sh --arm-all   # arm64 iOS simulator + device + macOS slices
./Scripts/init-local-ffi.sh --cached    # Download pre-built release
./Scripts/init-local-ffi.sh --cached-full [version] # Download prebuilt FULL-flavor release (access holders — see below)
```

This script:
- Builds the full XCFramework (all 5 architectures), an arm64-only subset (`--arm-*`, faster on Apple Silicon since it skips the x86_64 slices), or downloads a pre-built one (public STUB-flavor via `--cached`, or private FULL-flavor via `--cached-full`)
- Creates `LocalPackages/` with an SPM wrapper package
- `Package.swift` automatically detects `LocalPackages/` and switches to local mode

The `--arm-*` flags always build the `aarch64-*` targets regardless of host architecture. They produce an XCFramework containing only the requested arm64 slices, so building for an x86_64 simulator/Mac (or a slice you didn't include) will fail until you build it — run `rebuild-local-ffi.sh <target>` or a full `init-local-ffi.sh` to add the missing slices. Any unrecognized flag prints usage and exits without building.

### `rebuild-local-ffi.sh`

Fast incremental rebuild for the current development target. Requires `init-local-ffi.sh` to have been run first.

```bash
./Scripts/rebuild-local-ffi.sh [target]
```

Targets:
- `ios-sim` (default) — iOS Simulator, auto-detects arm64 vs x86_64
- `ios-device` — iOS Device (arm64)
- `macos` — macOS, auto-detects arm64 vs x86_64

**Why it's fast:** Only builds ONE architecture, and Cargo's incremental compilation means small changes rebuild in seconds.

**Note:** This creates a single-architecture build. Run `init-local-ffi.sh` before submitting PRs to verify all architectures compile.

### `reset-local-ffi.sh`

Removes `LocalPackages/` and switches back to the release binary.

```bash
./Scripts/reset-local-ffi.sh
```

## Architecture Details

### XCFramework Structure

The XCFramework contains three platform slices:
- `ios-arm64` — iOS devices
- `ios-arm64_x86_64-simulator` — iOS Simulator (universal)
- `macos-arm64_x86_64` — macOS (universal)

### Build Targets

| Development Target | Rust Target | XCFramework Slice |
|-------------------|-------------|-------------------|
| iOS Simulator (Apple Silicon) | `aarch64-apple-ios-sim` | `ios-arm64_x86_64-simulator` |
| iOS Simulator (Intel) | `x86_64-apple-ios` | `ios-arm64_x86_64-simulator` |
| iOS Device | `aarch64-apple-ios` | `ios-arm64` |
| macOS (Apple Silicon) | `aarch64-apple-darwin` | `macos-arm64_x86_64` |
| macOS (Intel) | `x86_64-apple-darwin` | `macos-arm64_x86_64` |

### Local Package Override

The `LocalPackages` directory contains a Swift package named `libzcashlc` with the same product name as the binary target in `Package.swift`. When `Package.swift` detects that `LocalPackages/Package.swift` exists, it adds `LocalPackages` as a path dependency and uses it instead of the `.binaryTarget` declaration. This switching is automatic — no manual edits to `Package.swift` are needed.

## Automatic FFI Rebuilds

The shared `ZcashLightClientKit` scheme in `ZcashSDK.xcworkspace` includes `FFIBuilder` as a build dependency. FFIBuilder runs `rebuild-local-ffi.sh` with the appropriate platform based on your selected destination, so Rust code is automatically recompiled when you build in Xcode.

**Note:** The FFIBuilder target requires `init-local-ffi.sh` to have been run first — it calls `rebuild-local-ffi.sh`, which expects `LocalPackages/` to exist.

| Approach | Best for |
|----------|----------|
| Manual script (`rebuild-local-ffi.sh`) | Occasional FFI changes, simple setup |
| FFIBuilder target in workspace | Frequent FFI changes, prefer staying in Xcode |

## Prebuilt FULL-flavor binary (access holders)

This SDK ships in two flavors of the same `libzcashlc` XCFramework: **STUB** (the public
default — every `slipstream_*` FFI entry point reports "engine not available") and
**FULL** (the real slipstream engine compiled in). Building FULL from source requires
git access to the private slipstream engine repository (`Scripts/slipstream-ffi-mode.sh
enable`, above). If you don't need to touch Rust at all, prebuilt FULL-flavor
XCFrameworks are also published on a dedicated private GitHub repo (`$PRIVATE_FFI_REPO`,
defined in `Scripts/private-ffi-common.sh`) — three ways to consume one, depending on
who you are:

| You are... | Use | Needs |
|---|---|---|
| An app depending on this SDK | `.package(url: "git@github.com:<org>/<private-ffi-repo>.git", exact: "<version>")` | ssh access to the repo + `~/.netrc` with a PAT (binary download) |
| An SDK collaborator not touching Rust | `./Scripts/init-local-ffi.sh --cached-full` | `gh auth` access to the private FFI repo only |
| An SDK collaborator building the engine from source | `./Scripts/slipstream-ffi-mode.sh enable` + `init-local-ffi.sh` | git access to the private *engine* repo |

Note the two different private repos involved: the FFI **asset** repo (prebuilt
binaries and the version tags below) and the engine **source** repo
(`LukasKorba/slipstream`, used by `slipstream-ffi-mode.sh`). They are deliberately
separate — see the PAT guidance below.

`$PRIVATE_FFI_REPO` carries two kinds of tag per version, created by two different
scripts:

| Tag | Created by | Purpose |
|---|---|---|
| `ffi-<version>` | `release-private-ffi.sh` | Release/asset-anchor tag. Hosts the built `libzcashlc.xcframework.zip`. |
| `<version>` | `publish-private-sdk-tag.sh` | Plain semver git tag, SPM-consumable. Points at a commit whose tree matches this fork at that version, except `Package.swift`'s `libzcashlc` binaryTarget url+checksum, which reference the `ffi-<version>` release asset. |

An asset re-upload changes the numeric asset ID (and so the checksum consumers must
verify against), which invalidates any `<version>` tag that already pointed at the old
one. Re-publishing the tag after that requires `publish-private-sdk-tag.sh <version> --force-retag`,
since the script otherwise refuses to overwrite an existing remote tag.

### 1. App: consume a version tag

`Scripts/publish-private-sdk-tag.sh` (run by whoever manages FFI releases) pushes a plain
semver tag `<version>` directly to the private FFI asset repo, with `Package.swift`'s
`libzcashlc` binaryTarget pointed at that version's release asset. Depend on it like any
other SwiftPM package dependency:

```swift
.package(url: "git@github.com:LukasKorba/zcash-sdk-private-ffi.git", exact: "2.6.0-alpha.6")
```

`Package.resolved` pins the exact commit, same as any other tag dependency.

Two separate authentications are involved, because SwiftPM handles them differently:

1. **Cloning the private package repo (git).** Uses git's own credential system, NOT
   SwiftPM's netrc. The ssh URL form above (with your ssh key authorized for the repo)
   is what our distribution gates verify end-to-end. If you must use the
   `https://github.com/...` URL form instead (common in CI), git needs an HTTPS
   credential for `github.com` — either a credential helper, or an additional netrc
   line (git reads netrc too): `machine github.com login <user> password <PAT>` (the
   same fine-grained PAT works as a git-over-HTTPS password).
2. **Downloading the binaryTarget zip from the private release.** SwiftPM authenticates
   this via `~/.netrc`:

```
machine api.github.com login <your-github-username> password <fine-grained-PAT>
```

`chmod 600 ~/.netrc` — SwiftPM (like `git` and `curl`) may otherwise ignore or refuse a
world-readable netrc. The netrc route is the one our distribution gates verify
end-to-end; as Apple's documented alternative (not exercised by our gates), on macOS
you can use the keychain instead of a plaintext file:

```bash
security add-internet-password -a <your-github-username> -s api.github.com -w <fine-grained-PAT>
```

**PAT scope:** create a **fine-grained** personal access token with **`Contents: read`**
scoped to **only the private FFI asset repo** — never a classic all-repo token. Keeping
prebuilt binaries in their own dedicated repo, separate from the engine source, exists
precisely so that a leaked netrc/keychain credential exposes only "someone can download
prebuilt binaries," never "someone can read the engine source."

**App CI:** inject `~/.netrc` from a secret at build/checkout time (e.g. a setup step
that writes it before `xcodebuild`/`swift build` run) — don't commit it to the repo.
If CI resolves the package over HTTPS rather than ssh, the injected netrc needs BOTH
lines (`machine github.com` for the git clone, `machine api.github.com` for the binary
download), per the authentication split above.

### 2. SDK collaborator: `--cached-full` (no Rust toolchain)

```bash
./Scripts/init-local-ffi.sh --cached-full 2.6.0-alpha.6
```

Downloads the private-release XCFramework straight into `LocalPackages/` — equivalent to
`--cached`, but from the private FFI asset repo's `ffi-<version>` release instead of the
public SDK release. This only needs `gh auth` access to that repo: no netrc, no Rust
toolchain, no engine-source access. Omit the version to reuse the one recorded in
`BuildSupport/products/private-release.env` (written by `release-private-ffi.sh` if you
just cut a release yourself).

### 3. SDK collaborator: build FULL from source

See `Scripts/slipstream-ffi-mode.sh enable` above — this is the only one of the three
paths that touches the private engine source, and the only one gated on access to that
repo rather than the FFI asset repo.

### Releasing a new FULL-flavor binary (maintainers)

```bash
PRIVATE_FFI_REPO=<owner>/<repo> ./Scripts/release-private-ffi.sh 2.6.0-alpha.6
PRIVATE_FFI_REPO=<owner>/<repo> ./Scripts/publish-private-sdk-tag.sh 2.6.0-alpha.6
```

`release-private-ffi.sh` builds all 5 architectures in FULL mode — restoring whichever
slipstream-ffi mode was active before it ran, even on failure — and publishes the zip as
release `ffi-2.6.0-alpha.6` on `$PRIVATE_FFI_REPO` (default in
`Scripts/private-ffi-common.sh`, override via the environment, e.g. for testing against
a scratch repo). `publish-private-sdk-tag.sh` re-downloads that same zip, checksums it itself
(never trusting the checksum in release metadata), and pushes a commit with the patched
`Package.swift` directly to the `2.6.0-alpha.6` tag on `$PRIVATE_FFI_GIT_URL` (derived
from `$PRIVATE_FFI_REPO`; see `Scripts/private-ffi-common.sh`) — no local branch, and no
push to this repo's own `origin`. Re-publishing the tag after a checksum-affecting re-upload needs
`--force-retag`.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| SwiftPM / `gh` / `xcodebuild` reports 404 fetching the asset | No access to the private repo, an expired/wrong PAT, or a stale asset ID | Confirm `gh api repos/<owner>/<repo>` succeeds for your account; regenerate the PAT; re-run `publish-private-sdk-tag.sh` to re-read the current asset ID |
| SwiftPM fails with a checksum mismatch | The release asset was re-uploaded (its numeric asset ID and content changed, but the `<version>` tag still points at the old checksum/ID — an asset re-upload always invalidates the tag that referenced it) | Re-publish the tag (`publish-private-sdk-tag.sh <version> --force-retag`) and have consumers re-resolve packages |
| Stale/corrupted resolve after switching versions or flavors | SwiftPM's or Xcode's local package cache still has the old artifact | Purge the cache: delete `.build/` in a SwiftPM-only checkout (or whatever directory you passed to `--cache-path`/`--scratch-path`), or in Xcode: File > Packages > Reset Package Caches (see the general Troubleshooting section below for `DerivedData` too) |

## Troubleshooting

### Xcode can't resolve packages / shows 404 error

This means `LocalPackages/` doesn't exist and SPM is trying to download the release binary. Run `./Scripts/init-local-ffi.sh` to set up local development, then reset package caches in Xcode: File > Packages > Reset Package Caches.

### Xcode doesn't pick up FFI changes

1. Clean the build folder: Cmd+Shift+K
2. If that doesn't work, reset package caches: File > Packages > Reset Package Caches
3. If that doesn't work, close Xcode and delete DerivedData:
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData
   ```

### Build fails with missing target

Ensure all Rust targets are installed:
```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
rustup target add aarch64-apple-darwin x86_64-apple-darwin
```

### Header changes not reflected

The headers are regenerated during cargo build. If you see stale headers:
```bash
rm -rf target/Headers
./Scripts/rebuild-local-ffi.sh
```

### Xcode uses wrong FFI after switching modes

After running `init-local-ffi.sh` or `reset-local-ffi.sh`, Xcode may need to re-resolve packages:
1. File > Packages > Reset Package Caches
2. If that doesn't help, close and reopen the workspace

### FFIBuilder fails on first workspace open

When opening `ZcashSDK.xcworkspace` for the first time after running `init-local-ffi.sh`, FFIBuilder may fail with "Command PhaseScriptExecution failed with a nonzero exit code". This is a timing issue -- Xcode may attempt to build FFIBuilder before package resolution has completed. Run "Product > Build For > Testing" manually and the build should succeed. Subsequent builds will work normally.

### FFI rebuilds from scratch despite no changes

The Makefile (used by `init-local-ffi.sh`) and `rebuild-local-ffi.sh` invoke `cargo` with slightly different environment variables, which can cause Cargo to invalidate its build cache. This means the first `rebuild-local-ffi.sh` after `init-local-ffi.sh` (or vice versa) may do a full rebuild. Subsequent incremental rebuilds within the same tool will be fast.

### `rustup: command not found` in Xcode build

The scripts source `~/.cargo/env` to find the Rust toolchain. If you installed Rust via a non-standard method (e.g., Homebrew, Nix), you may need to ensure `cargo` and `rustup` are on the default PATH or add the appropriate source/export to `~/.zprofile`.

## Full Rebuild

Before submitting a PR that modifies Rust code:

```bash
# Full rebuild to verify all architectures compile
./Scripts/init-local-ffi.sh

# Run tests
swift test
```
