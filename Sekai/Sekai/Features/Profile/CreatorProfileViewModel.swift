import Foundation
import Combine

@MainActor final class CreatorProfileViewModel: ObservableObject {
    let creatorID: CreatorID
    @Published private(set) var state = CreatorProfileState()
    @Published private(set) var feedback: ActionFeedback?
    private let repository: any CreatorProfileRepositoryProviding
    private var subscription: AnyCancellable?
    private var pageTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?

    init(repository: any CreatorProfileRepositoryProviding) {
        self.repository = repository
        creatorID = repository.creatorID
        subscription = repository.states.sink { [weak self] in self?.state = $0 }
    }

    @discardableResult func loadInitial() -> Task<Void, Never>? {
        guard pageTask == nil else { return pageTask }
        pageTask = Task { [weak self, repository] in
            await repository.loadInitial()
            if !Task.isCancelled { self?.pageTask = nil }
        }
        return pageTask
    }

    @discardableResult func loadNextPage() -> Task<Void, Never>? {
        guard pageTask == nil else { return pageTask }
        pageTask = Task { [weak self, repository] in
            await repository.loadNextPage()
            if !Task.isCancelled { self?.pageTask = nil }
        }
        return pageTask
    }

    @discardableResult func blockCreator() -> Task<Void, Never>? {
        guard actionTask == nil else { return actionTask }
        actionTask = Task { [weak self, repository] in
            do {
                try await repository.blockCreator()
                self?.feedback = ActionFeedback(message: "Creator blocked.", canRetry: false)
            } catch {
                self?.feedback = ActionFeedback(message: error.localizedDescription, canRetry: true)
            }
            self?.actionTask = nil
        }
        return actionTask
    }

    func retryAction() {
        guard feedback?.canRetry == true else { return }
        blockCreator()
    }

    func dismissFeedback() { feedback = nil }

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

@MainActor final class CreatorProfileFactory {
    private let api: any SekaiAPI
    private let moderation: any ModerationStateProviding
    private let commands: any ModerationCommands

    init(api: any SekaiAPI, moderation: any ModerationStateProviding, commands: any ModerationCommands) {
        self.api = api
        self.moderation = moderation
        self.commands = commands
    }

    func make(creatorID: CreatorID) -> CreatorProfileViewModel {
        CreatorProfileViewModel(repository: CreatorProfileRepository(
            creatorID: creatorID, api: api, moderation: moderation, commands: commands))
    }
}
