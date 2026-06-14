//
//  EnhanceFailureTrackerTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

final class EnhanceFailureTrackerTests: XCTestCase {
    private let txid1 = Data([0x01, 0x02, 0x03, 0x04])
    private let txid2 = Data([0x05, 0x06, 0x07, 0x08])

    func testShouldSkipReturnsFalseForUnknownTxid() async {
        let tracker = EnhanceFailureTracker(clock: { 100 })

        let result = await tracker.shouldSkipDueToBackoff(txId: txid1)

        XCTAssertFalse(result)
    }

    func testShouldSkipReturnsTrueWithinFirstBackoffWindow() async {
        let now = MutableClock(start: 100)
        let tracker = EnhanceFailureTracker(clock: now.read)

        await tracker.recordFailure(txId: txid1)
        now.advance(to: 130)

        let result = await tracker.shouldSkipDueToBackoff(txId: txid1)

        XCTAssertTrue(result)
    }

    func testShouldSkipReturnsFalseAfterFirstBackoffWindow() async {
        let now = MutableClock(start: 100)
        let tracker = EnhanceFailureTracker(clock: now.read)

        await tracker.recordFailure(txId: txid1)
        now.advance(to: 200)

        let result = await tracker.shouldSkipDueToBackoff(txId: txid1)

        XCTAssertFalse(result)
    }

    func testBackoffWindowDoublesAfterEachFailure() async {
        let now = MutableClock(start: 0)
        let tracker = EnhanceFailureTracker(clock: now.read)

        await tracker.recordFailure(txId: txid1)
        now.advance(by: 65)
        var skip = await tracker.shouldSkipDueToBackoff(txId: txid1)
        XCTAssertFalse(skip)

        await tracker.recordFailure(txId: txid1)
        now.advance(by: 65)
        skip = await tracker.shouldSkipDueToBackoff(txId: txid1)
        XCTAssertTrue(skip)
        now.advance(by: 60)
        skip = await tracker.shouldSkipDueToBackoff(txId: txid1)
        XCTAssertFalse(skip)

        await tracker.recordFailure(txId: txid1)
        now.advance(by: 200)
        skip = await tracker.shouldSkipDueToBackoff(txId: txid1)
        XCTAssertTrue(skip)
        now.advance(by: 100)
        skip = await tracker.shouldSkipDueToBackoff(txId: txid1)
        XCTAssertFalse(skip)
    }

    func testRecordSuccessClearsBackoff() async {
        let now = MutableClock(start: 100)
        let tracker = EnhanceFailureTracker(clock: now.read)

        await tracker.recordFailure(txId: txid1)
        var skip = await tracker.shouldSkipDueToBackoff(txId: txid1)
        XCTAssertTrue(skip)

        await tracker.recordSuccess(txId: txid1)
        now.advance(by: 1)
        skip = await tracker.shouldSkipDueToBackoff(txId: txid1)
        XCTAssertFalse(skip)
    }

    func testTracksMultipleTxidsIndependently() async {
        let now = MutableClock(start: 100)
        let tracker = EnhanceFailureTracker(clock: now.read)

        await tracker.recordFailure(txId: txid1)
        now.advance(to: 200)
        await tracker.recordFailure(txId: txid2)
        now.advance(to: 220)

        let txid1Skip = await tracker.shouldSkipDueToBackoff(txId: txid1)
        let txid2Skip = await tracker.shouldSkipDueToBackoff(txId: txid2)

        XCTAssertFalse(txid1Skip)
        XCTAssertTrue(txid2Skip)
    }
}

/// Mutable wall-clock substitute the tracker can read via its injectable clock closure.
/// Kept thread-safe so the closure satisfies `@Sendable`.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(start: TimeInterval) {
        self.value = start
    }

    func advance(to newValue: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func advance(by delta: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value += delta
    }

    func read() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
