//! Stub ABI flavor of the Slipstream FFI surface — compiled instead of `slipstream_ffi`
//! when the crate is built with `--no-default-features` (the `slipstream` feature off),
//! i.e. without access to the private `slipstream-core` engine repository.
//!
//! Every `zcashlc_slipstream_*` symbol below has the BYTE-IDENTICAL signature (and,
//! where cbindgen surfaces them, doc comment) as its counterpart in `slipstream_ffi.rs`
//! — see Gate 1a (`nm` symbol-set diff) and Gate 1b (cbindgen header diff) — so a host
//! app linking this flavor still compiles and links; every entry point simply reports
//! "engine not available" instead of doing real work. [`zcashlc_slipstream_available`]
//! is how a host distinguishes the two flavors at runtime.

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;

use crate::ffi;
use crate::slipstream_ffi_types::{FfiRestoreAnchor, FfiSlipstreamEvent, FfiSlipstreamSnapshot};
use crate::{unwrap_exc_or, unwrap_exc_or_null};

/// The error every fallible function below reports via the crate's standard last-error
/// mechanism (the same `catch_panic`/`unwrap_exc_or`/`unwrap_exc_or_null` convention
/// every other `zcashlc_*` FFI function in this crate uses — see `zcashlc_last_error_length`
/// / `zcashlc_error_message_utf8`).
const UNAVAILABLE_MSG: &str = "slipstream engine is not available in this build of libzcashlc";

/// Opaque handle to a Slipstream engine instance.
///
/// Wraps [`slipstream_core::ffi_handle::SlipstreamHandle`] as a crate-local newtype so
/// that cbindgen (which only parses the root crate) emits the required opaque typedef
/// `typedef struct SlipstreamHandle SlipstreamHandle;` in the generated `zcashlc.h`.
///
/// All state is stored in `inner`; the six `zcashlc_slipstream_*` functions delegate
/// directly to it.
pub struct SlipstreamHandle {
    // STUB flavor: there is no engine crate to wrap. No function in this module ever
    // constructs one of these — `zcashlc_slipstream_open` always returns null — so this
    // field exists only so the type is an ordinary sized struct, matching the shape (if
    // not the contents) of the `slipstream`-flavor definition in `slipstream_ffi.rs`.
    _private: (),
}

/// Opens a Slipstream engine handle.
///
/// - `db_data`/`db_data_len`: path to the wallet data.db (UTF-8 bytes, no NUL terminator).
/// - `server_host`/`server_host_len`: lightwalletd hostname (UTF-8 bytes).
/// - `server_port`: lightwalletd port.
/// - `use_tls`: `true` for TLS (mainnet), `false` for plaintext.
/// - `network_id`: `1` for mainnet, `0` for testnet.
/// - `total_memory_bytes`: host physical memory in bytes (Swift passes
///   `ProcessInfo.processInfo.physicalMemory`); `0` = unknown. Drives device-memory
///   budget derating at start for <3 GiB devices (T8.4); `0`/big devices keep defaults.
///
/// Returns an opaque handle pointer, or null on failure.
/// Free with [`zcashlc_slipstream_free`] when done.
///
/// # Safety
///
/// - `db_data` must be non-null and valid for reads for `db_data_len` bytes, with
///   alignment of `1`. Its contents must be a valid system path in the OS's preferred
///   representation.
/// - `server_host` must be non-null and valid for reads for `server_host_len` bytes,
///   with alignment of `1`. Its contents must be valid UTF-8.
/// - Neither pointer's memory must be mutated for the duration of the call.
/// - `db_data_len` and `server_host_len` must each be no larger than `isize::MAX`.
/// - Call [`zcashlc_slipstream_free`] to free the memory associated with the returned
///   pointer when done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_slipstream_open(
    db_data: *const u8,
    db_data_len: usize,
    server_host: *const u8,
    server_host_len: usize,
    server_port: u16,
    use_tls: bool,
    network_id: u32,
    total_memory_bytes: u64,
) -> *mut SlipstreamHandle {
    let _ = (
        db_data,
        db_data_len,
        server_host,
        server_host_len,
        server_port,
        use_tls,
        network_id,
        total_memory_bytes,
    );
    let res: Result<*mut SlipstreamHandle, ()> = catch_panic(|| Err(anyhow!(UNAVAILABLE_MSG)));
    unwrap_exc_or_null(res)
}

