import Foundation

protocol SekaiAPI: Sendable {
    func fetchFeed(page: Int, limit: Int) async throws -> [SekaiItem]
    func fetchProfile(creatorID: CreatorID) async throws -> CreatorProfile
    func fetchCreatorGames(creatorID: CreatorID, page: Int, size: Int) async throws -> GamePage
    func block(creatorID: CreatorID) async throws
    func report(sekaiID: SekaiID, reason: String) async throws
}

actor SekaiAPIClient: SekaiAPI {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetchFeed(page: Int, limit: Int) async throws -> [SekaiItem] {
        try await get("game/feed", query: ["refresh": String(page), "limit": String(limit)])
    }

    func fetchProfile(creatorID: CreatorID) async throws -> CreatorProfile {
        let response: Envelope<CreatorProfile> = try await get(
            "api/user/info/v1/userProfile", query: ["user_id": creatorID])
        return try response.value()
    }

    func fetchCreatorGames(creatorID: CreatorID, page: Int, size: Int) async throws -> GamePage {
        let response: Envelope<GamePage> = try await get("api/game/list/v1/userGames",
            query: ["user_id": creatorID, "page": String(page), "size": String(size)])
        return try response.value()
    }

    func block(creatorID: CreatorID) async throws {
        try await post("api/user/block/v1/blockUser", body: ["user_id": creatorID])
    }

    func report(sekaiID: SekaiID, reason: String) async throws {
        try await post("api/report/content/v1/reportContent", body: ["game_id": sekaiID, "reason": reason])
    }

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await request(URLRequest(url: components.url!))
    }

    private func post(_ path: String, body: [String: String]) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let response: Status = try await self.request(request)
        guard response.code == 0 else { throw SekaiError.server(response.message ?? "Moderation sync failed.") }
    }

    private func request<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SekaiError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct Status: Decodable {
        let code: Int
        let message: String?
    }

    private struct Envelope<T: Decodable>: Decodable {
        let code: Int
        let message: String?
        let data: T?
        func value() throws -> T {
            guard code == 0 else { throw SekaiError.server(message ?? "Request failed.") }
            guard let data else { throw SekaiError.invalidResponse }
            return data
        }
    }
}
