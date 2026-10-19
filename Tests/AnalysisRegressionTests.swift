import XCTest
import UIKit
import Photos
@testable import ChaiPhoto

final class AnalysisRegressionTests: XCTestCase {
    private func item(_ id: String, time: Double = 1000, modified: Double = 1000, video: Bool = false, duration: Double = 0, favorite: Bool = false) throws -> AnalysisMetadata {
        let value: [String: Any] = ["id": id, "created": time, "modified": modified, "width": 1920, "height": 1080,
                                  "type": video ? 2 : 1, "subtypes": 0, "favorite": favorite, "duration": duration, "albums": []]
        return try JSONDecoder().decode(AnalysisMetadata.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testDenseMetadataCandidatesStayBoundedAndNeverCrossMediaTypes() throws {
        var items = try (0..<10_000).map { try item(String(format: "%05d", $0)) }
        items.append(try item("video", video: true, duration: 20))
        let plan = AnalysisCandidatePlan(items)
        XCTAssertTrue(plan.previous.values.allSatisfy { $0.count <= 32 })
        XCTAssertLessThanOrEqual(plan.previous.values.reduce(0) { $0 + $1.count }, items.count * 32)
        XCTAssertNil(plan.previous["video"])
        XCTAssertTrue(plan.required.contains("00000"))
    }
    func testVideoDurationRejectsMisleadingMatchingPosters() throws {
        let first = try item("a", video: true, duration: 30)
        let close = try item("b", time: 1010, video: true, duration: 30.1)
        let different = try item("c", time: 1010, video: true, duration: 31)
        XCTAssertTrue(first.candidate(with: close))
        XCTAssertFalse(first.candidate(with: different))
    }
    func testFeatureKeyReusesUnchangedMediaButInvalidatesEdits() throws {
        let first = try item("a")
        XCTAssertEqual(AnalysisFeatureStore.key(first), AnalysisFeatureStore.key(try item("a", favorite: true)))
        XCTAssertNotEqual(AnalysisFeatureStore.key(first), AnalysisFeatureStore.key(try item("a", modified: 1001)))
        XCTAssertNotEqual(AnalysisFeatureStore.key(first), AnalysisFeatureStore.key(first, suffix: "frame-0"))
    }
    func testVisionFeatureSurvivesDiskRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try item("fixture")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 216), format: format).image { ctx in
            for x in 0..<12 {
                UIColor(hue: CGFloat(x) / 12, saturation: 0.85, brightness: x.isMultiple(of: 2) ? 1 : 0.4, alpha: 1).setFill()
                ctx.fill(CGRect(x: CGFloat(x * 32), y: 0, width: 32, height: 216))
            }
        }
        let key = AnalysisFeatureStore.key(item)
        XCTAssertTrue(try AnalysisFeatureStore(folder: folder).generate(image, item: item, key: key))
        let restored = AnalysisFeatureStore(folder: folder)
        XCTAssertTrue(restored.exists(key))
        XCTAssertEqual(restored.compare(key, key, video: false), .highlySimilar)
    }
    func testAnalysisPreheatingCannotInheritDownloadPermissions() {
        let window = AnalysisThumbnailWindow()
        XCTAssertFalse(window.options.isNetworkAccessAllowed)
        XCTAssertEqual(window.size, CGSize(width: 384, height: 384))
        window.stop()
    }
}
