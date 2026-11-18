import CoreGraphics
import XCTest
@testable import Quillmark

final class PresentationTests: XCTestCase {
    func testAspectFitLetterboxesWideScreen() {
        // iPad landscape content (4:3-ish) on a 1920x1080 AirPlay screen: black bars left/right.
        let rect = PresentationLayout.aspectFit(CGSize(width: 1180, height: 760), in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(rect.height, 1080, accuracy: 0.01)
        XCTAssertEqual(rect.width, 1180 * 1080 / 760, accuracy: 0.01)
        XCTAssertEqual(rect.midX, 960, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.01)
    }

    func testAspectFitPortraitContent() {
        let rect = PresentationLayout.aspectFit(CGSize(width: 820, height: 1100), in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(rect.height, 1080, accuracy: 0.01)
        XCTAssertLessThan(rect.width, 1920)
        XCTAssertEqual(PresentationLayout.aspectFit(.zero, in: CGRect(x: 0, y: 0, width: 10, height: 10)), .zero)
    }

    func testContentOnlyIsDefaultAndRemembered() throws {
        let suite = "presentation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let center = PresentationCenter(defaults: defaults)
        XCTAssertTrue(center.contentOnly, "like Goodnotes, projection shows only the content by default")
        XCTAssertFalse(center.isExternalDisplayConnected)
        XCTAssertFalse(center.isShowingContentOnly)
        center.contentOnly = false
        XCTAssertFalse(PresentationCenter(defaults: defaults).contentOnly)
    }
}
