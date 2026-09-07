import XCTest
@testable import Sekai

final class WebContentMetricsTests: XCTestCase {
    private func timing(_ overrides: [String: Any] = [:]) -> WebNavigationTiming {
        var values: [String: Any] = [
            "api": "navigation_timing", "worker": false,
            "requestStart": 10, "responseStart": 60, "responseEnd": 560,
            "transferSize": 1_048_876, "encodedBodySize": 1_048_576, "decodedBodySize": 2_097_152
        ]
        values.merge(overrides) { _, new in new }
        return WebNavigationTiming(values: values)
    }

    func testNetworkPhasesAndEstimatedBodyRate() {
        let sample = timing()
        XCTAssertEqual(sample.duration("requestStart", "responseStart"), 50)
        XCTAssertEqual(sample.duration("responseStart", "responseEnd"), 500)
        XCTAssertEqual(sample.bodyBytesPerSecond, 2_097_152)
        XCTAssertEqual(sample.cacheEvidence, "network_or_revalidated")
    }

    func testCacheRevalidationAndUnavailableSamplesNeverInventThroughput() {
        let cached = timing(["transferSize": 0])
        XCTAssertEqual(cached.cacheEvidence, "local_cache_likely")
        XCTAssertNil(cached.bodyBytesPerSecond)
        XCTAssertNil(timing(["transferSize": 300]).bodyBytesPerSecond)
        XCTAssertEqual(timing(["worker": true]).cacheEvidence, "unknown")
        XCTAssertEqual(timing(["api": "legacy_timing"]).cacheEvidence, "unknown")
        XCTAssertEqual(timing(["decodedBodySize": 0, "transferSize": 0]).cacheEvidence, "unknown")
        XCTAssertEqual(timing(["transferSize": NSNull()]).cacheEvidence, "unknown")
        for end: Any in [60, 59, Double.nan, Double.infinity, NSNull(), true] {
            XCTAssertNil(timing(["responseEnd": end]).bodyBytesPerSecond)
        }
        XCTAssertNil(timing(["transferSize": true]).value("transferSize"))
    }

    @MainActor func testLoadTerminalIsUniqueAndFailureHasNoReadyDuration() {
        var now: TimeInterval = 10
        var lines: [String] = []
        let load = WebLoadMeasurement(itemID: "a", slot: 0, role: "current", clock: { now }, emit: { lines.append($0) })
        now = 10.1
        load.didStart()
        now = 10.2
        load.didCommit()
        now = 12
        load.didFinish()
        now = 12.1
        load.end("ready", timing: timing())
        load.end("cancelled")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("navigation_ms=2000.000"))
        XCTAssertTrue(lines[1].contains("finish_to_ready_ms=100.000"))
        XCTAssertTrue(lines[1].contains("load_to_ready_ms=2100.000"))
        let failure = WebLoadMeasurement(itemID: "b", slot: 1, role: "adjacent", clock: { now }, emit: { lines.append($0) })
        failure.end("navigation_failed")
        failure.didFinish()
        failure.end("ready")
        XCTAssertTrue(lines.last!.contains("load_to_ready_ms=n/a"))
        XCTAssertNil(failure.readyAt)
    }

    @MainActor func testReadyPoolDisplayIsCountedWithZeroReadyWait() {
        var now: TimeInterval = 10
        var lines: [String] = []
        let load = WebLoadMeasurement(itemID: "a", slot: 0, role: "adjacent", clock: { now }, emit: { _ in })
        now = 11
        load.end("ready")
        now = 20
        let display = WebDisplayMeasurement(itemID: "a", reason: "settled", initialState: "ready_pool",
            load: load, clock: { now }, emit: { lines.append($0) })
        display.requestPlay()
        now = 20.02
        display.end("played")
        display.end("interrupted")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("eligible_to_ready_ms=0.000"))
        XCTAssertTrue(lines[1].contains("eligible_to_play_ms=20.000"))
        XCTAssertTrue(lines[1].contains("load=\(load.loadID)"))
    }

    @MainActor func testAbandonedDisplayDoesNotReportSuccessfulPlayback() {
        var now: TimeInterval = 1
        var lines: [String] = []
        let display = WebDisplayMeasurement(itemID: "a", reason: "settled", initialState: "unbound",
            load: nil, clock: { now }, emit: { lines.append($0) })
        let otherLoad = WebLoadMeasurement(itemID: "b", slot: 0, role: "current", clock: { now }, emit: { _ in })
        display.attach(otherLoad)
        now = 2
        display.end("interrupted")
        display.end("played")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("load=none"))
        XCTAssertTrue(lines[1].contains("eligible_to_play_ms=n/a"))
        XCTAssertTrue(lines[1].contains("observed_ms=1000.000"))
    }
}