/// Starts a Slipstream sync pass.
///
/// - `handle`: non-null pointer returned by [`zcashlc_slipstream_open`].
/// - `ufvk`/`ufvk_len`: UFVK string (UTF-8 bytes), or null/0 for a keyless update
///   (birthday is ignored when ufvk is null — account must already be imported).
/// - `birthday_height`: wallet birthday height (ignored when ufvk is null).
/// - `tor_dir`/`tor_dir_len`: dedicated Tor state directory (UTF-8 bytes) for the engine's
///   isolated circuits. Pass null/0 to sync directly (Tor off). When non-empty, the engine
///   bootstraps an arti client from it — a subdir SEPARATE from the old SDK's `TorClient`
///   directory (arti holds a state lock). Metadata calls then use isolated Tor circuits;
///   bulk block fetch stays direct (mirrors the old SDK's per-call Tor policy).
///
/// Can be called after [`zcashlc_slipstream_stop`] to restart. Cancels any in-flight
/// sync before spawning the new one.
/// Returns `true` on success, `false` on error
/// (check [`zcashlc_get_last_error_message`] for the error text).
///
/// # Safety
///
/// - `handle` must be a non-null pointer returned by [`zcashlc_slipstream_open`] that
///   has not previously been freed.
/// - `handle` must not be passed to two FFI calls at the same time.
/// - If `ufvk` is non-null, it must be valid for reads for `ufvk_len` bytes (UTF-8,
///   alignment `1`), and its memory must not be mutated for the duration of the call.
/// - If `tor_dir` is non-null, it must be valid for reads for `tor_dir_len` bytes (UTF-8,
///   alignment `1`), and its memory must not be mutated for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_slipstream_start(
    handle: *mut SlipstreamHandle,
    ufvk: *const u8,
    ufvk_len: usize,
    birthday_height: u64,
    tor_dir: *const u8,
    tor_dir_len: usize,
) -> bool {
    let _ = (handle, ufvk, ufvk_len, birthday_height, tor_dir, tor_dir_len);
    let res: Result<bool, ()> = catch_panic(|| Err(anyhow!(UNAVAILABLE_MSG)));
    unwrap_exc_or(res, false)
}

/// Stops any in-flight Slipstream sync (non-blocking — task abort is async).
///
/// Returns `true` immediately. The handle remains live; poll
/// [`zcashlc_slipstream_snapshot`] to confirm state transitions to idle.
///
/// # Safety
///
/// - `handle` must be a non-null pointer returned by [`zcashlc_slipstream_open`] that
///   has not previously been freed.
/// - `handle` must not be passed to two FFI calls at the same time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_slipstream_stop(handle: *mut SlipstreamHandle) -> bool {
    let _ = handle;
    let res: Result<bool, ()> = catch_panic(|| Err(anyhow!(UNAVAILABLE_MSG)));
    unwrap_exc_or(res, false)
}

/// Reads a snapshot of current Slipstream progress atomics (non-blocking, poll-based — D8).
///
/// Returns a zero-filled struct on null handle.
///
/// # Safety
///
/// - `handle` must be a non-null pointer returned by [`zcashlc_slipstream_open`] that
///   has not previously been freed, or null (in which case a zeroed struct is returned).
/// - `handle` must not be passed to two FFI calls at the same time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_slipstream_snapshot(
    handle: *const SlipstreamHandle,
) -> FfiSlipstreamSnapshot {
    let _ = handle;
    let res: Result<FfiSlipstreamSnapshot, ()> = catch_panic(|| Err(anyhow!(UNAVAILABLE_MSG)));
    unwrap_exc_or(res, FfiSlipstreamSnapshot::default())
}

