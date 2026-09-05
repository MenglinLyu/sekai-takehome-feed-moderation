import XCTest
import Combine
@testable import Sekai

@MainActor final class ModerationRepositoryTests: XCTestCase {
    private func make(storage: MemoryStorage, api: StubAPI = StubAPI(),
                      clock: ManualClock = ManualClock(), adapter: ModerationStateStore? = nil)
        -> ModerationRepository {
        let adapter = adapter ?? ModerationStateStore()
        return ModerationRepository(storage: storage, worker: ModerationSyncWorker(api: api, clock: clock)) {
            adapter.accept($0)
        }
    }

    func testBlockAndReportRestoreBothSetsWithoutReconstructingPendingRequests() async throws {
        let storage = MemoryStorage()
        let repository = make(storage: storage)
        try await repository.restore()
        try await repository.block(creatorID: "a")
        try await repository.report(sekaiID: "g", reason: "spam")
        let restored = make(storage: storage)
        try await restored.restore()
        let snapshot = await restored.snapshot()
        XCTAssertEqual(snapshot.rules.blockedCreatorIDs, ["a"])
        XCTAssertEqual(snapshot.rules.reportedSekaiIDs, ["g"])
        XCTAssertTrue(snapshot.pendingOperations.isEmpty)
    }

    func testDiskFailureDoesNotPublishHideOrStartNetworkAndNextCommandStillWorks() async throws {
        let storage = MemoryStorage()
        let api = StubAPI()
        let worker = ObservedSyncWorker(api: api, clock: ManualClock())
        var publications: [ModerationSnapshot] = []
        let repository = ModerationRepository(storage: storage, worker: worker) { publications.append($0) }
        try await repository.restore()
        try await repository.block(creatorID: "existing_creator")
        try await repository.report(sekaiID: "existing_game", reason: "spam")
        await eventually { await worker.completedCycles.count == 2 }
        let baseline = await repository.snapshot()
        let baselinePublications = publications
        let baselineRequests = await api.intents
        let baselineRules = await storage.rules
        XCTAssertEqual(baselineRules, VisibilityRules(
            blockedCreatorIDs: ["existing_creator"], reportedSekaiIDs: ["existing_game"]))
        XCTAssertTrue(baseline.pendingOperations.isEmpty)

        await storage.setFailure(true)
        for intent in [ModerationIntent.block("new_creator"), .report("new_game", reason: "spam")] {
            do {
                switch intent {
                case .block(let id): try await repository.block(creatorID: id)
                case .report(let id, let reason): try await repository.report(sekaiID: id, reason: reason)
                }
                XCTFail("Expected local save failure")
            } catch {
                guard case SekaiError.localSave = error else {
                    XCTFail("Expected the local-save error, got: \(error)")
                    continue
                }
            }
            let snapshot = await repository.snapshot()
            let persisted = await storage.rules
            let requests = await api.intents
            XCTAssertEqual(snapshot, baseline)
            XCTAssertEqual(persisted, baselineRules)
            XCTAssertEqual(publications, baselinePublications, "Even a transient hide/rollback must not publish")
            XCTAssertEqual(requests, baselineRequests)
        }

        await storage.setFailure(false)
        try await repository.report(sekaiID: "new_game", reason: "spam")
        await eventually { await worker.completedCycles.count == 3 }
        let saved = await repository.snapshot()
        let persisted = try await storage.load()
        let requests = await api.intents
        XCTAssertEqual(saved.rules, VisibilityRules(
            blockedCreatorIDs: ["existing_creator"], reportedSekaiIDs: ["existing_game", "new_game"]))
        XCTAssertEqual(persisted, saved.rules)
        XCTAssertEqual(requests, baselineRequests + [.report("new_game", reason: "spam")])
    }

