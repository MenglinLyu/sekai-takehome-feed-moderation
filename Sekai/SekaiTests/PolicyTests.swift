import XCTest
@testable import Sekai

final class PolicyTests: XCTestCase {
    func testVisibilityExcludesBothRulesAndPreservesStableOrder() {
        let items = [item("a"), item("b", creator: "b"), item("c", creator: "b"), item("c", creator: "b")]
        let raw = SekaiVisibilityPolicy.deduplicated(items)
        let visible = SekaiVisibilityPolicy.visibleItems(in: raw,
            rules: VisibilityRules(blockedCreatorIDs: ["creator_a"], reportedSekaiIDs: ["b"]))
        XCTAssertEqual(visible.map(\.id), ["c"])
    }

    func testEveryControllerPlaybackGateMustPass() {
        for foreground in [false, true] {
            for displayed in [false, true] {
                for settled in [false, true] {
                    XCTAssertEqual(PlaybackPolicy.eligibleTarget(
                        currentID: "a", visibleIDs: ["a"], foreground: foreground,
                        displayed: displayed, settled: settled),
                        foreground && displayed && settled ? "a" : nil)
                }
            }
        }
        XCTAssertNil(PlaybackPolicy.eligibleTarget(currentID: "a", visibleIDs: ["b"],
            foreground: true, displayed: true, settled: true))
        XCTAssertNil(PlaybackPolicy.eligibleTarget(currentID: nil, visibleIDs: ["a"],
            foreground: true, displayed: true, settled: true))
    }

    func testReplacementChoosesFirstSurvivingSuccessorThenPredecessor() {
        let old = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(PlaybackPolicy.replacement(oldIDs: old, newIDs: ["a", "e"], currentID: "c"), "e")
        XCTAssertEqual(PlaybackPolicy.replacement(oldIDs: old, newIDs: ["a", "b"], currentID: "c"), "b")
        XCTAssertEqual(PlaybackPolicy.replacement(oldIDs: old, newIDs: ["c", "e"], currentID: "c"), "c")
        XCTAssertNil(PlaybackPolicy.replacement(oldIDs: old, newIDs: [], currentID: "c"))
        XCTAssertEqual(PlaybackPolicy.replacement(oldIDs: [], newIDs: ["new"], currentID: nil), "new")
    }

    func testFeedWireDTOUsesSnakeCaseAndBareArray() throws {
        let json = """
        [{"game_id":"a","title":"A","game_url":"http://localhost/content/a",
          "cover_url":"http://localhost/avatar/a","creator_id":"c","creator_name":"C","like_count":7}]
        """
        let items = try JSONDecoder().decode([SekaiItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.first?.gameID, "a")
        XCTAssertEqual(items.first?.creatorID, "c")
        XCTAssertEqual(items.first?.likeCount, 7)
    }
}
