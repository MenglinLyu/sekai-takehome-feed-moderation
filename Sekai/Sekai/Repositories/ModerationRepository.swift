import Foundation
import Combine

protocol ModerationCommands: Sendable {
    func block(creatorID: CreatorID) async throws
    func report(sekaiID: SekaiID, reason: String) async throws
}

@MainActor protocol ModerationStateProviding: AnyObject {
    var snapshots: AnyPublisher<ModerationSnapshot, Never> { get }
}

@MainActor final class ModerationStateStore: ModerationStateProviding {
    private let subject = CurrentValueSubject<ModerationSnapshot, Never>(ModerationSnapshot())
    var snapshots: AnyPublisher<ModerationSnapshot, Never> { subject.eraseToAnyPublisher() }

    func accept(_ snapshot: ModerationSnapshot) {
        guard snapshot.revision > subject.value.revision else { return }
        subject.send(snapshot)
    }
}

enum SyncEvent: Sendable {
    case attempt(Int)
    case failed(nextRetryAt: Date?)
    case finished(success: Bool)
}

protocol ModerationSyncing: Sendable {
    func start(_ operation: PendingOperation,
               deliver: @escaping @Sendable (UUID, SyncEvent) async -> Void) async
    func cancelAll() async
}

actor ModerationSyncWorker: ModerationSyncing {
    private let api: any SekaiAPI
    private let clock: any RetryClock
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(api: any SekaiAPI, clock: any RetryClock) {
        self.api = api
        self.clock = clock
    }

    func start(_ operation: PendingOperation,
               deliver: @escaping @Sendable (UUID, SyncEvent) async -> Void) {
        guard tasks[operation.id] == nil else { return }
        tasks[operation.id] = Task { [weak self, api, clock] in
            var success = false
            for offset in 1...2 {
                if Task.isCancelled { break }
                await deliver(operation.id, .attempt(operation.attemptCount + offset))
                do {
                    switch operation.intent {
                    case .block(let id): try await api.block(creatorID: id)
                    case .report(let id, let reason): try await api.report(sekaiID: id, reason: reason)
                    }
                    success = true
                    break
                } catch {
                    if Task.isCancelled { break }
                    let retryAt = offset == 1 ? await clock.now().addingTimeInterval(5) : nil
                    await deliver(operation.id, .failed(nextRetryAt: retryAt))
                    if offset == 1 {
                        do { try await clock.sleep() } catch { break }
                    }
                }
            }
            await self?.remove(operation.id)
            await deliver(operation.id, .finished(success: success))
        }
    }

    private func remove(_ id: UUID) { tasks[id] = nil }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}

actor ModerationRepository: ModerationCommands {
    private enum Job {
        case restore(CheckedContinuation<Void, Error>)
        case command(ModerationIntent, CheckedContinuation<Void, Error>)
        case result(UUID, SyncEvent, CheckedContinuation<Void, Never>)
        case retry(CheckedContinuation<Void, Never>)
    }

    private let storage: any ModerationStorage
    private let worker: any ModerationSyncing
    private let publish: @MainActor @Sendable (ModerationSnapshot) -> Void
    private var state = ModerationSnapshot()
    private var restored = false
    private var jobs: [Job] = []
    private var drainTask: Task<Void, Never>?
    private var running: Set<UUID> = []

    init(storage: any ModerationStorage, worker: any ModerationSyncing,
         publish: @escaping @MainActor @Sendable (ModerationSnapshot) -> Void) {
        self.storage = storage
        self.worker = worker
        self.publish = publish
    }

    func restore() async throws {
        try await withCheckedThrowingContinuation { enqueue(.restore($0)) }
    }

    func block(creatorID: CreatorID) async throws {
        try await submit(.block(creatorID))
    }

    func report(sekaiID: SekaiID, reason: String) async throws {
        try await submit(.report(sekaiID, reason: reason))
    }

    private func submit(_ intent: ModerationIntent) async throws {
        // Once enqueued, a local commit survives cancellation of its originating page.
        try await withCheckedThrowingContinuation { enqueue(.command(intent, $0)) }
    }

    func retryPending() async {
        await withCheckedContinuation { enqueue(.retry($0)) }
    }

    func snapshot() -> ModerationSnapshot { state }

    // Read-only diagnostics let tests establish overlap without guessing executor timing.
    var queuedCommandCount: Int {
        jobs.reduce(0) { count, job in
            if case .command = job { return count + 1 }
            return count
        }
    }

    func shutdown() async { await worker.cancelAll() }

    private func enqueue(_ job: Job) {
        jobs.append(job)
        guard drainTask == nil else { return }
        drainTask = Task { await drain() }
    }

    private func drain() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            switch job {
            case .restore(let continuation):
                do {
                    if !restored {
                        state.rules = try await storage.load()
                        restored = true
                        await commitPublication()
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            case .command(let intent, let continuation):
                do {
                    guard restored else { throw SekaiError.notRestored }
                    if let existing = state.pendingOperations.first(where: { $0.intent.key == intent.key }) {
                        await start(existing)
                    } else {
                        var candidate = state.rules
                        intent.apply(to: &candidate)
                        // Already synchronized or restored hidden intent needs no invented request.
                        if candidate != state.rules {
                            do { try await storage.save(candidate) } catch { throw SekaiError.localSave }
                            let operation = PendingOperation(id: UUID(), intent: intent)
                            state.rules = candidate
                            state.pendingOperations.append(operation)
                            await commitPublication()
                            await start(operation)
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            case .result(let id, let event, let continuation):
                if let index = state.pendingOperations.firstIndex(where: { $0.id == id }) {
                    switch event {
                    case .attempt(let count):
                        state.pendingOperations[index].attemptCount = count
                        state.pendingOperations[index].nextRetryAt = nil
                    case .failed(let date):
                        state.pendingOperations[index].nextRetryAt = date
                        state.feedback = "Hidden on this device. Sync failed; we’ll retry during this session."
                    case .finished(let success):
                        running.remove(id)
                        if success { state.pendingOperations.remove(at: index) }
                        if state.pendingOperations.isEmpty { state.feedback = nil }
                    }
                    await commitPublication()
                }
                continuation.resume()
            case .retry(let continuation):
                for operation in state.pendingOperations { await start(operation) }
                continuation.resume()
            }
        }
        drainTask = nil
    }

    private func start(_ operation: PendingOperation) async {
        guard running.insert(operation.id).inserted else { return }
        await worker.start(operation) { [weak self] id, event in
            await self?.receive(id, event)
        }
    }

    private func receive(_ id: UUID, _ event: SyncEvent) async {
        await withCheckedContinuation { enqueue(.result(id, event, $0)) }
    }

    private func commitPublication() async {
        state.revision += 1
        await publish(state)
    }
}