    func testCommitQueuePreventsLostUpdateAcrossSuspendedSaveAndPublishesInOrder() async throws {
        let storage = MemoryStorage()
        let worker = ControlledSyncWorker()
        var publications: [ModerationSnapshot] = []
        let repository = ModerationRepository(storage: storage, worker: worker) { publications.append($0) }
        try await repository.restore()
        let restored = await repository.snapshot()
        await storage.holdSave()
        let first = Task { try await repository.block(creatorID: "a") }
        await eventually { await storage.writes.count == 1 }
        let second = Task { try await repository.report(sekaiID: "g", reason: "spam") }
        // The second command must be accepted while the first save remains suspended.
        await eventually { await repository.queuedCommandCount == 1 }
        let before = await repository.snapshot()
        let writesBeforeRelease = await storage.writes
        let startsBeforeRelease = await worker.starts
        XCTAssertEqual(before, restored)
        XCTAssertEqual(publications, [restored])
        XCTAssertEqual(writesBeforeRelease, [VisibilityRules(blockedCreatorIDs: ["a"])])
        XCTAssertTrue(startsBeforeRelease.isEmpty)

        await storage.releaseSave()
        try await first.value
        try await second.value
        let after = await repository.snapshot()
        let writes = await storage.writes
        let starts = await worker.starts
        let blocked = VisibilityRules(blockedCreatorIDs: ["a"])
        let both = VisibilityRules(blockedCreatorIDs: ["a"], reportedSekaiIDs: ["g"])
        XCTAssertEqual(after.rules, both)
        XCTAssertEqual(writes, [blocked, both])
        XCTAssertEqual(publications.map(\.rules), [VisibilityRules(), blocked, both])
        XCTAssertEqual(publications.map(\.revision), [1, 2, 3])
        XCTAssertEqual(starts.map(\.intent), [.block("a"), .report("g", reason: "spam")])
        XCTAssertEqual(after.pendingOperations.map(\.id), starts.map(\.id),
                       "Local commits finish while both remote operations are still pending")
    }

    func testDuplicateIntentUsesOneOperationAndOneDelayedRetryThenForegroundCanRestart() async throws {
        let storage = MemoryStorage()
        let api = StubAPI()
        await api.setFailures(moderation: true)
        let clock = ManualClock()
        let worker = ObservedSyncWorker(api: api, clock: clock)
        let repository = ModerationRepository(storage: storage, worker: worker) { _ in }
        try await repository.restore()
        try await repository.block(creatorID: "a")
        await eventually { await clock.sleeps == 1 }
        try await repository.block(creatorID: "a")
        let initial = await repository.snapshot()
        XCTAssertEqual(initial.pendingOperations.count, 1)
        XCTAssertEqual(initial.pendingOperations.first?.nextRetryAt, Date(timeIntervalSince1970: 105))
        let firstCount = await api.intents.count
        XCTAssertEqual(firstCount, 1)
        await clock.advance()
        await eventually { await worker.completedCycles.count == 1 }
        let failed = await repository.snapshot()
        XCTAssertEqual(failed.rules.blockedCreatorIDs, ["a"])
        XCTAssertNotNil(failed.feedback)
        let counts = await api.intents.count
        XCTAssertEqual(counts, 2)
        XCTAssertEqual(failed.pendingOperations.first?.attemptCount, 2)
        XCTAssertNil(failed.pendingOperations.first?.nextRetryAt)
        XCTAssertEqual(failed.pendingOperations.first?.id, initial.pendingOperations.first?.id)
        let sleeps = await clock.sleeps
        let writes = await storage.writes
        XCTAssertEqual(sleeps, 1, "A finished cycle must not schedule another automatic retry")
        XCTAssertEqual(writes.count, 1, "Duplicate intents must not create another durable commit")
        await api.setFailures()
        await repository.retryPending()
        await eventually { await worker.completedCycles.count == 2 }
        let final = await repository.snapshot()
        XCTAssertEqual(final.rules.blockedCreatorIDs, ["a"])
        XCTAssertNil(final.feedback)
        XCTAssertTrue(final.pendingOperations.isEmpty)
        let finalCount = await api.intents.count
        XCTAssertEqual(finalCount, 3)
    }

    func testOutOfOrderSyncResultsOnlyRemoveTheMatchingOperation() async throws {
        let storage = MemoryStorage()
        let worker = ControlledSyncWorker()
        let repository = ModerationRepository(storage: storage, worker: worker) { _ in }
        try await repository.restore()
        try await repository.block(creatorID: "a")
        try await repository.report(sekaiID: "g", reason: "spam")
        let operations = await worker.starts
        XCTAssertEqual(operations.count, 2)
        let block = try XCTUnwrap(operations.first { $0.intent == .block("a") })
        let report = try XCTUnwrap(operations.first { $0.intent == .report("g", reason: "spam") })

        try await worker.send(block.id, .attempt(2))
        try await worker.send(block.id, .failed(nextRetryAt: nil))
        try await worker.send(block.id, .finished(success: false))
        // Complete the second operation before the first one succeeds.
        try await worker.send(report.id, .finished(success: true))
        let partial = await repository.snapshot()
        XCTAssertEqual(partial.pendingOperations.map(\.id), [block.id])
        XCTAssertEqual(partial.pendingOperations.first?.attemptCount, 2)
        XCTAssertNotNil(partial.feedback)
        let expectedRules = VisibilityRules(blockedCreatorIDs: ["a"], reportedSekaiIDs: ["g"])
        XCTAssertEqual(partial.rules, expectedRules)

        await repository.retryPending()
        let restarted = await worker.starts
        XCTAssertEqual(restarted.map(\.id), [block.id, report.id, block.id])
        try await worker.send(block.id, .finished(success: true))
        let final = await repository.snapshot()
        let persisted = try await storage.load()
        XCTAssertTrue(final.pendingOperations.isEmpty)
        XCTAssertNil(final.feedback)
        XCTAssertEqual(final.rules, expectedRules)
        XCTAssertEqual(persisted, expectedRules)
    }

