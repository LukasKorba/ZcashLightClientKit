//
//  SubmitPlanExecutorTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class SubmitPlanExecutorTests: ZcashTestCase {
    private var mock: EndpointSubmitterMock!
    private var executor: SubmitPlanExecutor!

    override func setUp() async throws {
        try await super.setUp()
        mock = EndpointSubmitterMock()
        executor = SubmitPlanExecutor(endpointSubmitter: mock, logger: NullLogger())
    }

    private func endpoint(_ index: Int) -> LightWalletEndpoint {
        LightWalletEndpoint(address: "server\(index).example.com", port: 9067, secure: true)
    }

    private func makeTransaction() -> CreatedTransaction {
        CreatedTransaction(
            txId: Data(repeating: 0xAB, count: 32),
            raw: Data([0x01, 0x02]),
            expiryHeight: nil
        )
    }

    func testStopsAtFirstSuccess() async throws {
        mock.set(behavior: .succeed, for: endpoint(1))

        try await executor.submit(transaction: makeTransaction(), endpoints: [endpoint(1), endpoint(2)])

        XCTAssertEqual(mock.recordedSubmissions().map(\.host), ["server1.example.com"])
    }

    func testTriesNextEndpointAfterFailure() async throws {
        mock.set(behavior: .failTransport, for: endpoint(1))
        mock.set(behavior: .succeed, for: endpoint(2))

        try await executor.submit(transaction: makeTransaction(), endpoints: [endpoint(1), endpoint(2)])

        XCTAssertEqual(mock.recordedSubmissions().map(\.host), ["server1.example.com", "server2.example.com"])
    }

    func testThrowsLastErrorWhenAllEndpointsFail() async {
        mock.set(behavior: .failTransport, for: endpoint(1))
        mock.set(behavior: .reject(code: -25, message: "no"), for: endpoint(2))

        do {
            try await executor.submit(transaction: makeTransaction(), endpoints: [endpoint(1), endpoint(2)])
            XCTFail("Expected an error")
        } catch let TransactionEncoderError.submitError(code, _) {
            XCTAssertEqual(code, -25)
        } catch {
            XCTFail("Expected the LAST error (submitError), got \(error)")
        }
    }
}
