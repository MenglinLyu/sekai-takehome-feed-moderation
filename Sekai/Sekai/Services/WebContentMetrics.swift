import Foundation
import os

/// Diagnostics use numeric values and opaque identities only, never document URLs.
enum WebContentMetrics {
    private static let log = Logger(subsystem: "com.sekai.takehome", category: "WebContentMetrics")

    static func record(_ message: String) { log.info("\(message, privacy: .public)") }

    static func number(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "n/a" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func milliseconds(_ end: TimeInterval?, since start: TimeInterval?) -> String {
        guard let end, let start else { return "n/a" }
        return number((end - start) * 1_000)
    }

    /// Runs with the readiness check, so no additional JS round trip delays playback.
    /// No URLs, resource names or page text cross the bridge.
    static let readinessScript = """
    (() => {
      const ready = typeof window.sekaiPlay === 'function' && typeof window.sekaiPause === 'function';
      let timing = null;
      try {
        const p = window.performance;
        const n = p && p.getEntriesByType && p.getEntriesByType('navigation')[0];
        const legacy = !n && p && p.timing;
        const t = n || legacy;
        if (t) {
          const origin = n ? 0 : t.navigationStart;
          const point = key => typeof t[key] === 'number' && t[key] > 0 ? t[key] - origin : null;
          const size = key => n && typeof n[key] === 'number' ? n[key] : null;
          const paints = p.getEntriesByType ? p.getEntriesByType('paint') : [];
          const fcp = paints.find(e => e.name === 'first-contentful-paint');
          timing = {
            api: n ? 'navigation_timing' : 'legacy_timing',
            fetchStart: point('fetchStart'),
            domainLookupStart: point('domainLookupStart'), domainLookupEnd: point('domainLookupEnd'),
            connectStart: point('connectStart'), connectEnd: point('connectEnd'),
            secureConnectionStart: point('secureConnectionStart'),
            requestStart: point('requestStart'), responseStart: point('responseStart'),
            responseEnd: point('responseEnd'), domInteractive: point('domInteractive'),
            domContentLoadedEventEnd: point('domContentLoadedEventEnd'),
            loadEventEnd: point('loadEventEnd'),
            transferSize: size('transferSize'), encodedBodySize: size('encodedBodySize'),
            decodedBodySize: size('decodedBodySize'),
            worker: !!((n && n.workerStart > 0) || (navigator.serviceWorker && navigator.serviceWorker.controller)),
            fcp: fcp ? fcp.startTime : null
          };
        }
      } catch (_) {}
      return { ready, timing };
    })()
    """
}

/// Browser-reported main-document timings, not URLSession or packet-level counters.
struct WebNavigationTiming {
    let values: [String: Any]

    func value(_ key: String) -> Double? {
        guard let number = values[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 ? value : nil
    }

    func duration(_ start: String, _ end: String) -> Double? {
        guard let start = value(start), let end = value(end), end >= start else { return nil }
        return end - start
    }

    var cacheEvidence: String {
        guard values["api"] as? String == "navigation_timing",
              values["worker"] as? Bool == false,
              let transferred = value("transferSize"), let decoded = value("decodedBodySize"),
              decoded > 0 else { return "unknown" }
        return transferred == 0 ? "local_cache_likely" : "network_or_revalidated"
    }

    /// A 304 may report cached body size, so exclude samples whose transfer is smaller
    /// than that body. This remains an estimate, not measured wire bandwidth.
    var bodyBytesPerSecond: Double? {
        guard cacheEvidence == "network_or_revalidated",
              let transferred = value("transferSize"), let encoded = value("encodedBodySize"),
              encoded > 0, transferred >= encoded,
              let receive = duration("responseStart", "responseEnd"), receive > 0 else { return nil }
        let speed = encoded * 1_000 / receive
        return speed.isFinite ? speed : nil
    }

    var fields: String {
        let api = values["api"] as? String == "navigation_timing" ? "navigation_timing" : "legacy_timing"
        let phases = [
            ("dns_ms", duration("domainLookupStart", "domainLookupEnd")),
            ("connect_ms", duration("connectStart", "connectEnd")),
            ("tls_ms", duration("secureConnectionStart", "connectEnd")),
            ("ttfb_ms", duration("requestStart", "responseStart")),
            ("receive_ms", duration("responseStart", "responseEnd")),
            ("fetch_to_response_end_ms", duration("fetchStart", "responseEnd")),
            ("post_response_to_dcl_ms", duration("responseEnd", "domContentLoadedEventEnd")),
            ("dom_interactive_ms", value("domInteractive")),
            ("dcl_ms", value("domContentLoadedEventEnd")),
            ("load_event_ms", value("loadEventEnd")),
            ("fcp_ms", value("fcp")),
            ("transfer_bytes", value("transferSize")),
            ("encoded_body_bytes", value("encodedBodySize")),
            ("decoded_body_bytes", value("decodedBodySize")),
            ("body_bytes_per_second_estimate", bodyBytesPerSecond)
        ]
        return "timing_api=\(api) cache_evidence=\(cacheEvidence) " +
            phases.map { "\($0.0)=\(WebContentMetrics.number($0.1))" }.joined(separator: " ")
    }
}

@MainActor final class WebLoadMeasurement {
    let loadID = UUID()
    let itemID: SekaiID
    private let slot: Int
    private let role: String
    private let clock: () -> TimeInterval
    private let emit: (String) -> Void
    private let started: TimeInterval
    private var provisional: TimeInterval?
    private var committed: TimeInterval?
    private var finished: TimeInterval?
    private(set) var readyAt: TimeInterval?
    private(set) var ended = false

