import Foundation
import Combine

@MainActor final class FeedSession {
    let viewModel: FeedViewModel
    let controller: FeedViewController
    init(repository: FeedRepository, pool: WebViewSlotPool) {
        viewModel = FeedViewModel(repository: repository)
        controller = FeedViewController(viewModel: viewModel, pool: pool)
    }
}

@MainActor final class AppCompositionRoot: ObservableObject {
    @Published private(set) var feed: FeedSession?
    @Published private(set) var startupError: String?
    @Published private(set) var isStarting = false
    let profileFactory: CreatorProfileFactory
    private let api: SekaiAPIClient
    private let moderation: ModerationRepository
    private let moderationState: ModerationStateStore
    private let pool: WebViewSlotPool
    private var retryTask: Task<Void, Never>?

    init() {
        let configuredURL = ProcessInfo.processInfo.environment["SEKAI_BASE_URL"] ??
            Bundle.main.object(forInfoDictionaryKey: "SekaiBaseURL") as? String ??
            "http://127.0.0.1:8787"
        api = SekaiAPIClient(baseURL: URL(string: configuredURL)!)
        moderationState = ModerationStateStore()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storage = ModerationFileStore(url: directory.appendingPathComponent("moderation.json"))
        let worker = ModerationSyncWorker(api: api, clock: SystemRetryClock())
        let adapter = moderationState
        moderation = ModerationRepository(storage: storage, worker: worker) { snapshot in adapter.accept(snapshot) }
        pool = WebViewSlotPool()
        profileFactory = CreatorProfileFactory(api: api, moderation: moderationState, commands: moderation)
    }

    func start() async {
        guard feed == nil, !isStarting else { return }
        isStarting = true
        startupError = nil
        do {
            try await moderation.restore()
            feed = FeedSession(repository: FeedRepository(
                api: api, moderation: moderationState, commands: moderation), pool: pool)
        } catch { startupError = "Could not restore hidden content: " + error.localizedDescription }
        isStarting = false
    }

    func foreground() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self, moderation] in
            await moderation.retryPending()
            self?.retryTask = nil
        }
    }

    deinit { retryTask?.cancel() }
}