    func testLateResultsFromCompletedOperationCannotChangeAnotherPendingOperation() async throws {
        let storage = MemoryStorage()
        let worker = ControlledSyncWorker()
        var publications: [ModerationSnapshot] = []
        let repository = ModerationRepository(storage: storage, worker: worker) { publications.append($0) }
        try await repository.restore()
        try await repository.block(creatorID: "a")
        try await repository.report(sekaiID: "g", reason: "spam")
        let operations = await worker.starts
        let completed = try XCTUnwrap(operations.first { $0.intent == .block("a") })
        let pending = try XCTUnwrap(operations.first { $0.intent == .report("g", reason: "spam") })
        try await worker.send(completed.id, .finished(success: true))
        let baseline = await repository.snapshot()
        let baselinePublications = publications
        let baselineWrites = await storage.writes
        XCTAssertEqual(baseline.pendingOperations.map(\.id), [pending.id])

        for event in [SyncEvent.attempt(99), .failed(nextRetryAt: nil), .finished(success: true)] {
            try await worker.send(completed.id, event)
            let snapshot = await repository.snapshot()
            let writes = await storage.writes
            XCTAssertEqual(snapshot, baseline, "Late results must not change state or revision")
            XCTAssertEqual(publications, baselinePublications)
            XCTAssertEqual(writes, baselineWrites)
        }
        // A stale completion must not clear the other operation's in-flight guard.
        await repository.retryPending()
        let starts = await worker.starts
        XCTAssertEqual(starts.map(\.id), operations.map(\.id))
        try await worker.send(pending.id, .finished(success: true))
        let final = await repository.snapshot()
        XCTAssertTrue(final.pendingOperations.isEmpty)
        XCTAssertEqual(final.rules, baseline.rules)
    }

    func testAcceptedCommitSurvivesOriginatingTaskCancellation() async throws {
        let storage = MemoryStorage()
        let repository = make(storage: storage)
        try await repository.restore()
        await storage.holdSave()
        let task = Task { try await repository.report(sekaiID: "g", reason: "spam") }
        await eventually { await storage.writes.count == 1 }
        task.cancel()
        await storage.releaseSave()
        try await task.value
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.rules.reportedSekaiIDs, ["g"])
    }

    func testRestoreFailureCanBeRetriedWithoutOverwritingSavedState() async throws {
        let storage = MemoryStorage()
        await storage.setFailure(true)
        let repository = make(storage: storage)
        do { try await repository.restore(); XCTFail("Expected load failure") } catch {}
        do { try await repository.block(creatorID: "a"); XCTFail("Expected startup gate") } catch {}
        await storage.setFailure(false)
        try await repository.restore()
        try await repository.block(creatorID: "a")
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.rules.blockedCreatorIDs, ["a"])
    }

    func testAdapterRejectsStaleRevisions() {
        let adapter = ModerationStateStore()
        var latest = ModerationSnapshot()
        let subscription = adapter.snapshots.sink { latest = $0 }
        adapter.accept(ModerationSnapshot(rules: VisibilityRules(blockedCreatorIDs: ["a"]), revision: 2))
        adapter.accept(ModerationSnapshot(revision: 1))
        XCTAssertEqual(latest.revision, 2)
        XCTAssertEqual(latest.rules.blockedCreatorIDs, ["a"])
        withExtendedLifetime(subscription) {}
    }

    func testAtomicFileStoreRoundTripAndCorruptionIsAnError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("moderation.json")
        let store = ModerationFileStore(url: url)
        let empty = try await store.load()
        XCTAssertEqual(empty, VisibilityRules())
        let expected = VisibilityRules(blockedCreatorIDs: ["a"], reportedSekaiIDs: ["g"])
        try await store.save(expected)
        let loaded = try await ModerationFileStore(url: url).load()
        XCTAssertEqual(loaded, expected)
        try Data("invalid JSON".utf8).write(to: url)
        do { _ = try await store.load(); XCTFail("Corrupt state must not silently reset") } catch {}
    }
}
