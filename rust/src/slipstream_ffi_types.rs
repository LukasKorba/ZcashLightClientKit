//! C-ABI types shared by the two Slipstream FFI flavors.
//!
//! These `#[repr(C)]` types appear in the signatures of the `zcashlc_slipstream_*`
//! functions. They compile UNGATED — in both the `slipstream` (real engine, see
//! `slipstream_ffi.rs`) and stub (`slipstream_ffi_stubs.rs`) flavors — so cbindgen
//! emits byte-identical struct definitions into `zcashlc.h` regardless of which
//! flavor produced the header (Gate 1b: header parity).

/// C-compatible snapshot of Slipstream engine progress. Returned by
/// [`zcashlc_slipstream_snapshot`] (by value — no heap allocation).
///
/// Sync state codes: 0 = idle, 1 = syncing, 2 = error, 3 = done.
#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct FfiSlipstreamSnapshot {
    /// Current chain tip height as reported by the server (0 = not yet fetched).
    pub chain_tip: u64,
    /// Number of compact blocks fetched in the current/last sync pass.
    pub fetched_blocks: u64,
    /// Number of compact blocks scanned in the current/last sync pass.
    pub scanned_blocks: u64,
    /// Number of transactions enhanced in the current/last sync pass.
    pub enhanced_txs: u64,
    /// End height of the block range currently being processed.
    pub current_range_end: u64,
    /// Sync state: 0 = idle, 1 = syncing, 2 = error, 3 = done.
    pub state: u8,
    // ── T5.5 counter-based progress fields (appended at END for padding stability) ──
    /// Total blocks in the current pass. Set (not accumulated) by the scheduler each time
    /// suggest_scan_ranges returns: value = scanned_so_far + sum(all returned ranges).
    /// Denominator for counter-based progress: scanned_blocks / pass_total_blocks.
    pub pass_total_blocks: u64,
    /// Spendable hint: 0 = not yet spendable; 1 = a ChainTip-priority range has completed
    /// scanning (≈ SBS funds-spendable semantics). Latches to 1; never resets within a pass.
    pub spendable_hint: u8,
    // ── T5.6 range-boundary signals (appended at END for padding stability) ──
    /// Number of suggested ranges whose scan+enhancement has completed in the current pass.
    /// Swift observes this counter and triggers ONE balance-summary fetch per boundary.
    pub ranges_completed: u64,
    // ── API v2 fields (appended at END for padding stability) ──
    /// 1 while the wallet is inside its recovery (restore backfill) window; engine-computed
    /// with the fail-safe latch built in (terminal Done/Error force 0).
    pub is_recovering: u8,
    /// Blessed progress, 0..=1000, session-monotonic (never regresses while the handle
    /// lives; Done forces 1000). Replaces host-side progress math.
    pub progress_permille: u16,
    /// Seconds since last forward progress while syncing; 0 otherwise.
    pub stalled_seconds: u32,
    // ── API v2.1 fields (appended at END for padding stability) ──
    /// [E-2] 1 once the CURRENT run has refreshed the wallet-DB chain tip (the [#1591]
    /// stale-tip fact, engine-owned): the engine's tip-refresh counter advanced past its
    /// `start()` baseline (bumped only after `update_chain_tip` succeeds), or a pass
    /// reached Done. Survives stop→start hops shorter than 120 s. While 0, hosts must
    /// mask spendable balances (the mask transform stays host-side because the C
    /// `AccountBalance` cannot express the awaiting-resolution shift).
    pub tip_fresh: u8,
    /// [E-4] Monotonic version of the wallet's stored transaction set: bumps exactly when
    /// enhancement stores/updates a tx, the mempool monitor stores a 0-conf hit, a range
    /// boundary detects a reconcile-linkage transition, or the host pokes
    /// [`zcashlc_slipstream_notify_tx_change`] after a submit. Host rule (one line):
    /// version moved since the last poll → re-fetch transactions + publish
    /// `foundTransactions`. Never reset while the handle lives.
    pub tx_set_version: u64,
}

/// [API v2.1 E-6] C-compatible wallet-provisioning anchor. Returned by
/// [`zcashlc_slipstream_restore_anchor`]; free with
/// [`zcashlc_slipstream_free_restore_anchor`].
///
/// RESTORE intent: `height` = the recover_until height (always valid by policy — live tip
/// or the offline `max(checkpoint, birthday+1)` fallback); `treestate` null.
/// NEW intent: `height` + serialized `TreeState` protobuf bytes = the reorg-safe recent
/// tree state; `height` 0 + null `treestate` when offline (host keeps its checkpoint).
#[repr(C)]
pub struct FfiRestoreAnchor {
    /// See the type docs — recover_until (restore) or the anchor height (new).
    pub height: u64,
    /// Serialized `TreeState` protobuf bytes, or null (see the type docs).
    pub treestate: *mut u8,
    /// Length of `treestate` (0 when null).
    pub treestate_len: usize,
}

/// C-compatible Slipstream engine event record. Returned by
/// [`zcashlc_slipstream_drain_events`] in a caller-allocated buffer.
///
/// Event tags: 1 = SyncStarted, 2 = SyncProgress, 3 = SyncDone,
/// 4 = SyncError, 5 = FoundTransactions.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FfiSlipstreamEvent {
    /// Event tag (see type documentation for values).
    pub tag: u8,
    /// For SyncDone: transactions stored. For SyncError: error code. Others: 0.
    pub value: u64,
}