/// [API v2 §4.5] Notifies the engine that the HOST changed the wallet's transaction set
/// outside a sync pass — e.g. it stored a just-broadcast transaction. The engine responds by
/// emitting a FoundTransactions event (tag 5) through its normal event channel, so every
/// host's single event loop sees the pending transaction immediately and uniformly instead of
/// waiting for the next mempool/scan round. Returns `true` on success, `false` on a null
/// handle or internal panic.
///
/// # Safety
///
/// - `handle` must be a non-null pointer returned by [`zcashlc_slipstream_open`] that
///   has not previously been freed.
/// - `handle` must not be passed to two FFI calls at the same time.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_slipstream_notify_tx_change(handle: *mut SlipstreamHandle) -> bool {
    let _ = handle;
    let res: Result<bool, ()> = catch_panic(|| Err(anyhow!(UNAVAILABLE_MSG)));
    unwrap_exc_or(res, false)
}

/// [API v2.1 E-6] The engine-owned wallet-provisioning anchor (policy in slipstream-core
/// `anchor.rs`): the chain facts a host needs BEFORE creating/restoring a wallet, with the
/// offline fallback policy INSIDE — no host re-implements provisioning math.
///
/// - `intent` = 1 (RESTORE, with `birthday`): `height` = the live chain tip to provision as
///   `recover_until`; offline ⇒ `max(fallback_checkpoint_height, birthday + 1)` (a restore
///   must NEVER get a NULL recover_until — the syncLogsMac9 rule). `treestate` is null (the
///   host keeps its birthday checkpoint).
/// - `intent` = 0 (NEW wallet): `height` + serialized `TreeState` protobuf = the reorg-safe
///   recent tree state (`tip − 100`, floored at Sapling activation); offline ⇒ `height` 0 +
///   null `treestate` (the host keeps its bundled checkpoint defaults).
///
/// Handle-less by design: provisioning happens BEFORE [`zcashlc_slipstream_open`] in the
/// host init flow, and `importAccount` must not serialize against the live handle. Creates
/// a short-lived runtime and blocks until resolved (typically one round-trip; the direct
/// path is a SINGLE attempt — the offline fallback IS the retry policy). When `tor_dir` is
/// non-empty the identifying fetches ride an isolated Tor circuit; a requested-but-failed
/// Tor bootstrap resolves OFFLINE — never a de-anonymising direct retry.
///
/// Returns null only on invalid arguments or an internal panic. Free with
/// [`zcashlc_slipstream_free_restore_anchor`].
///
/// # Safety
///
/// - `server_host` must be non-null and valid for reads for `server_host_len` bytes (UTF-8).
/// - If `tor_dir` is non-null, it must be valid for reads for `tor_dir_len` bytes (UTF-8).
/// - Neither buffer may be mutated for the duration of the call.
/// - Call [`zcashlc_slipstream_free_restore_anchor`] to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_slipstream_restore_anchor(
    server_host: *const u8,
    server_host_len: usize,
    server_port: u16,
    use_tls: bool,
    network_id: u32,
    intent: u8,
    birthday: u64,
    fallback_checkpoint_height: u64,
    tor_dir: *const u8,
    tor_dir_len: usize,
) -> *mut FfiRestoreAnchor {
    let _ = (
        server_host,
        server_host_len,
        server_port,
        use_tls,
        network_id,
        intent,
        birthday,
        fallback_checkpoint_height,
        tor_dir,
        tor_dir_len,
    );
    let res: Result<*mut FfiRestoreAnchor, ()> = catch_panic(|| Err(anyhow!(UNAVAILABLE_MSG)));
    unwrap_exc_or_null(res)
}

/// Frees an [`FfiRestoreAnchor`] returned by [`zcashlc_slipstream_restore_anchor`].
///
/// # Safety
///
/// - If `ptr` is non-null, it must be a pointer returned by
///   [`zcashlc_slipstream_restore_anchor`] that has not previously been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_slipstream_free_restore_anchor(ptr: *mut FfiRestoreAnchor) {
    // STUB flavor: `zcashlc_slipstream_restore_anchor` never actually allocates one of
    // these, so a well-behaved caller never has a non-null pointer to pass here. Kept as
    // a safe no-op (rather than a `catch_panic` + last-error report) to match the "free"
    // functions' existing convention: freeing is infallible.
    let _ = ptr;
}

