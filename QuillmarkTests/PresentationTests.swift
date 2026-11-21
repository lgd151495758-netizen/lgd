import CoreGraphics
import UIKit
import XCTest
@testable import Quillmark

final class PresentationTests: XCTestCase {
    func testAspectFitLetterboxesWideScreen() {
        let rect = PresentationLayout.aspectFit(CGSize(width: 1180, height: 760), in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(rect.height, 1080, accuracy: 0.01)
        XCTAssertEqual(rect.width, 1180 * 1080 / 760, accuracy: 0.01)
        XCTAssertEqual(rect.midX, 960, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.01)
    }

    func testFillScreenExtendsHeightForTallerExternalDisplays() {
        // iPad Air 4 landscape content area (1180 x 674) -> 1.44 AirPlay / 16:10 / 4:3 displays.
        let iPadVisible = CGSize(width: 1180, height: 674)

        let airplay144 = PresentationViewport.compute(visibleSize: iPadVisible,
                                                      externalSize: CGSize(width: 1180, height: 820),
                                                      fillMode: .fillScreen)
        XCTAssertEqual(airplay144.contentHeight, 820, accuracy: 1)
        XCTAssertEqual(airplay144.extraBottomInset, 146, accuracy: 1)
        XCTAssertEqual(airplay144.captureRect.width, 1180, accuracy: 0.01)
        XCTAssertEqual(airplay144.captureRect.height, 820, accuracy: 1)
        let frame144 = PresentationLayout.frame(for: airplay144.captureRect.size,
                                                in: CGRect(x: 0, y: 0, width: 2360, height: 1640),
                                                mode: .fillScreen)
        XCTAssertEqual(frame144, CGRect(x: 0, y: 0, width: 2360, height: 1640), "zero black bars on 1.44 display")

        let monitor1610 = PresentationViewport.compute(visibleSize: iPadVisible,
                                                       externalSize: CGSize(width: 1920, height: 1200),
                                                       fillMode: .fillScreen)
        XCTAssertEqual(monitor1610.contentHeight, 738, accuracy: 1)
        XCTAssertGreaterThan(monitor1610.extraBottomInset, 60)
        let frame1610 = PresentationLayout.frame(for: monitor1610.captureRect.size,
                                                 in: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                                                 mode: .fillScreen)
        XCTAssertEqual(frame1610, CGRect(x: 0, y: 0, width: 1920, height: 1200), "zero black bars on 16:10 display")

        let projector43 = PresentationViewport.compute(visibleSize: iPadVisible,
                                                       externalSize: CGSize(width: 1024, height: 768),
                                                       fillMode: .fillScreen)
        XCTAssertEqual(projector43.contentHeight, 885, accuracy: 1)
        let frame43 = PresentationLayout.frame(for: projector43.captureRect.size,
                                               in: CGRect(x: 0, y: 0, width: 1024, height: 768),
                                               mode: .fillScreen)
        XCTAssertEqual(frame43, CGRect(x: 0, y: 0, width: 1024, height: 768), "zero black bars on 4:3 projector")
    }

    func testFillScreenSlicesHeightForWiderDisplaysAndTracksPen() {
        // Portrait iPad (820 x 1034) projecting to a 16:9 monitor (1920 x 1080).
        let portrait = CGSize(width: 820, height: 1034)
        let wide169 = CGSize(width: 1920, height: 1080)

        let top = PresentationViewport.compute(visibleSize: portrait, externalSize: wide169, fillMode: .fillScreen)
        XCTAssertEqual(top.extraBottomInset, 0)
        XCTAssertEqual(top.captureRect.minY, 0)
        XCTAssertEqual(top.captureRect.height, floor(820 / (1920.0 / 1080.0)), accuracy: 1)
        let frame169 = PresentationLayout.frame(for: top.captureRect.size,
                                                in: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                                mode: .fillScreen)
        XCTAssertEqual(frame169, CGRect(x: 0, y: 0, width: 1920, height: 1080), "zero black bars on 16:9 monitor")

        // Writing near the bottom shifts captureOriginY so the active pen stays on screen.
        let shifted = PresentationViewport.compute(visibleSize: portrait, externalSize: wide169,
                                                   fillMode: .fillScreen, focusY: 850, currentOriginY: 0)
        XCTAssertGreaterThan(shifted.captureRect.minY, 350)
        XCTAssertTrue(shifted.captureRect.contains(CGPoint(x: 100, y: 850)))
    }

    func testAspectFitModeNeverExtendsContent() {
        let vp = PresentationViewport.compute(visibleSize: CGSize(width: 1180, height: 674),
                                              externalSize: CGSize(width: 1024, height: 768),
                                              fillMode: .aspectFit)
        XCTAssertEqual(vp.contentHeight, 674)
        XCTAssertEqual(vp.extraBottomInset, 0)
        XCTAssertEqual(vp.captureRect, CGRect(x: 0, y: 0, width: 1180, height: 674))
    }

    func testContentOnlyAndFillModeArePersisted() throws {
        let suite = "presentation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let center = PresentationCenter(defaults: defaults)
        XCTAssertTrue(center.contentOnly, "projection shows only content by default")
        XCTAssertEqual(center.fillMode, .fillScreen, "fills all four edges by default")
        XCTAssertFalse(center.isExternalDisplayConnected)
        XCTAssertFalse(center.isShowingContentOnly)

        center.contentOnly = false
        center.fillMode = .aspectFit

        let reloaded = PresentationCenter(defaults: defaults)
        XCTAssertFalse(reloaded.contentOnly)
        XCTAssertEqual(reloaded.fillMode, .aspectFit)
    }

    @MainActor
    func testSceneAccessoryBridgeDoesNotCrash() {
        let vc = UIViewController()
        let token = SceneAccessoryBridge.registerExternalDisplay(on: vc)
        SceneAccessoryBridge.unregister(token, from: vc)
    }
}
