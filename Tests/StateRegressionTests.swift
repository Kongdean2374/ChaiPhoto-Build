import XCTest
import AVFoundation
@testable import ChaiPhoto

final class RecordingPlayer: AVPlayer {
    var starts = 0
    override func playImmediately(atRate rate: Float) { starts += 1 }
    override func pause() {}
}

final class StateRegressionTests: XCTestCase {
    func testNewCaptureBypassesSavedCursorWithoutLosingOlderItems() {
        let result = ReviewQueueOrdering.arrange(["screenshot", "older", "cursor", "last"],
            id: { $0 }, resumeID: "cursor", priorityIDs: ["screenshot"])
        XCTAssertEqual(result, ["screenshot", "cursor", "last", "older"])
    }

    func testMultipleCapturesAndRestoresAreNotDuplicated() {
        let result = ReviewQueueOrdering.arrange(["new2", "new1", "restore", "cursor"],
            id: { $0 }, resumeID: "cursor", priorityIDs: ["new2", "new1", "restore", "new2", "deleted"])
        XCTAssertEqual(result, ["new2", "new1", "restore", "cursor"])
    }

    func testMissingCursorAndFilteredCaptureDoNotHideRemainingMedia() {
        let result = ReviewQueueOrdering.arrange(["video1", "video2"],
            id: { $0 }, resumeID: "deleted", priorityIDs: ["screenshot"])
        XCTAssertEqual(result, ["video1", "video2"])
    }

    func testLargeQueueKeepsEveryIdentifierExactlyOnce() {
        let items = (0..<10_000).map(String.init)
        let result = ReviewQueueOrdering.arrange(items, id: { $0 }, resumeID: "9000", priorityIDs: ["0", "1"])
        XCTAssertEqual(Array(result.prefix(3)), ["0", "1", "9000"])
        XCTAssertEqual(Set(result), Set(items))
        XCTAssertEqual(result.count, items.count)
    }

    @MainActor
    func testForegroundRequiresExplicitPlayback() {
        let loader = VideoLoader()
        let player = RecordingPlayer()
        loader.player = player
        loader.readyToPlay = true
        loader.setAutoplay(true)
        XCTAssertEqual(player.starts, 1)
        loader.setSceneActive(false)
        loader.setSceneActive(true)
        loader.setVisible(true)
        XCTAssertEqual(player.starts, 1)
        loader.togglePlayback()
        XCTAssertEqual(player.starts, 2)
        loader.stop()
    }

    @MainActor
    func testInvisiblePlayerDoesNotStartFromPlayCommand() {
        let loader = VideoLoader()
        let player = RecordingPlayer()
        loader.player = player
        loader.readyToPlay = true
        loader.setVisible(false)
        loader.play()
        XCTAssertEqual(player.starts, 0)
        loader.stop()
    }

    @MainActor
    func testVideoFilterAndCursorSurviveRelaunch() {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: "lastMediaFilter.v2")
        defer {
            if let previous { defaults.set(previous, forKey: "lastMediaFilter.v2") }
            else { defaults.removeObject(forKey: "lastMediaFilter.v2") }
        }
        var video = MediaFilter()
        video.source = "videos"
        video.kind = "slow"
        video.persist()
        let restored = MediaFilter.restored()
        XCTAssertEqual(restored.source, "videos")
        XCTAssertEqual(restored.kind, "slow")
        let previousCursor = restored.restoredResumeAssetID()
        defer { restored.persistResumeAssetID(previousCursor) }
        restored.persistResumeAssetID("video-中文😀")
        XCTAssertEqual(MediaFilter.restored().restoredResumeAssetID(), "video-中文😀")
        restored.persistResumeAssetID(nil)
        XCTAssertNil(restored.restoredResumeAssetID())
    }

    func testDecisionHistoryRoundTripKeepsAssetIdentityAndUndoState() throws {
        var action = DecisionAction(assetID: "stable-中文😀", before: .keep, after: .delete)
        action.undoneAt = Date()
        let decoded = try JSONDecoder().decode(DecisionAction.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(decoded.id, action.id)
        XCTAssertEqual(decoded.assetID, action.assetID)
        XCTAssertEqual(decoded.before, .keep)
        XCTAssertEqual(decoded.after, .delete)
        XCTAssertEqual(decoded.undoneAt, action.undoneAt)
    }
}
