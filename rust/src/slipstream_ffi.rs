// ── Slipstream FFI surface ────────────────────────────────────────────────────
//
// These functions are ADDITIVE — they do not modify any existing item above.
// Pattern mirrors `zcashlc_create_tor_runtime` / `zcashlc_free_tor_runtime`
// (lib.rs:3157-3195): Box::into_raw / Box::from_raw, catch_panic, unwrap_exc_or_null.
// D7 deviation: the tokio runtime is created at `open` and lives for the full
// handle lifetime (dropped at `free`), not created per-start. This mirrors the
// TorRuntime precedent where the runtime is owned by the handle.
//
// cbindgen note (C4/C12): cbindgen only parses the root crate. `FfiSlipstreamSnapshot`
// and `FfiSlipstreamEvent` are therefore defined directly here so they appear in the
// generated `zcashlc.h`.
//
// `SlipstreamHandle` MUST also be defined here (not imported from the dep crate) so
// cbindgen emits `typedef struct SlipstreamHandle SlipstreamHandle;` in the header.
// Without it the ObjC module fails to compile with "unknown type name 'SlipstreamHandle'".
// This is the TorRuntime pattern: `TorRuntime` is defined in rust/src/tor.rs (crate-local)
// so cbindgen can see and emit its opaque typedef. We wrap the core handle in a thin
// crate-local newtype here — the wrapper owns the core handle via `inner`.

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::panic::AssertUnwindSafe;
use std::path::Path;
use std::slice;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use prost::Message;
use slipstream_core::ffi_handle::SyncState;
use zcash_client_backend::data_api::{WalletRead, wallet};
use zcash_client_sqlite::AccountUuid;
use zcash_protocol::consensus::Network::{MainNetwork, TestNetwork};

use crate::ffi;
use crate::slipstream_ffi_types::{FfiRestoreAnchor, FfiSlipstreamEvent, FfiSlipstreamSnapshot};
use crate::{free_ptr_from_vec, ptr_from_vec, unwrap_exc_or, unwrap_exc_or_null, wallet_db};

/// Opaque handle to a Slipstream engine instance.
///
/// Wraps [`slipstream_core::ffi_handle::SlipstreamHandle`] as a crate-local newtype so
/// that cbindgen (which only parses the root crate) emits the required opaque typedef
/// `typedef struct SlipstreamHandle SlipstreamHandle;` in the generated `zcashlc.h`.
///
/// All state is stored in `inner`; the six `zcashlc_slipstream_*` functions delegate
/// directly to it.
pub struct SlipstreamHandle {
    inner: slipstream_core::ffi_handle::SlipstreamHandle,
    /// [API v2.1 E-1] Upstream-summary cache: the expensive `get_wallet_summary` walk is
    /// rationed HERE (engine-side), so hosts may call the unified summary whenever they
    /// like. Arc'd because the background refresh thread outlives the FFI call.
    summary_cache: std::sync::Arc<std::sync::Mutex<Option<SummaryCacheEntry>>>,
    /// [API v2.1 E-1] One background refresh in flight at a time.
    summary_refresh_inflight: std::sync::Arc<std::sync::atomic::AtomicBool>,
    /// [API v2.1 E-2] Tip-freshness for the [#1591] stale-tip spendable mask — the engine
    /// owns the FACT (it is the thing refreshing the tip); hosts apply the mask transform.
    /// `shouldMarkChainTipUpdated` semantics at the source: fresh once THIS run has
    /// persisted a freshly-fetched server tip (`Progress::tip_refreshes` advanced past the
    /// baseline captured at `start()` — the engine bumps it only after `update_chain_tip`
    /// succeeds), or when a pass reaches Done. Counter-based (not tip-value-based) so the
    /// E-3 DB-seeded tip can neither fake freshness nor suppress a genuine refresh that
    /// happens to fetch the same height.
    tip_refreshes_at_run_start: std::sync::atomic::AtomicU64,
    tip_fresh: std::sync::atomic::AtomicBool,
    /// [API v2.1 E-2] `stop()` timestamp: freshness survives a stop→start hop shorter than
    /// 120 s (the SDK's `SDKFlags.sdkStarted` quick-background parity).
    last_stop_at: std::sync::Mutex<Option<std::time::Instant>>,
}

