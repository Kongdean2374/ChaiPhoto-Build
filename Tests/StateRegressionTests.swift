import XCTest
import AVFoundation
@testable import ChaiPhoto

final class RecordingPlayer: AVPlayer {
    var starts = 0
    override func playImmediately(atRate rate: Float) { starts += 1 }
    override func pause() {}
}

final class StateRegressionTests: XCTestCase {
    @MainActor
    func testRetiredAnalysisFiltersKeepSourceDatesAndOrdinaryCursor() throws {
        let defaults = UserDefaults.standard
        let key = "lastMediaFilter.v2"
        let previous = defaults.data(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let end = start.addingTimeInterval(86_400)
        for (source, kind) in [("photos", "appDuplicates"), ("videos", "appVideoDuplicates"), ("videos", "appLarge")] {
            var ordinary = MediaFilter()
            ordinary.source = source; ordinary.start = start; ordinary.end = end
            ordinary.timeMode = "month"; ordinary.dateEnabled = true
            let oldCursor = ordinary.restoredResumeAssetID()
            defer { ordinary.persistResumeAssetID(oldCursor) }
            ordinary.persistResumeAssetID("ordinary-cursor")
            let saved: [String: Any] = ["source": source, "kind": kind, "albumID": "", "albumName": "",
                "timeMode": "month", "dateEnabled": true,
                "start": start.timeIntervalSinceReferenceDate, "end": end.timeIntervalSinceReferenceDate]
            defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: key)
            let restored = MediaFilter.restored()
            XCTAssertEqual(restored.source, source)
            XCTAssertEqual(restored.kind, "all")
            XCTAssertNil(restored.allowedIDs)
            XCTAssertTrue(restored.dateEnabled)
            XCTAssertEqual(restored.timeMode, "month")
            XCTAssertEqual(restored.start, start); XCTAssertEqual(restored.end, end)
            XCTAssertEqual(restored.restoredResumeAssetID(), "ordinary-cursor")
            let normalized = try XCTUnwrap(defaults.data(forKey: key))
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: normalized) as? [String: Any])
            XCTAssertEqual(value["kind"] as? String, "all")
        }
    }

    func testRetiredCacheCleanupPreservesEveryUnrelatedFile() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let retired = ["media-analysis.json", "analysis-features-\(UUID().uuidString)"]
        let retained = ["sorting-history.json", "photos.json", "analysis-features-not-a-uuid", "unrelated.cache"]
        for name in retired + retained { try Data("sentinel".utf8).write(to: folder.appendingPathComponent(name)) }
        try RetiredAnalysisMigration.removeCache(in: folder)
        XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: folder.path)), Set(retained))
        for name in retained { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), Data("sentinel".utf8)) }
    }

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
