import UIKit
import WebKit
import os

@MainActor final class WebViewSlotPool: NSObject, WKNavigationDelegate {
    struct Presentation {
        let webView: WKWebView
        let isReady: Bool
        let error: String?
    }

    @MainActor private final class Slot {
        let webView: WKWebView
        var item: SekaiItem?
        var navigation: WKNavigation?
        var loadInterval: FeedPerformance.Interval?
        var measurement: WebLoadMeasurement?
        var playAcknowledged = false
        var finished = false
        var ready = false
        var playing = false
        var resetting = false
        var error: String?

        init(websiteDataStore: WKWebsiteDataStore) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = websiteDataStore
            configuration.suppressesIncrementalRendering = false
            configuration.allowsInlineMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            webView = WKWebView(frame: .zero, configuration: configuration)
            webView.isOpaque = false
            webView.backgroundColor = .black
            webView.scrollView.isScrollEnabled = false
        }
    }

    private let slots: [Slot]
    private var contentActive = false
    private var displayMeasurement: WebDisplayMeasurement?
    private let log = Logger(subsystem: "com.sekai.takehome", category: "WebViewPool")
    private var desired: [SekaiItem] = []
    private var currentID: SekaiID?
    private var eligibleID: SekaiID?
    private var conservative = false
    private var dirty = false
    private var reconciliation: Task<Void, Never>?
    private weak var webViewContainer: UIView?
    private var itemFrames: [SekaiID: CGRect] = [:]
    private var parkedFrame = CGRect.zero
    var onChange: (() -> Void)?

    init(websiteDataStore: WKWebsiteDataStore = .default()) {
        slots = (0..<3).map { _ in Slot(websiteDataStore: websiteDataStore) }
        super.init()
        for (index, slot) in slots.enumerated() {
            slot.webView.navigationDelegate = self
            log.info("Created WebView slot \(index); capacity=3")
        }
    }

    func mountWebViews(in container: UIView) {
        if let webViewContainer {
            precondition(webViewContainer === container, "WebViews must keep one permanent container")
        } else {
            webViewContainer = container
        }
        for (index, slot) in slots.enumerated() where slot.webView.superview == nil {
            let phase = FeedPerformance.begin("FeedWebViewAttach", "slot=\(index) permanent=true")
            container.addSubview(slot.webView)
            phase?.end()
        }
        positionMountedWebViews()
    }

    func positionWebViews(itemFrames: [SekaiID: CGRect], parkedFrame: CGRect) {
        self.itemFrames = itemFrames
        self.parkedFrame = parkedFrame
        positionMountedWebViews()
    }

    private func positionMountedWebViews() {
        guard webViewContainer != nil else { return }
        for slot in slots {
            if let id = slot.item?.id, let frame = itemFrames[id], !slot.resetting {
                slot.webView.frame = frame
                slot.webView.isUserInteractionEnabled = slot.ready
            } else {
                slot.webView.frame = parkedFrame
                slot.webView.isUserInteractionEnabled = false
            }
        }
    }

    func assign(items: [SekaiItem], currentID: SekaiID?) {
        self.currentID = currentID
        if let currentID, let index = items.firstIndex(where: { $0.id == currentID }) {
            desired = Array(items[max(0, index - 1)...min(items.count - 1, index + 1)])
        } else { desired = [] }
        schedule()
    }

    func setContentActive(_ active: Bool) {
        guard contentActive != active else { return }
        contentActive = active
        if !active { setEligibleTarget(nil) }
        schedule()
    }

    private func beginDisplay(_ id: SekaiID, reason: String) {
        let slot = slots.first { $0.item?.id == id && !$0.resetting }
        let state = slot?.ready == true ? "ready_pool" : (slot?.error != nil ? "failed" : (slot?.navigation == nil ? "unbound" : "loading"))
        displayMeasurement = WebDisplayMeasurement(itemID: id, reason: reason,
            initialState: state, load: slot?.measurement)
        if slot?.error != nil { displayMeasurement?.end("failed") }
        else if slot?.playAcknowledged == true { displayMeasurement?.end("played") }
    }

    func setEligibleTarget(_ id: SekaiID?, reason: String = "resume") {
        guard eligibleID != id else { return }
        FeedPerformance.event("FeedEligibility", "item=\(id ?? "none")")
        displayMeasurement?.end("interrupted")
        displayMeasurement = nil
        eligibleID = id
        if let id { beginDisplay(id, reason: reason) }
        schedule()
    }

    func presentation(for id: SekaiID) -> Presentation? {
        guard let slot = slots.first(where: { $0.item?.id == id && !$0.resetting }) else { return nil }
        return Presentation(webView: slot.webView, isReady: slot.ready, error: slot.error)
    }

    func retry(itemID: SekaiID) {
        guard let slot = slots.first(where: { $0.item?.id == itemID }), slot.error != nil else { return }
        reset(slot)
        if eligibleID == itemID { beginDisplay(itemID, reason: "retry") }
        schedule()
    }

    func removeHiddenItems(survivingIDs: Set<SekaiID>) {
        desired.removeAll { !survivingIDs.contains($0.id) }
        if let eligibleID, !survivingIDs.contains(eligibleID) { setEligibleTarget(nil) }
        for slot in slots {
            guard let id = slot.item?.id, !survivingIDs.contains(id) else { continue }
            slot.webView.isUserInteractionEnabled = false
            if !slot.playing && !slot.resetting { reset(slot) }
            else { slot.webView.stopLoading() }
        }
        schedule()
    }

    func memoryWarning() {
        FeedPerformance.event("FeedMemoryWarning")
        conservative = true
        log.notice("Memory warning: adjacent loads deferred for this session")
        schedule()
    }

    private func schedule() {
        dirty = true
        guard reconciliation == nil else { return }
        reconciliation = Task { [weak self] in
            await self?.reconcile()
        }
    }

    private func reconcile() async {
        while dirty && !Task.isCancelled {
            let phase = FeedPerformance.begin("WebPoolReconcile", "current=\(currentID ?? "none") eligible=\(eligibleID ?? "none")")
            defer { phase?.end() }
            dirty = false

            // No slot may start until the old running document has acknowledged pause.
            for slot in slots where slot.playing && !slot.resetting {
                let shouldKeepPlaying = slot.item?.id == eligibleID &&
                    desired.contains(where: { $0.id == slot.item?.id && $0.gameURL == slot.item?.gameURL }) && slot.ready && contentActive
                if shouldKeepPlaying { continue }
                let id = slot.item?.id
                let navigation = slot.navigation
                do {
                    _ = try await evaluate("window.sekaiPause()", in: slot, phase: "WebPauseJS")
                    guard matches(slot, id: id, navigation: navigation) else { dirty = true; continue }
                    slot.playing = false
                    slot.playAcknowledged = false
                    log.debug("Paused \(id ?? "")")
                } catch {
                    // Replacing the document, not stopLoading alone, proves the old script is gone.
                    reset(slot)
                }
            }

            for slot in slots where !slot.resetting {
                if let item = slot.item, !desired.contains(where: { $0.id == item.id && $0.gameURL == item.gameURL }) {
                    reset(slot)
                } else if conservative, slot.item?.id != currentID, slot.navigation != nil {
                    reset(slot)
                } else if !contentActive, slot.navigation != nil, !slot.finished {
                    reset(slot)
                }
            }

            for item in desired.sorted(by: { ($0.id == currentID ? 0 : 1) < ($1.id == currentID ? 0 : 1) }) {
                guard contentActive, !conservative || item.id == currentID else { continue }
                if let existing = slots.first(where: { $0.item?.id == item.id && !$0.resetting }) {
                    if existing.navigation == nil && existing.error == nil { bind(item, to: existing) }
                } else if let free = slots.first(where: { $0.item == nil && !$0.resetting }) {
                    bind(item, to: free)
                }
            }

            // Readiness checks share the same executor as play/pause JS.
            for slot in slots where slot.finished && !slot.ready && !slot.resetting && slot.error == nil {
                let id = slot.item?.id
                let navigation = slot.navigation
                do {
                    let result = try await evaluate(WebContentMetrics.readinessScript, in: slot, phase: "WebReadinessJS")
                    guard matches(slot, id: id, navigation: navigation) else { dirty = true; continue }
                    let payload = result as? [String: Any]
                    let value = payload?["ready"] as? Bool == true
                    let timing = (payload?["timing"] as? [String: Any]).map { WebNavigationTiming(values: $0) }
                    slot.measurement?.end(value ? "ready" : "bridge_unavailable", timing: timing)
                    if displayMeasurement?.itemID == id {
                        displayMeasurement?.attach(slot.measurement)
                        if !value { displayMeasurement?.end("failed") }
                    }
                    slot.loadInterval?.end(value ? "ready" : "functions unavailable")
                    slot.loadInterval = nil
                    FeedPerformance.event("WebContentReady", "item=\(id ?? "none") ready=\(value)")
                    slot.ready = value
                    if !slot.ready { slot.error = "Playback functions are unavailable." }
                } catch {
                    guard matches(slot, id: id, navigation: navigation) else { continue }
                    slot.measurement?.end("readiness_failed")
                    if displayMeasurement?.itemID == id { displayMeasurement?.end("failed") }
                    slot.loadInterval?.end("readiness failed")
                    slot.loadInterval = nil
                    slot.error = "Could not prepare content. Tap Retry."
                }
            }

            // Only a potentially running document blocks another slot from playing.
            // reset() preserves playing after a failed pause until replacement finishes;
            // resetting an already paused neighbor must not stall the current item.
            if !slots.contains(where: { $0.playing }),
               contentActive, let eligibleID,
               let slot = slots.first(where: { $0.item?.id == eligibleID && $0.ready && !$0.resetting }),
               desired.contains(where: { $0.id == eligibleID }) {
                let navigation = slot.navigation
                slot.playing = true
                slot.playAcknowledged = false
                displayMeasurement?.requestPlay()
                do {
                    _ = try await evaluate("window.sekaiPlay()", in: slot, phase: "WebPlayJS")
                    guard matches(slot, id: eligibleID, navigation: navigation) else { reset(slot); continue }
                    slot.playAcknowledged = true
                    if self.eligibleID == eligibleID {
                        displayMeasurement?.attach(slot.measurement)
                        displayMeasurement?.end("played")
                    } else { dirty = true }
                    log.debug("Play completion \(eligibleID)")
                } catch {
                    if displayMeasurement?.itemID == eligibleID { displayMeasurement?.end("play_failed") }
                    reset(slot)
                }
            }
            positionMountedWebViews()
            onChange?()
        }
        reconciliation = nil
    }

    private func bind(_ item: SekaiItem, to slot: Slot) {
        slot.measurement?.end("rebound")
        slot.measurement = WebLoadMeasurement(itemID: item.id,
            slot: slots.firstIndex(where: { $0 === slot }) ?? -1,
            role: item.id == currentID ? "current" : "adjacent")
        if displayMeasurement?.itemID == item.id { displayMeasurement?.attach(slot.measurement) }
        slot.loadInterval?.end("rebound")
        slot.loadInterval = FeedPerformance.begin("WebLoadToReady", "item=\(item.id) role=\(item.id == currentID ? "current" : "adjacent") slot=\(slots.firstIndex(where: { $0 === slot }) ?? -1)")
        slot.item = item
        slot.ready = false
        slot.finished = false
        slot.error = nil
        slot.playAcknowledged = false
        slot.navigation = slot.webView.load(URLRequest(url: item.gameURL, cachePolicy: .useProtocolCachePolicy))
        if slot.navigation == nil {
            slot.measurement?.end("navigation_unavailable")
            slot.loadInterval?.end("navigation unavailable")
            slot.loadInterval = nil
            slot.error = "Content failed to load. Tap Retry."
            if displayMeasurement?.itemID == item.id { displayMeasurement?.end("failed") }
        }
        log.debug("Load \(item.id)")
    }

    private func reset(_ slot: Slot) {
        let phase = FeedPerformance.begin("WebSlotReset", "item=\(slot.item?.id ?? "none")")
        defer { phase?.end() }
        slot.measurement?.end("cancelled")
        slot.measurement = nil
        slot.playAcknowledged = false
        slot.loadInterval?.end("reset or cancelled")
        slot.loadInterval = nil
        slot.webView.isUserInteractionEnabled = false
        if slot.navigation != nil && !slot.finished {
            log.debug("Canceled load \(slot.item?.id ?? "")")
        }
        slot.webView.stopLoading()
        slot.navigation = nil
        slot.ready = false
        slot.finished = false
        slot.item = nil
        slot.error = nil
        slot.resetting = true
        // Keep the playing flag until the replacement navigation finishes.
        slot.navigation = slot.webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    private func matches(_ slot: Slot, id: SekaiID?, navigation: WKNavigation?) -> Bool {
        guard let navigation, let current = slot.navigation else { return false }
        return !slot.resetting && slot.item?.id == id && current === navigation
    }

    private func slot(for webView: WKWebView, navigation: WKNavigation?) -> Slot? {
        guard let navigation else { return nil }
        return slots.first { $0.webView === webView && $0.navigation === navigation }
    }

    private func evaluate(_ script: String, in slot: Slot, phase name: StaticString) async throws -> Any? {
        let phase = FeedPerformance.begin(name, "item=\(slot.item?.id ?? "none")")
        defer { phase?.end() }
        return try await withCheckedThrowingContinuation { continuation in
            slot.webView.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result) }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let slot = slot(for: webView, navigation: navigation), !slot.resetting else { return }
        slot.measurement?.didStart()
        slot.ready = false
        slot.finished = false
        onChange?()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let slot = slot(for: webView, navigation: navigation) else { return }
        if !slot.resetting { slot.measurement?.didCommit() }
        FeedPerformance.event("WebNavigationCommit", "item=\(slot.item?.id ?? "blank")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let slot = slot(for: webView, navigation: navigation) else { return }
        if slot.resetting {
            slot.resetting = false
            slot.playing = false
            slot.navigation = nil
        } else {
            FeedPerformance.event("WebNavigationFinished", "item=\(slot.item?.id ?? "none")")
            slot.measurement?.didFinish()
            slot.finished = true
        }
        schedule()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, navigation: navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, navigation: navigation, error: error)
    }

    private func failed(_ webView: WKWebView, navigation: WKNavigation?, error: Error) {
        guard let slot = slot(for: webView, navigation: navigation) else { return }
        if slot.resetting {
            // Keep this slot unavailable. It blocks other playback only if its old
            // document may still be running; process termination can clear that barrier.
            log.error("Blank-document reset failed: \(error.localizedDescription)")
            return
        }
        slot.measurement?.end((error as NSError).code == NSURLErrorCancelled ? "cancelled" : "navigation_failed")
        if displayMeasurement?.itemID == slot.item?.id { displayMeasurement?.end("failed") }
        slot.loadInterval?.end("navigation failed code=\((error as NSError).code)")
        slot.loadInterval = nil
        slot.navigation = nil
        slot.ready = false
        slot.finished = false
        slot.error = "Content failed to load. Tap Retry."
        schedule()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let slot = slots.first(where: { $0.webView === webView }) else { return }
        slot.measurement?.end("process_terminated")
        slot.measurement = nil
        slot.playAcknowledged = false
        if displayMeasurement?.itemID == slot.item?.id { displayMeasurement?.end("process_terminated") }
        slot.loadInterval?.end("process terminated")
        slot.loadInterval = nil
        FeedPerformance.event("WebProcessTerminated", "item=\(slot.item?.id ?? "none")")
        log.notice("WebContent process terminated for \(slot.item?.id ?? "empty")")
        slot.navigation = nil
        slot.ready = false
        slot.finished = false
        slot.playing = false
        slot.resetting = false
        slot.error = slot.item?.id == currentID ? nil : "Content was released. Tap Retry."
        if let id = eligibleID, slot.item?.id == id { beginDisplay(id, reason: "recovery") }
        schedule()
    }
}