/// [API v2.1 E-1] One cached upstream wallet summary + the engine facts it was captured
/// under. Refresh triggers: the pass crossed a range boundary (`ranges_completed` moved),
/// the engine state changed (e.g. Syncing → Done), or — outside a scan — the idle TTL
/// elapsed. While Syncing between boundaries the cache is served as-is: this is the T5.5
/// no-walk-while-scanning invariant, now engine-owned.
struct SummaryCacheEntry {
    captured_at: std::time::Instant,
    ranges_completed: u64,
    state: u8,
    summary: zcash_client_backend::data_api::WalletSummary<AccountUuid>,
}

/// [API v2.1 E-1] Idle refresh TTL — matches the SDK's historical idle/error refetch cadence.
const SUMMARY_IDLE_TTL: std::time::Duration = std::time::Duration::from_secs(2);
/// [API v2.1 E-2] Freshness survives stop→start hops shorter than this (SDKFlags parity).
const TIP_FRESH_STOP_WINDOW: std::time::Duration = std::time::Duration::from_secs(120);

/// Installs (once per process) a chaining panic hook that reports every Rust panic
/// through `tracing::error!` before delegating to the previously-installed hook.
///
/// B1 (#1755 failure-path hardening): `zcashlc_init_on_load` installs `log_panics`,
/// which reports panics via the `log` facade — that reaches os_log only through the
/// `tracing-log` bridge AND only when the app initialized logging at a level that
/// admits it. This hook reports directly through `tracing` so device logs always
/// carry the panic message and backtrace location, no matter how the `log` facade
/// is configured. Chaining preserves `log_panics` (and any test-harness hook).
static SLIPSTREAM_PANIC_HOOK: std::sync::Once = std::sync::Once::new();

