//
//  EnhanceFailureTracker.swift
//  ZcashLightClientKit
//

import Foundation

/// Tracks per-txid enhance failures so `BlockEnhancer` can back off cross-cycle on a tx that
/// has repeatedly failed to enhance against the current lightwalletd endpoint. Without this,
/// the rust backend keeps re-queueing the same `TransactionDataRequest` every sync cycle and
/// the SDK keeps hammering the server with retries that immediately fail again.
actor EnhanceFailureTracker {
    private enum Constants {
        /// Base wait after the first failure before retrying across sync cycles.
        static let baseBackoff: TimeInterval = 60
        /// Cap so an unbounded exponential never extends past 30 minutes.
        static let maxBackoff: TimeInterval = 1800
        /// Drop entries older than this to keep the map bounded.
        static let maxRetention: TimeInterval = 7200
    }

    private struct Record {
        let attemptCount: Int
        let lastAttemptAt: TimeInterval
    }

    private var failuresByTxId: [Data: Record] = [:]
    private let clock: @Sendable () -> TimeInterval

    init(clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.clock = clock
    }

    func shouldSkipDueToBackoff(txId: Data) -> Bool {
        guard let record = failuresByTxId[txId] else { return false }
        let backoff = backoffFor(attempt: record.attemptCount)
        return (clock() - record.lastAttemptAt) < backoff
    }

    func recordFailure(txId: Data) {
        let now = clock()
        let previous = failuresByTxId[txId]
        failuresByTxId[txId] = Record(
            attemptCount: (previous?.attemptCount ?? 0) + 1,
            lastAttemptAt: now
        )
        failuresByTxId = failuresByTxId.filter { now - $0.value.lastAttemptAt < Constants.maxRetention }
    }

    func recordSuccess(txId: Data) {
        failuresByTxId.removeValue(forKey: txId)
    }

    private func backoffFor(attempt: Int) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let raw = Constants.baseBackoff * pow(2.0, Double(exponent))
        return min(raw, Constants.maxBackoff)
    }
}
