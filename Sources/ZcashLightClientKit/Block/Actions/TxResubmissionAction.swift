//
//  TxResubmissionAction.swift
//
//
//  Created by Lukas Korba on 06-17-2024.
//

import Foundation

final class TxResubmissionAction {
    private enum Constants {
        static let thresholdToTrigger = TimeInterval(300.0)
    }

    var latestResolvedTime: TimeInterval = 0
    let transactionRepository: TransactionRepository
    var transactionEncoder: TransactionEncoder
    let submitPlanStore: SubmitPlanStoring
    let submitPlanExecutor: SubmitPlanExecutor
    let logger: Logger

    init(container: DIContainer) {
        transactionRepository = container.resolve(TransactionRepository.self)
        transactionEncoder = container.resolve(TransactionEncoder.self)
        submitPlanStore = container.resolve(SubmitPlanStoring.self)
        submitPlanExecutor = container.resolve(SubmitPlanExecutor.self)
        logger = container.resolve(Logger.self)
    }
}

extension TxResubmissionAction: Action {
    var removeBlocksCacheWhenFailed: Bool { true }

    func run(with context: ActionContext, didUpdate: @escaping (CompactBlockProcessor.Event) async -> Void) async throws -> ActionContext {
        let latestBlockHeight = await context.syncControlData.latestBlockHeight

        // Plans whose transactions are mined, expired, or gone are no longer
        // retry candidates; drop them. Decisions are made per transaction from
        // current repository state, so a transaction created mid-pass can never
        // be wrongly pruned (it is by definition present, unmined, unexpired).
        await pruneStalePlans(latestBlockHeight: latestBlockHeight)

        // find all candidates for the resubmission
        do {
            logger.info("TxResubmissionAction check started at \(latestBlockHeight) height.")
            let transactions = try await transactionRepository.findForResubmission(upTo: latestBlockHeight)

            // no candidates, update the time and continue with the next action
            if transactions.isEmpty {
                latestResolvedTime = Date().timeIntervalSince1970
            } else {
                let now = Date().timeIntervalSince1970
                let diff = now - latestResolvedTime

                // the last time resubmission was triggered is more than 5 minutes ago so try again
                if diff > Constants.thresholdToTrigger {
                    // resubmission
                    do {
                        for transaction in transactions {
                            try await resubmit(transaction: transaction)
                        }
                    } catch {
                        logger.error("TxResubmissionAction failed to resubmit candidates.")
                    }

                    latestResolvedTime = Date().timeIntervalSince1970
                }
            }
        } catch {
            logger.error("TxResubmissionAction failed to find candidates.")
        }

        if await context.prevState == .enhance {
            await context.update(state: .updateChainTip)
        } else {
            await context.update(state: .finished)
        }
        return context
    }

    func stop() async { }
}

private extension TxResubmissionAction {
    func resubmit(transaction: ZcashTransaction.Overview) async throws {
        let plan = await submitPlanStore.plan(for: transaction.rawID)

        switch plan {
        case .awaiting:
            // Created through Broadcaster but never submitted by the app —
            // resubmitting would broadcast something the user may have cancelled.
            logger.info(
                "TxResubmissionAction skipping transaction \(transaction.rawID.toHexStringTxId()) until it is submitted by the app."
            )

        case .ready(let endpoints):
            logger.info("TxResubmissionAction trying to resubmit transaction \(transaction.rawID.toHexStringTxId()) via its submit plan.")
            let createdTransaction = try CreatedTransaction(overview: transaction)
            try await submitPlanExecutor.submit(transaction: createdTransaction, endpoints: endpoints)

        case nil:
            logger.info("TxResubmissionAction trying to resubmit transaction \(transaction.rawID.toHexStringTxId()).")
            let encodedTransaction = try transaction.encodedTransaction()
            try await transactionEncoder.submit(transaction: encodedTransaction)
        }
    }

    func pruneStalePlans(latestBlockHeight: BlockHeight) async {
        let plannedTxIds = await submitPlanStore.allPlannedTransactionIds()
        guard !plannedTxIds.isEmpty else { return }

        var staleTxIds: [Data] = []
        for txId in plannedTxIds {
            do {
                let transaction = try await transactionRepository.find(rawID: txId)
                let isCandidate = transaction.minedHeight == nil && (transaction.expiryHeight ?? 0) > latestBlockHeight
                if !isCandidate {
                    staleTxIds.append(txId)
                }
            } catch ZcashError.transactionRepositoryEntityNotFound {
                staleTxIds.append(txId)
            } catch {
                // Unknown repository error — keep the plan, try again next pass.
                logger.warn("TxResubmissionAction could not check plan staleness: \(error)")
            }
        }

        if !staleTxIds.isEmpty {
            logger.info("TxResubmissionAction pruning \(staleTxIds.count) stale submit plan(s).")
            await submitPlanStore.deletePlans(txIds: staleTxIds)
        }
    }
}
