import XCTest
import Combine
@testable import Sekai

@MainActor final class ViewModelTests: XCTestCase {
    func testFeedAdoptsSuppliedStateAndNavigation() {
        let repository = FeedRepositorySpy()
        let model = FeedViewModel(repository: repository)
        let supplied = FeedState(items: [item("a")], isLoading: true, hasMore: false,
                                 error: DisplayFailure(message: "Network"), syncFeedback: "Retrying")
        repository.subject.send(supplied)
        XCTAssertEqual(model.state, supplied)
        model.openCreator("creator_b")
        XCTAssertEqual(model.selectedCreatorID, "creator_b")
    }

    func testFeedForwardsReportAndBlockAndShowsLocalConfirmationWithoutEditingList() async {
        let repository = FeedRepositorySpy()
        repository.subject.send(FeedState(items: [item("a")]))
        let model = FeedViewModel(repository: repository)
        await model.report("a", reason: "spam")?.value
        XCTAssertEqual(repository.intents, [.report("a", reason: "spam")])
        XCTAssertEqual(model.feedback, ActionFeedback(message: "Content hidden.", canRetry: false))
        XCTAssertEqual(model.state.items.map(\.id), ["a"])
        await model.blockCreator("creator_a")?.value
        XCTAssertEqual(repository.intents.last, .block("creator_a"))
        XCTAssertEqual(model.feedback?.message, "Creator blocked.")
        model.dismissFeedback()
        XCTAssertNil(model.feedback)
    }

    func testFeedFailedActionCanRetrySameIdentityAndReason() async {
        let repository = FeedRepositorySpy()
        repository.fails = true
        let model = FeedViewModel(repository: repository)
        await model.report("a", reason: "abusive content")?.value
        XCTAssertEqual(model.feedback?.canRetry, true)
        repository.fails = false
        model.retryAction()
        await eventually { repository.intents.count == 2 && model.feedback?.canRetry == false }
        XCTAssertEqual(repository.intents, [
            .report("a", reason: "abusive content"), .report("a", reason: "abusive content")
        ])
    }

    func testFeedOwnsOnePageTaskAndRefreshCancelsPreviousRequest() async {
        let repository = FeedRepositorySpy()
        repository.hold = true
        let model = FeedViewModel(repository: repository)
        let old = model.loadNextPage()
        _ = model.loadNextPage()
        await eventually { repository.loads == 1 }
        await model.refresh().value
        XCTAssertEqual(repository.refreshes, 1)
        XCTAssertEqual(repository.cancellations, 1)
        repository.waiter?.resume()
        repository.waiter = nil
        await old?.value
        repository.hold = false
        await model.loadNextPage()?.value
        XCTAssertEqual(repository.loads, 2)
        model.stop()
        XCTAssertEqual(repository.cancellations, 2)
    }

    func testCancelledOldFeedTaskCannotClearNewTaskOwnership() async {
        let repository = FeedRepositorySpy()
        repository.hold = true
        let model = FeedViewModel(repository: repository)
        let old = model.loadNextPage()
        await eventually { repository.waiter != nil }
        let oldWaiter = repository.waiter
        model.stop()
        repository.waiter = nil
        let new = model.loadNextPage()
        await eventually { repository.loads == 2 && repository.waiter != nil }
        oldWaiter?.resume()
        await old?.value
        _ = model.loadNextPage()
        await Task.yield()
        XCTAssertEqual(repository.loads, 2)
        repository.waiter?.resume()
        repository.waiter = nil
        await new?.value
    }

    func testProfileAdoptsPublisherStateAndImmutableCreatorIdentity() {
        let repository = ProfileRepositorySpy(creatorID: "creator_b")
        let model = CreatorProfileViewModel(repository: repository)
        let supplied = CreatorProfileState(profile: profile("creator_b"), items: [item("a")],
                                            hasMore: false, syncFeedback: "Sync failed")
        repository.subject.send(supplied)
        XCTAssertEqual(model.creatorID, "creator_b")
        XCTAssertEqual(model.state, supplied)
    }

    func testProfileForwardsLoadingAndBlockThenReliesOnRepositoryForEmptyState() async {
        let repository = ProfileRepositorySpy()
        let model = CreatorProfileViewModel(repository: repository)
        repository.subject.send(CreatorProfileState(items: [item("a")]))
        await model.loadInitial()?.value
        await model.loadNextPage()?.value
        await model.blockCreator()?.value
        XCTAssertEqual(repository.initialLoads, 1)
        XCTAssertEqual(repository.pageLoads, 1)
        XCTAssertEqual(repository.blocks, 1)
        XCTAssertEqual(model.feedback?.message, "Creator blocked.")
        XCTAssertEqual(model.state.items.map(\.id), ["a"])
        repository.subject.send(CreatorProfileState(items: [], hasMore: false))
        XCTAssertTrue(model.state.items.isEmpty)
        model.stop()
        XCTAssertEqual(repository.cancellations, 1)
    }

    func testProfileFailedBlockCanRetryAndDismissFeedback() async {
        let repository = ProfileRepositorySpy()
        repository.fails = true
        let model = CreatorProfileViewModel(repository: repository)
        await model.blockCreator()?.value
        XCTAssertEqual(model.feedback?.canRetry, true)
        repository.fails = false
        model.retryAction()
        await eventually { repository.blocks == 2 && model.feedback?.canRetry == false }
        model.dismissFeedback()
        model.retryAction()
        XCTAssertNil(model.feedback)
        XCTAssertEqual(repository.blocks, 2)
    }
}
