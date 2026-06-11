//
//  MultiEndpointSubmitterTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class MultiEndpointSubmitterTests: ZcashTestCase {
    private var mock: EndpointSubmitterMock!
    private var submitter: MultiEndpointSubmitter!

    override func setUp() async throws {
        try await super.setUp()
        mock = EndpointSubmitterMock()
        submitter = MultiEndpointSubmitter(endpointSubmitter: mock, logger: NullLogger())
    }

    private let fastTiming = SubmissionTiming(responseTimeout: 1.0, postAcceptanceGraceDelay: 0.3)

    private func endpoint(_ index: Int) -> LightWalletEndpoint {
        LightWalletEndpoint(address: "server\(index).example.com", port: 9067, secure: true)
    }

    private func makeTransaction() -> CreatedTransaction {
        CreatedTransaction(
            txId: Data(repeating: 0xAB, count: 32),
            raw: Data([0x01, 0x02, 0x03]),
            expiryHeight: 123_456
        )
    }

    func testEmptyEndpointListIsUnreachable() async {
        let outcome = await submitter.submit(transaction: makeTransaction(), to: [], timing: fastTiming)
        XCTAssertEqual(outcome, TransactionSubmissionOutcome.unreachable)
        XCTAssertTrue(mock.recordedSubmissions().isEmpty)
    }

    func testFirstSuccessWinsAndAllEndpointsAreAttempted() async {
        let endpoints = [endpoint(1), endpoint(2), endpoint(3)]
        mock.set(behavior: .succeed, for: endpoint(1))
        mock.set(behavior: .succeed, for: endpoint(2))
        mock.set(behavior: .succeed, for: endpoint(3))

        let outcome = await submitter.submit(transaction: makeTransaction(), to: endpoints, timing: fastTiming)

        guard case let .accepted(winner) = outcome else {
            XCTFail("Expected accepted, got \(outcome)")
            return
        }
        XCTAssertTrue(endpoints.contains(winner))
        XCTAssertEqual(mock.recordedSubmissions().count, 3)
    }

    func testAllRejectedReturnsFirstRejection() async {
        let endpoints = [endpoint(1), endpoint(2)]
        mock.set(behavior: .reject(code: -25, message: "first"), for: endpoint(1))
        mock.set(behavior: .reject(code: -26, message: "second"), for: endpoint(2))

        let outcome = await submitter.submit(transaction: makeTransaction(), to: endpoints, timing: fastTiming)

        guard case let .rejected(code, _) = outcome else {
            XCTFail("Expected rejected, got \(outcome)")
            return
        }
        // Either rejection can win the race to the actor; both are valid "first" rejections.
        XCTAssertTrue([-25, -26].contains(code))
    }

    func testAllTransportFailuresAreUnreachable() async {
        let endpoints = [endpoint(1), endpoint(2)]
        mock.set(behavior: .failTransport, for: endpoint(1))
        mock.set(behavior: .failTransport, for: endpoint(2))

        let outcome = await submitter.submit(transaction: makeTransaction(), to: endpoints, timing: fastTiming)

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.unreachable)
    }

    func testMixedRejectionAndTransportFailureIsRejected() async {
        let endpoints = [endpoint(1), endpoint(2)]
        mock.set(behavior: .failTransport, for: endpoint(1))
        mock.set(behavior: .reject(code: -25, message: "bad tx"), for: endpoint(2))

        let outcome = await submitter.submit(transaction: makeTransaction(), to: endpoints, timing: fastTiming)

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.rejected(code: -25, message: "bad tx"))
    }

    func testSuccessWithHangingEndpointResolvesImmediatelyAndCancelsAfterGrace() async {
        let endpoints = [endpoint(1), endpoint(2)]
        mock.set(behavior: .succeed, for: endpoint(1))
        mock.set(behavior: .hang, for: endpoint(2))

        let start = Date()
        let outcome = await submitter.submit(transaction: makeTransaction(), to: endpoints, timing: fastTiming)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.accepted(by: endpoint(1)))
        // Caller resumes at the first acceptance — long before the 1s timeout.
        XCTAssertLessThan(elapsed, 0.25)

        // The hanging straggler gets cancelled once the grace window ends.
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(mock.recordedCancellations().map(\.host), [endpoint(2).host])
    }

    func testStragglerSuccessDuringGraceIsAllowedToFinish() async {
        let endpoints = [endpoint(1), endpoint(2)]
        mock.set(behavior: .succeed, for: endpoint(1))
        mock.set(behavior: .succeedAfter(0.1), for: endpoint(2))

        let outcome = await submitter.submit(transaction: makeTransaction(), to: endpoints, timing: fastTiming)

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.accepted(by: endpoint(1)))

        // Wait past the straggler's completion; it must not have been cancelled.
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(mock.recordedCancellations().isEmpty)
    }

    func testTimeoutWithNoResponses() async {
        let endpoints = [endpoint(1), endpoint(2)]
        mock.set(behavior: .hang, for: endpoint(1))
        mock.set(behavior: .hang, for: endpoint(2))
        let timing = SubmissionTiming(responseTimeout: 0.2, postAcceptanceGraceDelay: 0.1)

        let outcome = await submitter.submit(transaction: makeTransaction(), to: endpoints, timing: timing)

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.timedOut)
    }

    func testRejectionsThenHangTimesOut() async {
        // One endpoint rejects, the other never answers: not all endpoints
        // completed, so the timer decides — timeout, not rejection.
        let endpoints = [endpoint(1), endpoint(2)]
        mock.set(behavior: .reject(code: -25, message: "bad"), for: endpoint(1))
        mock.set(behavior: .hang, for: endpoint(2))
        let timing = SubmissionTiming(responseTimeout: 0.2, postAcceptanceGraceDelay: 0.1)

        let outcome = await submitter.submit(transaction: makeTransaction(), to: endpoints, timing: timing)

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.timedOut)
    }

    func testCallerCancellationCancelsAllSubmissions() async {
        let endpoints = [endpoint(1), endpoint(2)]
        mock.set(behavior: .hang, for: endpoint(1))
        mock.set(behavior: .hang, for: endpoint(2))
        let transaction = makeTransaction()
        let timing = fastTiming
        let submitter = self.submitter!

        let task = Task { () -> TransactionSubmissionOutcome in
            await submitter.submit(transaction: transaction, to: endpoints, timing: timing)
        }

        // Give the race time to start both submissions, then cancel.
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.cancelled)

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mock.recordedCancellations().count, 2)
    }
}
