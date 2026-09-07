import XCTest
import WebKit
import Network
@testable import Sekai

/// Real HTTP responses are required: URLProtocol does not intercept WebKit.
@MainActor private final class CacheHTTPFixture {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private(set) var requests: [String: Int] = [:]
    private var startup: CheckedContinuation<URL, Error>?
    private let namespace = UUID().uuidString

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let waiting = self.startup else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener?.port else { return }
                        self.startup = nil
                        waiting.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.namespace)/")!)
                    case .failed(let error):
                        self.startup = nil
                        waiting.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    func stop() {
        startup?.resume(throwing: CancellationError())
        startup = nil
        listener?.cancel()
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= 16_384 else { connection.cancel(); return }
                guard let request = String(data: bytes, encoding: .utf8),
                      request.contains("\r\n\r\n") else {
                    if error == nil && !complete { self.receive(connection, buffer: bytes) }
                    else { connection.cancel() }
                    return
                }
                let path = request.components(separatedBy: " ").dropFirst().first ?? ""
                self.requests[path, default: 0] += 1
                let body = Data("""
                <!doctype html><html><body><p>Cache fixture</p><script>
                window.sekaiPlay = function() { document.body.dataset.playing = 'true'; };
                window.sekaiPause = function() { document.body.dataset.playing = 'false'; };
                </script></body></html>
                """.utf8)
                let policy = path.contains("no-store") ? "no-store" : "public, max-age=3600"
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: \(policy)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

@MainActor final class WebViewCacheTests: XCTestCase {
    private func items(_ base: URL) -> [SekaiItem] {
        ["a", "b", "c", "d"].map { id in
            SekaiItem(gameID: id, title: id, gameURL: base.appendingPathComponent(id),
                coverURL: base.appendingPathComponent("cover"), creatorID: "creator",
                creatorName: "Creator", likeCount: 0)
        }
    }

    private func ready(_ ids: [String], pool: WebViewSlotPool, action: () -> Void) async {
        let completed = expectation(description: "Ready: \(ids.joined(separator: ","))")
        var fulfilled = false
        pool.onChange = {
            guard !fulfilled else { return }
            let states = ids.compactMap { pool.presentation(for: $0) }
            if states.count == ids.count && states.allSatisfy({ $0.isReady || $0.error != nil }) {
                fulfilled = true
                completed.fulfill()
            }
        }
        action()
        pool.onChange?()
        await fulfillment(of: [completed], timeout: 20)
        pool.onChange = nil
        for id in ids {
            XCTAssertEqual(pool.presentation(for: id)?.isReady, true, "\(id): \(pool.presentation(for: id)?.error ?? "missing")")
        }
    }

    func testFreshHTTPDocumentIsReusedAfterLeavingPoolWindow() async throws {
        let server = CacheHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let dataStore = WKWebsiteDataStore.default()
        let pool = WebViewSlotPool(websiteDataStore: dataStore)
        let content = items(base)
        defer { pool.setContentActive(false); pool.removeHiddenItems(survivingIDs: []) }
        await ready(["a", "b"], pool: pool) {
            pool.setContentActive(true)
            pool.assign(items: content, currentID: "a")
        }
        let first = try XCTUnwrap(pool.presentation(for: "a")?.webView)
        let second = try XCTUnwrap(pool.presentation(for: "b")?.webView)
        XCTAssertTrue(first.configuration.websiteDataStore === dataStore)
        XCTAssertTrue(second.configuration.websiteDataStore === dataStore)
        XCTAssertFalse(first === second)
        let firstDocument = first.backForwardList.currentItem
        await ready(["c", "d"], pool: pool) { pool.assign(items: content, currentID: "d") }
        XCTAssertNil(pool.presentation(for: "a"))
        await ready(["a", "b"], pool: pool) { pool.assign(items: content, currentID: "a") }
        let revisited = try XCTUnwrap(pool.presentation(for: "a")?.webView)
        XCTAssertFalse(revisited.backForwardList.currentItem === firstDocument)
        XCTAssertEqual(server.requests[base.appendingPathComponent("a").path], 1)
        XCTAssertEqual(server.requests[base.appendingPathComponent("b").path], 1)
    }

    func testNoStoreResponseIsFetchedAgainDespiteSharedDataStore() async throws {
        let server = CacheHTTPFixture()
        let base = try await server.start().appendingPathComponent("no-store")
        defer { server.stop() }
        let pool = WebViewSlotPool(websiteDataStore: .default())
        let content = items(base)
        defer { pool.setContentActive(false); pool.removeHiddenItems(survivingIDs: []) }
        await ready(["a", "b"], pool: pool) {
            pool.setContentActive(true)
            pool.assign(items: content, currentID: "a")
        }
        await ready(["c", "d"], pool: pool) { pool.assign(items: content, currentID: "d") }
        await ready(["a", "b"], pool: pool) { pool.assign(items: content, currentID: "a") }
        XCTAssertEqual(server.requests[base.appendingPathComponent("a").path], 2)
    }
}
