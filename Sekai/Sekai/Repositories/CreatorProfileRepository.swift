import Foundation
import Combine

struct CreatorProfileState: Equatable {
    var profile: CreatorProfile?
    var items: [SekaiItem] = []
    var isLoading = false
    var hasMore = true
    var needsContinue = false
    var error: DisplayFailure?
    var syncFeedback: String?
}

@MainActor protocol CreatorProfileRepositoryProviding: AnyObject {
    var creatorID: CreatorID { get }
    var states: AnyPublisher<CreatorProfileState, Never> { get }
    func loadInitial() async
    func loadNextPage() async
    func refresh() async
    func cancelRequests()
    func blockCreator() async throws
}

@MainActor final class CreatorProfileRepository: CreatorProfileRepositoryProviding {
    let creatorID: CreatorID
    private let api: any SekaiAPI
    private let commands: any ModerationCommands
    private let pageSize: Int
    private let raw = CurrentValueSubject<CreatorProfileState, Never>(CreatorProfileState())
    private let output = CurrentValueSubject<CreatorProfileState, Never>(CreatorProfileState())
    private var subscriptions = Set<AnyCancellable>()
    private var nextPage = 0
    private var generation = 0

    var states: AnyPublisher<CreatorProfileState, Never> { output.eraseToAnyPublisher() }

    init(creatorID: CreatorID, api: any SekaiAPI, moderation: any ModerationStateProviding,
         commands: any ModerationCommands, pageSize: Int = 10) {
        self.creatorID = creatorID
        self.api = api
        self.commands = commands
        self.pageSize = pageSize
        raw.combineLatest(moderation.snapshots.map(\.rules).removeDuplicates())
            .map { raw, rules in
                var state = raw
                state.items = SekaiVisibilityPolicy.visibleItems(in: raw.items, rules: rules)
                return state
            }
            .sink { [weak self] state in
                guard let self else { return }
                var state = state
                state.syncFeedback = self.output.value.syncFeedback
                self.output.send(state)
            }.store(in: &subscriptions)
        moderation.snapshots.map(\.feedback).removeDuplicates().sink { [weak self] feedback in
            guard let self else { return }
            var state = self.output.value
            state.syncFeedback = feedback
            self.output.send(state)
        }.store(in: &subscriptions)
    }

    func loadInitial() async {
        guard raw.value.profile == nil, !raw.value.isLoading else { return }
        generation += 1
        let requestGeneration = generation
        raw.value.isLoading = true
        raw.value.error = nil
        do {
            async let profile = api.fetchProfile(creatorID: creatorID)
            async let page = api.fetchCreatorGames(creatorID: creatorID, page: 0, size: pageSize)
            let result = try await (profile, page)
            guard generation == requestGeneration else { return }
            guard !Task.isCancelled else { raw.value.isLoading = false; return }
            var state = raw.value
            state.profile = result.0
            state.items = SekaiVisibilityPolicy.deduplicated(result.1.list)
            state.hasMore = result.1.hasMore
            state.isLoading = false
            nextPage = result.1.page + 1
            raw.send(state)
            if output.value.items.isEmpty && state.hasMore { await loadNextPage() }
        } catch {
            guard generation == requestGeneration else { return }
            raw.value.isLoading = false
            if !Task.isCancelled { raw.value.error = DisplayFailure(message: error.localizedDescription) }
        }
    }

    func loadNextPage() async {
        guard raw.value.profile != nil else { await loadInitial(); return }
        guard !raw.value.isLoading, raw.value.hasMore else { return }
        generation += 1
        let requestGeneration = generation
        raw.value.isLoading = true
        raw.value.error = nil
        raw.value.needsContinue = false
        for attempt in 0..<3 {
            let visibleIDs = Set(output.value.items.map(\.id))
            do {
                let page = try await api.fetchCreatorGames(creatorID: creatorID, page: nextPage, size: pageSize)
                guard generation == requestGeneration else { return }
                guard !Task.isCancelled else { raw.value.isLoading = false; return }
                nextPage = page.page + 1
                var state = raw.value
                state.items = SekaiVisibilityPolicy.deduplicated(state.items + page.list)
                state.hasMore = page.hasMore
                raw.send(state)
                if output.value.items.contains(where: { !visibleIDs.contains($0.id) }) || !page.hasMore { break }
                if attempt == 2 { raw.value.needsContinue = true }
            } catch {
                guard generation == requestGeneration else { return }
                if !Task.isCancelled { raw.value.error = DisplayFailure(message: error.localizedDescription) }
                break
            }
        }
        guard generation == requestGeneration else { return }
        raw.value.isLoading = false
    }

    func refresh() async {
        cancelRequests()
        nextPage = 0
        raw.send(CreatorProfileState())
        await loadInitial()
    }

    func cancelRequests() {
        generation += 1
        raw.value.isLoading = false
    }

    func blockCreator() async throws { try await commands.block(creatorID: creatorID) }
}
