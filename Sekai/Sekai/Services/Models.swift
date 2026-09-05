import Foundation

typealias CreatorID = String
typealias SekaiID = String

struct SekaiItem: Codable, Equatable, Identifiable, Sendable {
    let gameID: SekaiID
    let title: String
    let gameURL: URL
    let coverURL: URL
    let creatorID: CreatorID
    let creatorName: String
    let likeCount: Int
    var id: SekaiID { gameID }

    enum CodingKeys: String, CodingKey {
        case gameID = "game_id", title, gameURL = "game_url", coverURL = "cover_url"
        case creatorID = "creator_id", creatorName = "creator_name", likeCount = "like_count"
    }
}

struct CreatorProfile: Codable, Equatable, Sendable {
    let userID: CreatorID
    let nickName: String
    let avatar: URL
    let bio: String
    let followingCount: Int
    let followerCount: Int
    let likeCount: Int
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", nickName = "nick_name", avatar, bio
        case followingCount = "following_count", followerCount = "follower_count", likeCount = "like_count"
    }
}

struct GamePage: Codable, Equatable, Sendable {
    let list: [SekaiItem]
    let page: Int
    let size: Int
    let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case list, page, size, hasMore = "has_more"
    }
}

struct VisibilityRules: Codable, Equatable, Sendable {
    var blockedCreatorIDs: Set<CreatorID> = []
    var reportedSekaiIDs: Set<SekaiID> = []
}

enum ModerationIntent: Equatable, Sendable {
    case block(CreatorID)
    case report(SekaiID, reason: String)

    var key: String {
        switch self {
        case .block(let id): return "block:" + id
        case .report(let id, _): return "report:" + id
        }
    }

    func apply(to rules: inout VisibilityRules) {
        switch self {
        case .block(let id): rules.blockedCreatorIDs.insert(id)
        case .report(let id, _): rules.reportedSekaiIDs.insert(id)
        }
    }
}

struct PendingOperation: Equatable, Sendable, Identifiable {
    let id: UUID
    let intent: ModerationIntent
    var attemptCount = 0
    var nextRetryAt: Date?
}

struct ModerationSnapshot: Equatable, Sendable {
    var rules = VisibilityRules()
    var pendingOperations: [PendingOperation] = []
    var revision: UInt64 = 0
    var feedback: String?
}

enum SekaiVisibilityPolicy {
    static func visibleItems(in items: [SekaiItem], rules: VisibilityRules) -> [SekaiItem] {
        items.filter { !rules.blockedCreatorIDs.contains($0.creatorID) &&
            !rules.reportedSekaiIDs.contains($0.gameID) }
    }

    static func deduplicated(_ items: [SekaiItem]) -> [SekaiItem] {
        var seen = Set<SekaiID>()
        return items.filter { seen.insert($0.gameID).inserted }
    }
}

struct DisplayFailure: Equatable, Sendable {
    let message: String
}

enum SekaiError: LocalizedError {
    case invalidResponse
    case server(String)
    case notRestored
    case localSave
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an invalid response."
        case .server(let message): return message
        case .notRestored: return "Saved moderation state has not loaded."
        case .localSave: return "Could not save on this device. Please retry."
        }
    }
}