/// [API v2 §0-5] The unified, PHASE-RESOLVING wallet summary for Slipstream hosts: one call
/// that is correct at every phase, so no host ever re-implements restore balance math.
///
/// - **Not recovering** → the upstream wallet summary, unchanged (identical to
///   [`zcashlc_get_wallet_summary`]).
/// - **Recovering** (the recent-first restore backfill; `snapshot.is_recovering == 1`) →
///   the upstream summary's per-account balances are REPLACED, because upstream balances
///   "may overestimate" mid-restore by documented design (a receipt is counted before its
///   spend is scanned). The replacement is the engine-owned `slipstream_v_recovery_balance`
///   (Σ of FINAL, reconciled tx deltas — never over-shows, converges to the true total),
///   surfaced per the SDK's field-validated Direction-B mapping: the whole clamped net as
///   orchard spendable, everything else zero. Progress/heights fields pass through.
///
/// Returns null on error; a summary with `fully_scanned_height == -1` when the wallet has
/// no balance data yet.
///
/// # Safety
///
/// - `handle` must be a non-null pointer returned by [`zcashlc_slipstream_open`] that
///   has not previously been freed, and must not be passed to two FFI calls at once.
/// - Call [`zcashlc_free_wallet_summary`] to free the memory associated with the returned
///   pointer when done using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_slipstream_wallet_summary(
    handle: *const SlipstreamHandle,
    confirmations_policy: ffi::ConfirmationsPolicy,
) -> *mut ffi::WalletSummary {
    let _ = (handle, confirmations_policy);
    let res: Result<*mut ffi::WalletSummary, ()> = catch_panic(|| Err(anyhow!(UNAVAILABLE_MSG)));
    unwrap_exc_or_null(res)
}

/// Drains all queued Slipstream events into a caller-allocated buffer.
///
/// - `handle`: non-null pointer returned by [`zcashlc_slipstream_open`].
/// - `buf`: caller-allocated array of [`FfiSlipstreamEvent`]; must be valid for writes
///   for `buf_len` elements.
/// - `buf_len`: length of `buf` (maximum events to drain in this call).
///
/// Returns the number of events written (≤ `buf_len`). Events are drained atomically
/// — after this call returns, the drained events are removed from the internal ring.
///
/// # Safety
///
/// - `handle` must be a non-null pointer returned by [`zcashlc_slipstream_open`] that
///   has not previously been freed.
/// - `handle` must not be passed to two FFI calls at the same time.
/// - `buf` must be non-null and valid for writes for `buf_len` elements of
///   [`FfiSlipstreamEvent`], with alignment of `1`.
/// - `buf_len` must be no larger than `isize::MAX`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_slipstream_drain_events(
    handle: *mut SlipstreamHandle,
    buf: *mut FfiSlipstreamEvent,
    buf_len: usize,
) -> usize {
    let _ = (handle, buf, buf_len);
    let res: Result<usize, ()> = catch_panic(|| Err(anyhow!(UNAVAILABLE_MSG)));
    unwrap_exc_or(res, 0)
}

/// Frees a Slipstream handle.
///
/// Cancels any in-flight sync and drops the tokio runtime. After this call, `handle`
/// must not be used.
///
/// # Safety
///
/// - If `handle` is non-null, it must be a pointer returned by [`zcashlc_slipstream_open`]
///   that has not previously been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_slipstream_free(handle: *mut SlipstreamHandle) {
    // STUB flavor: `zcashlc_slipstream_open` never actually allocates one of these, so a
    // well-behaved caller never has a non-null pointer to pass here. Kept as a safe
    // no-op (rather than a `catch_panic` + last-error report) to match the "free"
    // functions' existing convention: freeing is infallible.
    let _ = handle;
}

/// Reports whether this build of `libzcashlc` links the real Slipstream engine.
///
/// Hosts should call this once (e.g. at startup) to decide whether to offer Slipstream
/// sync at all. Returns `true` here, in the `slipstream` (real-engine) flavor — every
/// other `zcashlc_slipstream_*` function performs real work; `false` in the stub-ABI
/// flavor — every other `zcashlc_slipstream_*` function is a no-op that reports
/// `"slipstream engine is not available in this build of libzcashlc"`.
#[unsafe(no_mangle)]
pub extern "C" fn zcashlc_slipstream_available() -> bool {
    false
}