fn install_slipstream_panic_hook() {
    SLIPSTREAM_PANIC_HOOK.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            tracing::error!(panic = %info, "rust panic");
            previous(info);
        }));
    });
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
    let res = catch_panic(|| {
        // B1 (#1755): make sure every panic is visible in device logs (os_log via
        // the tracing layers) — see install_slipstream_panic_hook.
        install_slipstream_panic_hook();

        let db_path = Path::new(OsStr::from_bytes(unsafe {
            slice::from_raw_parts(db_data, db_data_len)
        }));
        let host =
            std::str::from_utf8(unsafe { slice::from_raw_parts(server_host, server_host_len) })
                .map_err(|e| anyhow!("server_host UTF-8: {e}"))?;
        let network = if network_id == 1 { MainNetwork } else { TestNetwork };

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .map_err(|e| anyhow!("tokio runtime: {e}"))?;

        let inner = slipstream_core::ffi_handle::SlipstreamHandle {
            runtime,
            progress: std::sync::Arc::new(slipstream_core::events::Progress::default()),
            state: std::sync::Arc::new(std::sync::Mutex::new(SyncState::Idle)),
            events: std::sync::Arc::new(std::sync::Mutex::new(Vec::new())),
            task: None,
            pass_lock: std::sync::Arc::new(tokio::sync::Mutex::new(())),
            endpoint: slipstream_core::config::Endpoint {
                host: host.to_string(),
                port: server_port,
                tls: use_tls,
            },
            wallet_db_path: db_path.to_path_buf(),
            network,
            total_memory_bytes,
        };

        // [API v2.1 E-3] Truthful-from-open snapshot: seed the progress atomics from the
        // persisted wallet DB (the same inputs the first suggest round would use), so a
        // pre-pass snapshot never lies — `is_recovering` is correct on a mid-restore
        // relaunch, the permille floor holds a 99%-synced wallet's real position, and
        // `chain_tip` reports the last persisted tip. Hosts must NOT compensate.
        // Failures degrade to the zero snapshot (truthful for a fresh wallet) — the seed
        // is presentation state and must never fail `open()`. NOTE: the Swift host always
        // runs `Initializer.initialize` (DB create + migrations) before `open()`, so this
        // does not race wallet creation.
        match slipstream_core::wallet_session::WalletSession::open(network, db_path) {
            Ok(session) => {
                if let Err(e) =
                    slipstream_core::scheduler::seed_progress_from_wallet(&inner.progress, &session)
                {
                    tracing::warn!(error = %e, "E-3 open-time snapshot seed failed — snapshot starts cold");
                }
            }
            Err(e) => {
                tracing::warn!(error = %e, "E-3 seed skipped (wallet not openable) — snapshot starts cold");
            }
        }
        tracing::info!(total_memory_bytes, "slipstream handle opened");

        Ok(Box::into_raw(Box::new(SlipstreamHandle {
            inner,
            summary_cache: std::sync::Arc::new(std::sync::Mutex::new(None)),
            summary_refresh_inflight: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            // Freshness baseline = the refresh COUNTER (0 on a fresh handle; the E-3 seed
            // above never bumps it) — a DB-seeded tip is persisted state, not freshness.
            tip_refreshes_at_run_start: std::sync::atomic::AtomicU64::new(0),
            tip_fresh: std::sync::atomic::AtomicBool::new(false),
            last_stop_at: std::sync::Mutex::new(None),
        })))
    });
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
    // SAFETY: callers must respect mutability rules on the Swift side so that observing
    // a panic from another thread does not leave the handle in an inconsistent state.
    let handle = AssertUnwindSafe(handle);
    let res = catch_panic(|| {
        let handle = unsafe { handle.as_mut() }.ok_or_else(|| anyhow!("null handle"))?;

        // [API v2.1 E-2] Tip-freshness bookkeeping (shouldMarkChainTipUpdated parity):
        // capture the refresh-counter baseline BEFORE the pass starts — a later advance
        // proves THIS run persisted a freshly-fetched tip (even when the fetched height
        // equals the E-3 DB-seeded one). Freshness survives a stop→start hop < 120 s
        // (quick background hop); a longer gap re-masks until the new pass proves the tip.
        let refreshes_now = handle.inner.progress.tip_refreshes();
        handle
            .tip_refreshes_at_run_start
            .store(refreshes_now, std::sync::atomic::Ordering::Relaxed);
        let stale_stop = handle
            .last_stop_at
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .map(|t| t.elapsed() >= TIP_FRESH_STOP_WINDOW)
            .unwrap_or(false);
        if stale_stop {
            handle
                .tip_fresh
                .store(false, std::sync::atomic::Ordering::Relaxed);
        }

        let h = &mut handle.inner;

        // Cancel any in-flight task before spawning a new one.
        if let Some(task) = h.task.take() {
            task.abort();
            join_aborted_slipstream_task(&task);
        }
        // [B4-16 drain] The aborted pass's write-behind commit may still be running
        // (`spawn_blocking` — uncancellable); wait it out BEFORE spawning the new
        // session, so the new pass's first writes never collide with an orphan
        // ("database is locked" at pass start) and no orphan Scanned-mark can land
        // after this point. Kills the B4-12 orphan-overlap class at the root.
        drain_slipstream_wallet_writers(&h.progress);
        *h.state.lock().unwrap_or_else(|p| p.into_inner()) = SyncState::Syncing;

        let ufvk_str: Option<String> = if ufvk.is_null() || ufvk_len == 0 {
            None
        } else {
            Some(
                std::str::from_utf8(unsafe { slice::from_raw_parts(ufvk, ufvk_len) })
                    .map_err(|e| anyhow!("ufvk UTF-8: {e}"))?
                    .to_string(),
            )
        };

        // ── T-Tor.3: engine-owned Tor (mirrors the old SDK's per-call Tor setup) ──
        // Swift passes a non-empty `tor_dir` — a DEDICATED slipstream Tor state subdir,
        // separate from the old SDK's TorRuntime dir to avoid an arti state-lock clash —
        // ONLY when Tor is enabled at start() time; empty/null = Tor off (direct).
        let tor_dir_opt: Option<std::path::PathBuf> = if tor_dir.is_null() || tor_dir_len == 0 {
            None
        } else {
            Some(
                Path::new(OsStr::from_bytes(unsafe {
                    slice::from_raw_parts(tor_dir, tor_dir_len)
                }))
                .to_path_buf(),
            )
        };

        #[allow(unused_mut)] // `mut` is only used under the `gpu` feature below.
        let mut cfg = slipstream_core::config::EngineConfig::new(
            h.network,
            h.wallet_db_path.clone(),
            h.endpoint.clone(),
        )
        // T8.4: derate fetch/split budgets on <3 GiB devices from the open-time
        // physical-memory hint (0 = unknown → defaults). Explicit field overrides win.
        .scaled_for_device_memory(h.total_memory_bytes);

        // v0.3 (#1755): GPU Orchard subtree offload. Compiled only with `--features gpu`;
        // opt in at runtime via the ZCASH_GPU_SUBTREE env var (the dev A/B for the device
        // matrix — set it in the Xcode scheme for v0.3, unset for v0.2). The capability
        // auto-gate (calibration probe) supersedes this once tuned. No-op without the
        // feature (build_orchard_subtrees falls back to CPU regardless).
        #[cfg(feature = "gpu")]
        {
            cfg.gpu_subtree = std::env::var("ZCASH_GPU_SUBTREE")
                .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                .unwrap_or(false);
            tracing::info!(gpu_subtree = cfg.gpu_subtree, "v0.3 GPU offload config (feature=gpu)");
        }

        // v0.4 (#1755): Plan A graft + Plan B batch — DEFAULT ON since 2026-07-05
        // (P3 gates passed 100%). The env toggles are now KILL SWITCHES
        // (`=0` disables) and the dev A/B lever. Mirrors ZCASH_GPU_SUBTREE.
        cfg.graft_subtree = std::env::var("ZCASH_GRAFT_SUBTREE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(cfg.graft_subtree);
        cfg.batch_combine = std::env::var("ZCASH_BATCH_COMBINE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(cfg.batch_combine);
        // v0.5 C1 (#1755): batched same-scalar trial-decrypt DH (forked orchard
        // lockstep kernel). Default OFF until the C3 device gates.
        cfg.batch_decrypt = std::env::var("ZCASH_BATCH_DECRYPT")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(cfg.batch_decrypt);
        // v0.5 scan-pacer lever (#1755): local chunk-boundary treestates
        // (one seed fetch per range instead of one RPC per boundary).
        // Default OFF until the A/B + audit gates.
        cfg.local_treestate = std::env::var("ZCASH_LOCAL_TREESTATE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(cfg.local_treestate);
        // v0.5 C2 (#1755): GLV endomorphism per-item DH. Default ON
        // (fleet-gated 2026-07-06); ZCASH_ENDO_MUL=0 is the kill switch.
        cfg.endo_mul = std::env::var("ZCASH_ENDO_MUL")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(cfg.endo_mul);
        tracing::info!(
            graft_subtree = cfg.graft_subtree,
            batch_combine = cfg.batch_combine,
            batch_decrypt = cfg.batch_decrypt,
            endo_mul = cfg.endo_mul,
            local_treestate = cfg.local_treestate,
            "v0.4/v0.5 lever config"
        );

        // ── Build the session config + reporting sink, then spawn the engine session ──────
        // The orchestration (resilient Tor bootstrap + initial pass + tip-following + mempool)
        // now lives in slipstream_core::session::run_session. This FFI only marshals C args,
        // builds the config + the reporting sink (the handle's existing progress/state/event
        // Arcs), and spawns the engine's session on the handle runtime.
        let account: Option<(String, u64)> = ufvk_str.map(|s| (s, birthday_height));
        // iOS sandboxes the app dir so fs-mistrust can trust it (mirrors the old SDK's
        // zcashlc_create_tor_runtime); elsewhere let Tor manage permissions. The engine stays
        // host-agnostic — a future Android FFI sets this field too.
        let tor = tor_dir_opt.map(|dir| slipstream_core::session::TorSessionConfig {
            dir,
            dangerously_trust_everyone: cfg!(target_os = "ios"),
        });
        let session_config =
            slipstream_core::session::SessionConfig { engine: cfg, account, tor };
        let reporter = slipstream_core::session::SessionReporter {
            progress: std::sync::Arc::clone(&h.progress),
            state: std::sync::Arc::clone(&h.state),
            events: std::sync::Arc::clone(&h.events),
        };

        // B1 (#1755): spawn SUPERVISED — a panic in the session body becomes SyncState::Error(2)
        // + a tag=4/value=2 event instead of a silent death stuck at "Syncing" forever.
        let sup_state = std::sync::Arc::clone(&h.state);
        let sup_events = std::sync::Arc::clone(&h.events);
        h.task = Some(slipstream_core::ffi_handle::spawn_supervised(
            &h.runtime,
            slipstream_core::session::run_session(
                session_config,
                reporter,
                std::sync::Arc::clone(&h.pass_lock),
            ),
            sup_state,
            sup_events,
        ));
        Ok(true)
    });
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
    let handle = AssertUnwindSafe(handle);
    let res = catch_panic(|| {
        let handle = unsafe { handle.as_mut() }.ok_or_else(|| anyhow!("null handle"))?;
        // [API v2.1 E-2] Stamp the stop: a start() within 120 s keeps tip freshness
        // (quick background hop, SDKFlags parity); a longer gap re-masks.
        *handle
            .last_stop_at
            .lock()
            .unwrap_or_else(|p| p.into_inner()) = Some(std::time::Instant::now());
        let h = &mut handle.inner;
        if let Some(task) = h.task.take() {
            task.abort();
            join_aborted_slipstream_task(&task);
        }
        // [B4-16 drain] abort() cannot cancel an in-flight write-behind commit
        // (`spawn_blocking`) — drain it so a returned stop means the wallet file is
        // QUIESCENT: the host's next write (deleteAccount / importAccount / rewind
        // truncate) can no longer interleave with an orphan commit. Swift hops this
        // call off the cooperative pool (the drain is a real, bounded wait).
        drain_slipstream_wallet_writers(&h.progress);
        *h.state.lock().unwrap_or_else(|p| p.into_inner()) = SyncState::Idle;
        Ok(true)
    });
    unwrap_exc_or(res, false)
}

/// [B4-16 drain] Bounded wait for the engine's in-flight wallet-file writer — the
/// write-behind lane's deferred commit, a `spawn_blocking` closure `task.abort()` cannot
/// cancel. Field evidence (2026-07-04): an orphan commit outlived an `importAccount`
/// restart, collided with the new pass's first writes ("database is locked" →
/// non-transient failure, absorbed by the revival loop) and — worse — landed its
/// Scanned-mark AFTER the import's force-rescan re-queue, silently shrinking the new
/// account's scan scope. Called by stop() and start() right after aborting the task.
/// 10 s cap ≫ the worst observed device commit (a few seconds, A10); on timeout we
/// proceed with a warning — the busy_timeouts remain the backstop.
/// [B4-16 drain] `abort()` is ASYNCHRONOUS — the task keeps running until its next await
/// point, so a synchronous in-flight wallet write (an enhance `decrypt_and_store`, a
/// chain-tip or subtree-roots update — field evidence: a `deleteAccount` landing in that
/// window failed its read→write lock upgrade, "error + try again") can land AFTER
/// `abort()` returns. Wait (bounded) for the task to finish unwinding. Combined with
/// `drain_slipstream_wallet_writers` (the persist lane's `spawn_blocking` commit — the
/// engine's ONLY detached writer), a completed stop/start-abort means the wallet file is
/// FULLY quiescent.
fn join_aborted_slipstream_task(task: &tokio::task::AbortHandle) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !task.is_finished() {
        if std::time::Instant::now() >= deadline {
            tracing::warn!(
                "slipstream stop/start: aborted pass still unwinding after 10 s — proceeding"
            );
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}

fn drain_slipstream_wallet_writers(progress: &slipstream_core::ProgressArc) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let mut waited = false;
    while progress.wallet_writers() > 0 {
        if std::time::Instant::now() >= deadline {
            tracing::warn!(
                "slipstream stop/start: in-flight wallet commit still running after 10 s — proceeding (busy_timeouts remain the backstop)"
            );
            return;
        }
        waited = true;
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    if waited {
        tracing::info!("slipstream stop/start: drained in-flight wallet commit");
    }
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
    let handle = AssertUnwindSafe(handle);
    let res = catch_panic(|| {
        let handle = unsafe { handle.as_ref() }.ok_or_else(|| anyhow!("null handle"))?;
        // Delegate to the inner handle's snapshot() and copy fields into the
        // cbindgen-visible FfiSlipstreamSnapshot defined in this file.
        let s = handle.inner.snapshot();
        Ok(FfiSlipstreamSnapshot {
            chain_tip: s.chain_tip,
            fetched_blocks: s.fetched_blocks,
            scanned_blocks: s.scanned_blocks,
            enhanced_txs: s.enhanced_txs,
            current_range_end: s.current_range_end,
            state: s.state,
            pass_total_blocks: s.pass_total_blocks,
            spendable_hint: s.spendable_hint,
            ranges_completed: s.ranges_completed,
            is_recovering: s.is_recovering,
            progress_permille: s.progress_permille,
            stalled_seconds: s.stalled_seconds,
            tip_fresh: if handle.tip_fresh_now(s.state) { 1 } else { 0 },
            tx_set_version: s.tx_set_version,
        })
    });
    unwrap_exc_or(res, FfiSlipstreamSnapshot::default())
}

impl SlipstreamHandle {
    /// [API v2.1 E-2] Lazily evaluates + latches tip freshness — the exact
    /// `shouldMarkChainTipUpdated` semantics the SDK derived host-side:
    /// - already fresh → stays fresh (until a >120 s stop→start gap re-masks in `start()`);
    /// - the refresh counter advanced past its `start()` baseline → the engine bumps it
    ///   only AFTER `session.update_chain_tip` succeeds, so an advance proves THIS run
    ///   refreshed the wallet-DB tip (counter-based so the E-3 DB-seeded tip can neither
    ///   fake freshness nor mask a refresh that fetched the same height);
    /// - otherwise → trust only a pass that reached Done (state 3): `sync_once` cannot
    ///   complete without `update_chain_tip` having succeeded.
    fn tip_fresh_now(&self, state: u8) -> bool {
        use std::sync::atomic::Ordering;
        if self.tip_fresh.load(Ordering::Relaxed) {
            return true;
        }
        let advanced = self.inner.progress.tip_refreshes()
            > self.tip_refreshes_at_run_start.load(Ordering::Relaxed);
        if advanced || state == 3 {
            self.tip_fresh.store(true, Ordering::Relaxed);
            return true;
        }
        false
    }
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
    let handle = AssertUnwindSafe(handle);
    let res = catch_panic(|| {
        let handle = unsafe { handle.as_ref() }.ok_or_else(|| anyhow!("null handle"))?;
        // [E-4] The version counter is the primary signal (snapshot-carried, loss-proof);
        // the tag-5 event stays for hosts that consume the ring.
        handle.inner.progress.bump_tx_set_version();
        handle
            .inner
            .push_event(slipstream_core::ffi_handle::FfiSlipstreamEvent { tag: 5, value: 0 });
        Ok(true)
    });
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
    let res = catch_panic(|| {
        let host =
            std::str::from_utf8(unsafe { slice::from_raw_parts(server_host, server_host_len) })
                .map_err(|e| anyhow!("server_host UTF-8: {e}"))?;
        let network = if network_id == 1 { MainNetwork } else { TestNetwork };
        let endpoint = slipstream_core::config::Endpoint {
            host: host.to_string(),
            port: server_port,
            tls: use_tls,
        };
        let tor_dir_opt: Option<std::path::PathBuf> = if tor_dir.is_null() || tor_dir_len == 0 {
            None
        } else {
            Some(
                Path::new(OsStr::from_bytes(unsafe {
                    slice::from_raw_parts(tor_dir, tor_dir_len)
                }))
                .to_path_buf(),
            )
        };
        let intent = if intent == 1 {
            slipstream_core::anchor::AnchorIntent::Restore {
                birthday,
                fallback_checkpoint: fallback_checkpoint_height,
            }
        } else {
            slipstream_core::anchor::AnchorIntent::New
        };

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| anyhow!("tokio runtime: {e}"))?;
        let anchor = runtime.block_on(async {
            let tor_conn = match &tor_dir_opt {
                Some(dir) => {
                    match slipstream_core::connector::TorConn::bootstrap(dir, false).await {
                        Ok(t) => Some(t),
                        Err(e) => {
                            tracing::warn!(
                                error = %e,
                                "anchor: Tor bootstrap failed — resolving OFFLINE (no direct fallback)"
                            );
                            return slipstream_core::anchor::offline_anchor(intent);
                        }
                    }
                }
                None => None,
            };
            slipstream_core::anchor::restore_anchor(&endpoint, network, intent, tor_conn.as_ref())
                .await
        });

        let (ts_ptr, ts_len) = match anchor.treestate {
            Some(ts) => ptr_from_vec(ts.encode_to_vec()),
            None => (std::ptr::null_mut(), 0),
        };
        Ok(Box::into_raw(Box::new(FfiRestoreAnchor {
            height: anchor.height,
            treestate: ts_ptr,
            treestate_len: ts_len,
        })))
    });
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
    if !ptr.is_null() {
        let anchor = unsafe { Box::from_raw(ptr) };
        free_ptr_from_vec(anchor.treestate, anchor.treestate_len);
        drop(anchor);
    }
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
    let handle = AssertUnwindSafe(handle);
    let res = catch_panic(|| {
        let handle = unsafe { handle.as_ref() }.ok_or_else(|| anyhow!("null handle"))?;
        let network = handle.inner.network;
        let db_path = handle.inner.wallet_db_path.clone();
        let snap = handle.inner.snapshot();

        // ── [API v2.1 E-1] Serve-cached + refresh policy — the walk is rationed HERE, so
        // hosts may call this whenever they like (per poll tick included):
        //   • no cache yet → ONE synchronous walk (in practice: the host's prepare/open-time
        //     call, when the engine is quiet);
        //   • cache exists → serve it immediately, and — when the pass crossed a range
        //     boundary, the state changed, or (outside a scan) the idle TTL elapsed — spawn
        //     ONE background walk (plain thread; owns only clones + Arcs, so it is safe
        //     against `free()` racing it) that swaps the cache for later calls.
        // Between boundaries while Syncing, NO walk ever runs: the T5.5
        // no-summary-while-scanning invariant, now engine-owned. The recovery-balance
        // REPLACEMENT below is NOT cached — it re-reads the cheap view on every call, so a
        // recovering host sees the per-tick climb.
        let cached: Option<SummaryCacheEntry> = {
            let guard = handle
                .summary_cache
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            guard.as_ref().map(|e| SummaryCacheEntry {
                captured_at: e.captured_at,
                ranges_completed: e.ranges_completed,
                state: e.state,
                summary: e.summary.clone(),
            })
        };

        let summary = match cached {
            None => {
                // First call on this handle: walk synchronously and prime the cache.
                let path_bytes = db_path.as_os_str().as_bytes();
                let db_data =
                    unsafe { wallet_db(path_bytes.as_ptr(), path_bytes.len(), network)? };
                let policy = wallet::ConfirmationsPolicy::try_from(confirmations_policy)?;
                let walked = db_data
                    .get_wallet_summary(policy)
                    .map_err(|e| anyhow!("Error while fetching wallet summary: {}", e))?;
                if let Some(ref s) = walked {
                    *handle
                        .summary_cache
                        .lock()
                        .unwrap_or_else(|p| p.into_inner()) = Some(SummaryCacheEntry {
                        captured_at: std::time::Instant::now(),
                        ranges_completed: snap.ranges_completed,
                        state: snap.state,
                        summary: s.clone(),
                    });
                }
                match walked {
                    Some(s) => s,
                    None => return Ok(ffi::WalletSummary::none()),
                }
            }
            Some(entry) => {
                let boundary_crossed = snap.ranges_completed != entry.ranges_completed
                    || snap.state != entry.state;
                let idle_ttl_due =
                    snap.state != 1 && entry.captured_at.elapsed() >= SUMMARY_IDLE_TTL;
                if (boundary_crossed || idle_ttl_due)
                    && !handle
                        .summary_refresh_inflight
                        .swap(true, std::sync::atomic::Ordering::SeqCst)
                {
                    let cache = std::sync::Arc::clone(&handle.summary_cache);
                    let inflight = std::sync::Arc::clone(&handle.summary_refresh_inflight);
                    let thread_db_path = db_path.clone();
                    let thread_policy = confirmations_policy;
                    let (ranges_at, state_at) = (snap.ranges_completed, snap.state);
                    std::thread::spawn(move || {
                        let walk = || -> anyhow::Result<
                            Option<zcash_client_backend::data_api::WalletSummary<AccountUuid>>,
                        > {
                            let path_bytes = thread_db_path.as_os_str().as_bytes();
                            let db_data = unsafe {
                                wallet_db(path_bytes.as_ptr(), path_bytes.len(), network)?
                            };
                            let policy =
                                wallet::ConfirmationsPolicy::try_from(thread_policy)?;
                            db_data
                                .get_wallet_summary(policy)
                                .map_err(|e| anyhow!("summary refresh: {}", e))
                        };
                        if let Ok(Some(s)) = walk() {
                            *cache.lock().unwrap_or_else(|p| p.into_inner()) =
                                Some(SummaryCacheEntry {
                                    captured_at: std::time::Instant::now(),
                                    ranges_completed: ranges_at,
                                    state: state_at,
                                    summary: s,
                                });
                        }
                        inflight.store(false, std::sync::atomic::Ordering::SeqCst);
                    });
                }
                entry.summary
            }
        };

        let summary_ptr = ffi::WalletSummary::some(summary)?;

        // Phase resolution. `is_recovering` carries the engine's fail-safe latch (terminal
        // Done/Error force 0), so a dead pass falls back to the upstream summary here too.
        if snap.is_recovering == 1 {
            let conn = rusqlite::Connection::open(&db_path)
                .map_err(|e| anyhow!("recovery balance open: {}", e))?;
            conn.busy_timeout(std::time::Duration::from_secs(5))
                .map_err(|e| anyhow!("recovery balance busy_timeout: {}", e))?;
            let mut nets: std::collections::HashMap<[u8; 16], i64> = std::collections::HashMap::new();
            {
                let mut stmt = conn
                    .prepare("SELECT account_uuid, balance_zat FROM slipstream_v_recovery_balance")
                    .map_err(|e| anyhow!("recovery balance prepare: {}", e))?;
                let mut rows = stmt
                    .query([])
                    .map_err(|e| anyhow!("recovery balance query: {}", e))?;
                while let Some(row) = rows.next().map_err(|e| anyhow!("recovery balance row: {}", e))? {
                    let uuid: Vec<u8> = row.get(0).map_err(|e| anyhow!("recovery balance uuid: {}", e))?;
                    let net: i64 = row.get(1).map_err(|e| anyhow!("recovery balance net: {}", e))?;
                    if let Ok(uuid16) = <[u8; 16]>::try_from(uuid.as_slice()) {
                        nets.insert(uuid16, net);
                    }
                }
            }
            // Accounts with no reconciled rows yet read 0 — the SDK's `?? .zero` semantics.
            let summary_mut = unsafe { &mut *summary_ptr };
            for balance in summary_mut.account_balances_mut() {
                let net = nets.get(balance.uuid_bytes()).copied().unwrap_or(0);
                balance.override_with_recovery_net(net);
            }
        }
        Ok(summary_ptr)
    });
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
    let handle = AssertUnwindSafe(handle);
    let buf = AssertUnwindSafe(buf);
    let res = catch_panic(|| {
        let handle = unsafe { handle.as_mut() }.ok_or_else(|| anyhow!("null handle"))?;
        let mut ring = handle.inner.events.lock().unwrap_or_else(|p| p.into_inner());
        let to_copy = ring.len().min(buf_len);
        // Convert from the ffi_handle event type to the cbindgen-visible
        // FfiSlipstreamEvent (defined in this file). Both are repr(C); copy fields.
        let drained: Vec<FfiSlipstreamEvent> = ring
            .drain(..to_copy)
            .map(|e| FfiSlipstreamEvent { tag: e.tag, value: e.value })
            .collect();
        // SAFETY: buf is valid for writes for buf_len elements (caller contract above).
        unsafe { std::ptr::copy_nonoverlapping(drained.as_ptr(), *buf, to_copy) };
        Ok(to_copy)
    });
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
    if !handle.is_null() {
        // SAFETY: handle is non-null and was returned by zcashlc_slipstream_open (caller
        // contract). We take ownership here and drop it at end of scope.
        let mut h: Box<SlipstreamHandle> = unsafe { Box::from_raw(handle) };
        // Abort the in-flight task before dropping the runtime; dropping a Runtime with
        // live tasks causes a panic on some platforms.
        if let Some(task) = h.inner.task.take() {
            task.abort();
        }
        drop(h);
    }
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
    true
}
