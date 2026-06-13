//
//  SubmitResultClassificationTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

final class SubmitResultClassificationTests: XCTestCase {
    func testRecognisesAlreadyInMempool() {
        XCTAssertTrue(SDKSynchronizer.isAlreadyKnownToNetwork("transaction already exists in mempool"))
        XCTAssertTrue(SDKSynchronizer.isAlreadyKnownToNetwork("send failed: transaction already exists in mempool"))
        XCTAssertTrue(SDKSynchronizer.isAlreadyKnownToNetwork("Transaction Already Exists In Mempool"))
    }

    func testRecognisesAlreadyQueuedForDownload() {
        XCTAssertTrue(SDKSynchronizer.isAlreadyKnownToNetwork("transaction dropped because it is already queued for download"))
        XCTAssertTrue(SDKSynchronizer.isAlreadyKnownToNetwork("ALREADY QUEUED FOR DOWNLOAD"))
    }

    func testDoesNotMatchUnrelatedFailures() {
        XCTAssertFalse(SDKSynchronizer.isAlreadyKnownToNetwork(""))
        XCTAssertFalse(SDKSynchronizer.isAlreadyKnownToNetwork("insufficient funds"))
        XCTAssertFalse(SDKSynchronizer.isAlreadyKnownToNetwork("transaction rejected: bad signature"))
        XCTAssertFalse(SDKSynchronizer.isAlreadyKnownToNetwork("connection refused"))
    }
}
