//
//  Broadcaster.swift
//  ZcashLightClientKit
//
//  Created by Adam Tucker on 2026-04-15.
//

import Foundation

/// Protocol for creating transactions without immediate submission,
/// and for submitting raw transaction data to specific endpoints.
///
/// This separates the concerns of transaction creation and network
/// submission from the broader synchronization lifecycle managed
/// by ``Synchronizer``. Use this to implement custom broadcast
/// strategies such as submitting to multiple lightwalletd servers
/// in parallel.
///
/// Typical usage:
/// ```swift
/// // 1. Create the transaction(s)
/// let txs = try await synchronizer.broadcaster.createProposedTransactions(
///     proposal: proposal, spendingKey: spendingKey
/// )
///
/// // 2. Submit to one or more endpoints
/// for endpoint in endpoints {
///     try await synchronizer.broadcaster.submit(txs[0].raw!, to: endpoint)
/// }
/// ```
public protocol Broadcaster: AnyObject {
    /// Creates the transactions in the given proposal without submitting
    /// them to the network.
    ///
    /// - Parameter proposal: the proposal for which to create transactions.
    /// - Parameter spendingKey: the `UnifiedSpendingKey` associated with the
    ///   account for which the proposal was created.
    /// - Returns: An array of transaction overviews. Each overview's `raw`
    ///   property contains the serialized transaction bytes suitable for
    ///   later submission via ``submit(_:to:)``.
    ///
    /// If `prepare()` hasn't already been called since creation of the
    /// synchronizer instance or since the last wipe then this method throws
    /// `ZcashError.synchronizerNotPrepared`.
    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey
    ) async throws -> [ZcashTransaction.Overview]

    /// Finalizes a PCZT that has been separately proven and signed,
    /// stores it in the wallet, and returns the resulting transactions
    /// without submitting them to the network.
    ///
    /// - Parameter pcztWithProofs: the PCZT with proofs added.
    /// - Parameter pcztWithSigs: the PCZT with signatures added.
    /// - Returns: An array of transaction overviews with `raw` bytes.
    ///
    /// If `prepare()` hasn't already been called since creation of the
    /// synchronizer instance or since the last wipe then this method throws
    /// `ZcashError.synchronizerNotPrepared`.
    func createTransactionFromPCZT(
        pcztWithProofs: Pczt,
        pcztWithSigs: Pczt
    ) async throws -> [ZcashTransaction.Overview]

    /// Submits raw transaction bytes to a specific lightwalletd endpoint.
    ///
    /// Creates an ephemeral connection to the given endpoint, submits the
    /// transaction, and tears down the connection. Respects the current
    /// Tor configuration.
    ///
    /// - Parameter rawTransaction: the raw serialized transaction bytes.
    /// - Parameter endpoint: the `LightWalletEndpoint` to submit to.
    func submit(
        _ rawTransaction: Data,
        to endpoint: LightWalletEndpoint
    ) async throws
}

// MARK: - Multi-endpoint submission types

/// A transaction created locally, not yet broadcast to the network.
public struct CreatedTransaction: Equatable {
    /// The transaction id (also known as `rawID`).
    public let txId: Data
    /// The serialized transaction bytes suitable for submission.
    public let raw: Data
    /// The height at which the transaction expires, if known.
    public let expiryHeight: BlockHeight?
}

extension CreatedTransaction {
    /// - Throws: `TransactionEncoderError.notEncoded` when the overview carries no raw bytes.
    ///   Encoder-created transactions always do; a nil here is an invariant violation.
    init(overview: ZcashTransaction.Overview) throws {
        guard let raw = overview.raw else {
            throw TransactionEncoderError.notEncoded(txId: overview.rawID)
        }
        self.txId = overview.rawID
        self.raw = raw
        self.expiryHeight = overview.expiryHeight
    }

    var encodedTransaction: EncodedTransaction {
        EncodedTransaction(transactionId: txId, raw: raw)
    }
}

/// Timing knobs for multi-endpoint submission.
public struct SubmissionTiming: Equatable {
    /// How long to wait for the first endpoint decision before declaring timeout.
    public let responseTimeout: TimeInterval
    /// After the first acceptance, how long remaining in-flight submissions may
    /// continue (best-effort propagation) before being cancelled.
    public let postAcceptanceGraceDelay: TimeInterval

    public static let `default` = SubmissionTiming(responseTimeout: 30, postAcceptanceGraceDelay: 5)

    public init(responseTimeout: TimeInterval, postAcceptanceGraceDelay: TimeInterval) {
        self.responseTimeout = responseTimeout
        self.postAcceptanceGraceDelay = postAcceptanceGraceDelay
    }
}

/// Per-transaction outcome of a multi-endpoint submission.
public enum TransactionSubmissionOutcome: Equatable {
    /// At least one endpoint accepted the transaction.
    case accepted(by: LightWalletEndpoint)
    /// Every endpoint responded and none accepted. Carries the first
    /// lightwalletd rejection (error code + message) that was observed.
    case rejected(code: Int, message: String)
    /// Every endpoint failed at the transport level (gRPC/connection error);
    /// no server-level rejection was observed.
    case unreachable
    /// No endpoint produced a decision within `responseTimeout`. The transaction
    /// may still have been broadcast — treat as pending, not failed.
    case timedOut
    /// Skipped because an earlier transaction in the batch was not accepted.
    case notAttempted
    /// The submission was cancelled by the caller.
    case cancelled
}

public struct TransactionSubmissionReport: Equatable {
    public let txId: Data
    public let outcome: TransactionSubmissionOutcome
}