    init(itemID: SekaiID, slot: Int, role: String,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping (String) -> Void = WebContentMetrics.record) {
        self.itemID = itemID
        self.slot = slot
        self.role = role
        self.clock = clock
        self.emit = emit
        started = clock()
        emit("WebLoadStart item=\(itemID) load=\(loadID) slot=\(slot) role=\(role) uptime_ms=\(WebContentMetrics.number(started * 1_000))")
    }

    func didStart() { if !ended && provisional == nil { provisional = clock() } }
    func didCommit() { if !ended && committed == nil { committed = clock() } }
    func didFinish() { if !ended && finished == nil { finished = clock() } }

    func end(_ outcome: String, timing: WebNavigationTiming? = nil) {
        guard !ended else { return }
        ended = true
        let end = clock()
        if outcome == "ready" { readyAt = end }
        let ms = WebContentMetrics.milliseconds
        emit("WebLoadMetrics item=\(itemID) load=\(loadID) slot=\(slot) role=\(role) outcome=\(outcome) " +
             "source=webkit_request provisional_ms=\(ms(provisional, started)) commit_ms=\(ms(committed, started)) " +
             "navigation_ms=\(ms(finished, started)) finish_to_ready_ms=\(ms(readyAt, finished)) " +
             "load_to_ready_ms=\(ms(readyAt, started)) total_ms=\(ms(end, started)) " +
             (timing?.fields ?? "timing_api=unavailable cache_evidence=unknown"))
    }
}

/// One interval per eligible display opportunity, including already-ready pool hits.
/// Reasons distinguish actual settlement from initial/snapshot, resume and retry.
@MainActor final class WebDisplayMeasurement {
    let displayID = UUID()
    let itemID: SekaiID
    private let reason: String
    private let initialState: String
    private let clock: () -> TimeInterval
    private let emit: (String) -> Void
    private let started: TimeInterval
    private var loadID: UUID?
    private var readyAt: TimeInterval?
    private var playRequested: TimeInterval?
    private(set) var ended = false

    init(itemID: SekaiID, reason: String, initialState: String,
         load: WebLoadMeasurement?,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping (String) -> Void = WebContentMetrics.record) {
        self.itemID = itemID
        self.reason = reason
        self.initialState = initialState
        self.clock = clock
        self.emit = emit
        started = clock()
        attach(load)
        emit("WebDisplayStart item=\(itemID) display=\(displayID) reason=\(reason) state=\(initialState) uptime_ms=\(WebContentMetrics.number(started * 1_000))")
    }

    func attach(_ load: WebLoadMeasurement?) {
        guard !ended, let load, load.itemID == itemID else { return }
        loadID = load.loadID
        if let ready = load.readyAt { readyAt = max(started, ready) }
    }

    func requestPlay() { if !ended && playRequested == nil { playRequested = clock() } }

    func end(_ outcome: String) {
        guard !ended else { return }
        ended = true
        let end = clock()
        let played = outcome == "played"
        let ms = WebContentMetrics.milliseconds
        emit("WebDisplayMetrics item=\(itemID) display=\(displayID) load=\(loadID?.uuidString ?? "none") " +
             "reason=\(reason) initial_state=\(initialState) outcome=\(outcome) " +
             "eligible_to_ready_ms=\(ms(readyAt, started)) " +
             "eligible_to_play_ms=\(played ? ms(end, started) : "n/a") " +
             "ready_to_play_ms=\(played ? ms(end, readyAt) : "n/a") " +
             "play_js_ms=\(played ? ms(end, playRequested) : "n/a") observed_ms=\(ms(end, started))")
    }
}
