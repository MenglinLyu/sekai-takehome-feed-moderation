import Foundation

protocol ModerationStorage: Sendable {
    func load() async throws -> VisibilityRules
    func save(_ rules: VisibilityRules) async throws
}

final class ModerationFileStore: ModerationStorage {
    private let url: URL
    private let queue = DispatchQueue(label: "com.sekai.moderation.files")

    init(url: URL) { self.url = url }

    func load() async throws -> VisibilityRules {
        let url = url
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        continuation.resume(returning: VisibilityRules())
                        return
                    }
                    continuation.resume(returning: try JSONDecoder().decode(
                        VisibilityRules.self, from: Data(contentsOf: url)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func save(_ rules: VisibilityRules) async throws {
        let url = url
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try JSONEncoder().encode(rules).write(to: url, options: .atomic)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

protocol RetryClock: Sendable {
    func sleep() async throws
    func now() async -> Date
}

struct SystemRetryClock: RetryClock {
    func sleep() async throws { try await Task.sleep(nanoseconds: 5_000_000_000) }
    func now() async -> Date { Date() }
}
