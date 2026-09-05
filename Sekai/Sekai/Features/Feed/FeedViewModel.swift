import Foundation
import Combine

struct ActionFeedback: Equatable {
    let message: String
    let canRetry: Bool
}

@MainActor final class FeedViewModel: ObservableObject {
    @Published private(set) var state = FeedState()
    @Published private(set) var feedback: ActionFeedback?
    @Published var selectedCreatorID: CreatorID?
    private let repository: any FeedRepositoryProviding
    private var subscription: AnyCancellable?
    private var pageTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var retry: (() -> Void)?

    init(repository: any FeedRepositoryProviding) {
        self.repository = repository
        subscription = repository.states.sink { [weak self] in self?.state = $0 }
    }

    @discardableResult func loadNextPage() -> Task<Void, Never>? {
        guard pageTask == nil else { return pageTask }
        pageTask = Task { [weak self, repository] in
            await repository.loadNextPage()
            if !Task.isCancelled { self?.pageTask = nil }
        }
        return pageTask
    }

    @discardableResult func refresh() -> Task<Void, Never> {
        pageTask?.cancel()
        repository.cancelRequests()
        let task = Task { [weak self, repository] in
            await repository.refresh()
            if !Task.isCancelled { self?.pageTask = nil }
        }
        pageTask = task
        return task
    }

    @discardableResult func report(_ id: SekaiID, reason: String) -> Task<Void, Never>? {
        perform(message: "Content hidden.", retry: { [weak self] in self?.report(id, reason: reason) }) {
            try await self.repository.report(id, reason: reason)
        }
    }

    @discardableResult func blockCreator(_ id: CreatorID) -> Task<Void, Never>? {
        perform(message: "Creator blocked.", retry: { [weak self] in self?.blockCreator(id) }) {
            try await self.repository.blockCreator(id)
        }
    }

    private func perform(message: String, retry: @escaping () -> Void,
                         action: @escaping @MainActor () async throws -> Void) -> Task<Void, Never>? {
        guard actionTask == nil else { return actionTask }
        let task = Task { [weak self] in
            do {
                try await action()
                self?.feedback = ActionFeedback(message: message, canRetry: false)
                self?.retry = nil
            } catch {
                self?.feedback = ActionFeedback(message: error.localizedDescription, canRetry: true)
                self?.retry = retry
            }
            self?.actionTask = nil
        }
        actionTask = task
        return task
    }

    func retryAction() { retry?() }
    func dismissFeedback() { feedback = nil; retry = nil }
    func openCreator(_ id: CreatorID) { selectedCreatorID = id }

    func stop() {
        pageTask?.cancel()
        pageTask = nil
        repository.cancelRequests()
        actionTask?.cancel()
    }

    deinit {
        pageTask?.cancel()
        actionTask?.cancel()
    }
}
