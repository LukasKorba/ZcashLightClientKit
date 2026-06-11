//
//  TxResubmissionActionTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class TxResubmissionActionTests: ZcashTestCase {
    private var transactionRepository: TransactionRepositoryMock!
    private var transactionEncoder: StubTransactionEncoder!
    private var submitPlanStore: SubmitPlanStoringMock!
    private var endpointSubmitter: EndpointSubmitterMock!

    private let latestBlockHeight = BlockHeight(2_000_000)

    private var endpointA: LightWalletEndpoint {
        LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
    }

    private func makeOverview(
        rawID: Data,
        minedHeight: BlockHeight? = nil,
        expiryHeight: BlockHeight? = 3_000_000
    ) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: TestsData.mockedAccountUUID,
            blockTime: nil,
            expiryHeight: expiryHeight,
            fee: Zatoshi(10_000),
            index: 0,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: minedHeight,
            raw: Data([0x01, 0x02, 0x03]),
            rawID: rawID,
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-1_000),
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil
        )
    }

    private func setupAction(
        candidates: [ZcashTransaction.Overview],
        encoderTransactions: [ZcashTransaction.Overview] = []
    ) -> TxResubmissionAction {
        transactionRepository = TransactionRepositoryMock()
        transactionRepository.findForResubmissionUpToClosure = { _ in candidates }
        transactionEncoder = StubTransactionEncoder(createdTransactions: encoderTransactions)
        submitPlanStore = SubmitPlanStoringMock()
        endpointSubmitter = EndpointSubmitterMock()

        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in self.transactionRepository }
        mockContainer.mock(type: TransactionEncoder.self, isSingleton: true) { _ in self.transactionEncoder }
        mockContainer.mock(type: SubmitPlanStoring.self, isSingleton: true) { _ in self.submitPlanStore }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in NullLogger() }
        mockContainer.mock(type: SubmitPlanExecutor.self, isSingleton: true) { _ in
            SubmitPlanExecutor(endpointSubmitter: self.endpointSubmitter, logger: NullLogger())
        }

        return TxResubmissionAction(container: mockContainer)
    }

    private func makeContext() -> ActionContextMock {
        let context = ActionContextMock.default()
        context.prevState = .enhance
        context.underlyingSyncControlData = SyncControlData(
            latestBlockHeight: latestBlockHeight,
            latestScannedHeight: nil,
            firstUnenhancedHeight: nil
        )
        return context
    }

    func testAwaitingTransactionIsSkipped() async throws {
        let rawID = Data(repeating: 0x01, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        await submitPlanStore.markAwaitingSubmission(txIds: [rawID])
        // Make the repository confirm the candidate is alive so pruning keeps it.
        transactionRepository.findRawIDClosure = { _ in candidate }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertTrue(transactionEncoder.submittedTransactions.isEmpty, "Awaiting transactions must not be submitted")
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
        let plan = await submitPlanStore.plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.awaiting, "Awaiting plan must survive")
    }

    func testReadyTransactionIsResubmittedThroughPlanEndpoints() async throws {
        let rawID = Data(repeating: 0x02, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        await submitPlanStore.recordPlan(txId: rawID, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { _ in candidate }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertEqual(endpointSubmitter.recordedSubmissions().map(\.host), ["a.example.com"])
        XCTAssertTrue(transactionEncoder.submittedTransactions.isEmpty, "Plan transactions must not use the default endpoint")
    }

    func testLegacyTransactionUsesDefaultEncoderSubmit() async throws {
        let rawID = Data(repeating: 0x03, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertEqual(transactionEncoder.submittedTransactions.count, 1)
        XCTAssertEqual(transactionEncoder.submittedTransactions.first?.transactionId, rawID)
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
    }

    func testPruningRemovesMinedExpiredMissingAndNilExpiryPlans() async throws {
        let minedTxId = Data(repeating: 0x04, count: 32)
        let expiredTxId = Data(repeating: 0x05, count: 32)
        let missingTxId = Data(repeating: 0x06, count: 32)
        let nilExpiryTxId = Data(repeating: 0x08, count: 32)
        let aliveTxId = Data(repeating: 0x07, count: 32)

        let action = setupAction(candidates: [])
        await submitPlanStore.recordPlan(txId: minedTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: expiredTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: missingTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: nilExpiryTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: aliveTxId, endpoints: [endpointA])

        transactionRepository.findRawIDClosure = { rawID in
            if rawID == minedTxId {
                return self.makeOverview(rawID: rawID, minedHeight: 1_999_000)
            }
            if rawID == expiredTxId {
                return self.makeOverview(rawID: rawID, expiryHeight: 1_999_999)
            }
            if rawID == missingTxId {
                throw ZcashError.transactionRepositoryEntityNotFound
            }
            if rawID == nilExpiryTxId {
                return self.makeOverview(rawID: rawID, expiryHeight: nil)
            }
            return self.makeOverview(rawID: rawID)
        }

        _ = try await action.run(with: makeContext()) { _ in }

        let remaining = await submitPlanStore.allPlannedTransactionIds()
        XCTAssertEqual(Set(remaining), Set([aliveTxId]))
    }

    func testNoCandidatesStillPrunes() async throws {
        let staleTxId = Data(repeating: 0x09, count: 32)
        let action = setupAction(candidates: [])
        await submitPlanStore.recordPlan(txId: staleTxId, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { _ in
            throw ZcashError.transactionRepositoryEntityNotFound
        }

        _ = try await action.run(with: makeContext()) { _ in }

        let remaining = await submitPlanStore.allPlannedTransactionIds()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testUnknownRepositoryErrorKeepsPlanDuringPruning() async throws {
        struct TransientDatabaseError: Error {}
        let txId = Data(repeating: 0x0A, count: 32)
        let action = setupAction(candidates: [])
        await submitPlanStore.recordPlan(txId: txId, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { _ in
            throw TransientDatabaseError()
        }

        _ = try await action.run(with: makeContext()) { _ in }

        let remaining = await submitPlanStore.allPlannedTransactionIds()
        XCTAssertEqual(remaining, [txId], "A transient repository error must not prune a live retry plan")
    }
}
