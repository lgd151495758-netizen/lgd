import CoreGraphics
import PDFKit
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

    // MARK: Async Off-Main-Thread PDF Projection Renderer Tests

    func testPDFProjectionRendererPreservesOrientationInkAndMultiPageComposition() throws {
        let url = try makeTestPDF(pageCount: 2, pageSize: CGSize(width: 400, height: 600)) { pageIndex, ctx, rect in
            if pageIndex == 0 {
                // Page 0: Red top half, Blue bottom half (UIKit top-left coordinates inside UIGraphicsPDFRenderer).
                UIColor(red: 0.92, green: 0.12, blue: 0.12, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height / 2))
                UIColor(red: 0.12, green: 0.25, blue: 0.92, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: rect.height / 2, width: rect.width, height: rect.height / 2))
            } else {
                // Page 1: Solid green.
                UIColor(red: 0.12, green: 0.82, blue: 0.20, alpha: 1).setFill()
                ctx.fill(rect)
            }
        }
        defer { try? FileManager.default.removeItem(at: url) }

        // Bright yellow ink stroke horizontally across the middle of Page 0 (y = 300 in page space).
        let yellowStroke = InkStroke(
            id: UUID(),
            pen: .ballpoint,
            color: RGBAColor(0.98, 0.92, 0.08, 1.0),
            width: 36,
            smoothing: 0,
            points: [
                InkPoint(x: 40, y: 300, t: 0),
                InkPoint(x: 360, y: 300, t: 0.1),
            ]
        )

        let renderer = PDFProjectionRenderer()
        let page0Rect = CGRect(x: 50, y: 10, width: 400, height: 600)
        let page1Rect = CGRect(x: 50, y: 630, width: 400, height: 600)
        let request = PDFProjectionFrameRequest(
            pdfURL: url,
            documentRevision: 1,
            displayBox: .cropBox,
            captureSize: CGSize(width: 500, height: 800),
            outputScale: 1.0,
            backgroundColor: CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1),
            pages: [
                PDFProjectionPageSlice(
                    pageIndex: 0,
                    frameInCapture: page0Rect,
                    inkToCaptureTransform: CGAffineTransform(translationX: page0Rect.minX, y: page0Rect.minY),
                    strokes: [yellowStroke]
                ),
                PDFProjectionPageSlice(
                    pageIndex: 1,
                    frameInCapture: page1Rect,
                    inkToCaptureTransform: CGAffineTransform(translationX: page1Rect.minX, y: page1Rect.minY),
                    strokes: []
                ),
            ],
            floatingScratchpad: nil,
            isFastMotion: false
        )

        var deliveredOnMain = false
        let exp = expectation(description: "render completed")
        var renderedImage: UIImage?
        renderer.render(request) { image in
            deliveredOnMain = Thread.isMainThread
            renderedImage = image
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        XCTAssertTrue(deliveredOnMain, "completion must deliver on main thread")
        let image = try XCTUnwrap(renderedImage)
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, 500)
        XCTAssertEqual(cg.height, 800)

        // Top half of Page 0 must be Red (not flipped upside down!).
        let topPixel = sampleRGBA(in: cg, x: 250, y: 120)
        XCTAssertGreaterThan(topPixel.r, 200, "top of page 0 should be red")
        XCTAssertLessThan(topPixel.b, 60)

        // Middle of Page 0 must show the Yellow vector stroke.
        let inkPixel = sampleRGBA(in: cg, x: 250, y: 310)
        XCTAssertGreaterThan(inkPixel.r, 210, "yellow ink should render on page 0")
        XCTAssertGreaterThan(inkPixel.g, 200, "yellow ink should render on page 0")
        XCTAssertLessThan(inkPixel.b, 60)

        // Bottom half of Page 0 must be Blue.
        let bottomPixel = sampleRGBA(in: cg, x: 250, y: 500)
        XCTAssertGreaterThan(bottomPixel.b, 200, "bottom of page 0 should be blue")
        XCTAssertLessThan(bottomPixel.r, 60)

        // Visible top portion of Page 1 must be Green.
        let page1Pixel = sampleRGBA(in: cg, x: 250, y: 700)
        XCTAssertGreaterThan(page1Pixel.g, 180, "page 1 below page 0 should be green")
        XCTAssertLessThan(page1Pixel.r, 60)
    }

    func testPDFProjectionRendererCachesPagesUpgradesAfterScrollAndEnforcesBudget() throws {
        let url = try makeTestPDF(pageCount: 6, pageSize: CGSize(width: 400, height: 600)) { pageIndex, ctx, rect in
            let shade = CGFloat(pageIndex + 1) / 7.0
            UIColor(red: shade, green: 0.4, blue: 1.0 - shade, alpha: 1).setFill()
            ctx.fill(rect)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let renderer = PDFProjectionRenderer()

        func renderSync(pageIndex: Int, scale: CGFloat, fastMotion: Bool, offsetY: CGFloat = 0) -> UIImage? {
            let exp = expectation(description: "render p\(pageIndex)")
            var out: UIImage?
            let rect = CGRect(x: 0, y: offsetY, width: 400, height: 600)
            let req = PDFProjectionFrameRequest(
                pdfURL: url,
                documentRevision: 1,
                displayBox: .cropBox,
                captureSize: CGSize(width: 400, height: 500),
                outputScale: scale,
                backgroundColor: CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1),
                pages: [
                    PDFProjectionPageSlice(
                        pageIndex: pageIndex,
                        frameInCapture: rect,
                        inkToCaptureTransform: .identity,
                        strokes: []
                    ),
                ],
                floatingScratchpad: nil,
                isFastMotion: fastMotion
            )
            renderer.render(req) { img in
                out = img
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5.0)
            return out
        }

        // 1. Fast-scroll frame 1 on page 0 -> cold rasterize.
        XCTAssertNotNil(renderSync(pageIndex: 0, scale: 1.0, fastMotion: true, offsetY: 0))
        let afterCold = renderer.cacheStats()
        XCTAssertEqual(afterCold.pageRasterizeCount, 1)
        XCTAssertEqual(afterCold.cacheHitCount, 0)

        // 2. Fast-scroll frame 2 on page 0 at a different scroll offset -> pure cache hit (zero re-rasterize!).
        XCTAssertNotNil(renderSync(pageIndex: 0, scale: 1.0, fastMotion: true, offsetY: -80))
        let afterFastHit = renderer.cacheStats()
        XCTAssertEqual(afterFastHit.pageRasterizeCount, 1, "scrolling same page must hit bitmap cache")
        XCTAssertEqual(afterFastHit.cacheHitCount, 1)

        // 3. Scroll settles at full crisp scale (1.75x) -> upgrades cached bitmap cleanly.
        XCTAssertNotNil(renderSync(pageIndex: 0, scale: 1.75, fastMotion: false, offsetY: -80))
        let afterUpgrade = renderer.cacheStats()
        XCTAssertEqual(afterUpgrade.pageRasterizeCount, 2, "settled high-res frame should upgrade fast-motion cache")

        // 4. Subsequent fast scroll reuses the higher-res cached page with zero downgrade rasterization.
        XCTAssertNotNil(renderSync(pageIndex: 0, scale: 1.0, fastMotion: true, offsetY: -120))
        let afterReuseHighRes = renderer.cacheStats()
        XCTAssertEqual(afterReuseHighRes.pageRasterizeCount, 2, "fast scroll should reuse existing crisp page")
        XCTAssertEqual(afterReuseHighRes.cacheHitCount, 2)

        // 5. Scroll through all 6 pages -> LRU strictly respects maxCachedPages & maxCacheBytes.
        for p in 1..<6 {
            XCTAssertNotNil(renderSync(pageIndex: p, scale: 1.0, fastMotion: true, offsetY: 0))
        }
        let afterSixPages = renderer.cacheStats()
        XCTAssertLessThanOrEqual(afterSixPages.cachedPageCount, PDFProjectionRenderer.maxCachedPages)
        XCTAssertLessThanOrEqual(afterSixPages.cachedByteCount, PDFProjectionRenderer.maxCacheBytes)

        // 6. Explicit cache clearing releases all memory cleanly.
        renderer.clearCache()
        let afterClear = renderer.cacheStats()
        XCTAssertEqual(afterClear.cachedPageCount, 0)
        XCTAssertEqual(afterClear.cachedByteCount, 0)
    }

    func testPDFProjectionRendererCompositesFloatingScratchpadAndDeepZoomVectorPath() throws {
        let url = try makeTestPDF(pageCount: 1, pageSize: CGSize(width: 400, height: 600)) { _, ctx, rect in
            // Solid red top half, white bottom half.
            UIColor(red: 0.90, green: 0.10, blue: 0.10, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height / 2))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: rect.height / 2, width: rect.width, height: rect.height / 2))
        }
        defer { try? FileManager.default.removeItem(at: url) }

        // Floating card image: cyan top half, magenta bottom half.
        let cardFormat = UIGraphicsImageRendererFormat()
        cardFormat.scale = 1
        cardFormat.opaque = true
        let cardImg = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120), format: cardFormat).image { c in
            UIColor(red: 0.05, green: 0.88, blue: 0.92, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
            UIColor(red: 0.92, green: 0.10, blue: 0.85, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: 60, width: 120, height: 60))
        }
        let cardCG = try XCTUnwrap(cardImg.cgImage)

        let renderer = PDFProjectionRenderer()
        // Deep-zoom settled frame: page rect width 3000 > maxCachedPageDimension * 1.15 -> direct vector path.
        let request = PDFProjectionFrameRequest(
            pdfURL: url,
            documentRevision: 1,
            displayBox: .cropBox,
            captureSize: CGSize(width: 400, height: 400),
            outputScale: 1.0,
            backgroundColor: CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1),
            pages: [
                PDFProjectionPageSlice(
                    pageIndex: 0,
                    frameInCapture: CGRect(x: -200, y: -100, width: 3000, height: 4500),
                    inkToCaptureTransform: .identity,
                    strokes: []
                ),
            ],
            floatingScratchpad: PDFProjectionFloatingCard(
                rect: CGRect(x: 220, y: 200, width: 120, height: 120),
                image: cardCG
            ),
            isFastMotion: false
        )

        let exp = expectation(description: "deep zoom + floating card")
        var rendered: UIImage?
        renderer.render(request) { img in
            rendered = img
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)

        let cg = try XCTUnwrap(rendered?.cgImage)
        // Deep-zoom page should bypass bitmap cache (0 pages cached) while rendering crisp red top half.
        XCTAssertEqual(renderer.cacheStats().cachedPageCount, 0)
        let pdfPixel = sampleRGBA(in: cg, x: 50, y: 50)
        XCTAssertGreaterThan(pdfPixel.r, 200, "deep-zoom direct vector path must render top red region right-side-up")
        XCTAssertLessThan(pdfPixel.g, 60)

        // Floating card top half should be cyan, bottom half magenta (right-side-up!).
        let cardTop = sampleRGBA(in: cg, x: 280, y: 225)
        XCTAssertGreaterThan(cardTop.g, 190)
        XCTAssertGreaterThan(cardTop.b, 190)
        XCTAssertLessThan(cardTop.r, 60)

        let cardBottom = sampleRGBA(in: cg, x: 280, y: 295)
        XCTAssertGreaterThan(cardBottom.r, 190)
        XCTAssertGreaterThan(cardBottom.b, 180)
        XCTAssertLessThan(cardBottom.g, 60)
    }

    // MARK: Test Helpers

    private func makeTestPDF(
        pageCount: Int,
        pageSize: CGSize,
        drawPage: (Int, CGContext, CGRect) -> Void
    ) throws -> URL {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = pdfRenderer.pdfData { ctx in
            for i in 0..<pageCount {
                ctx.beginPage()
                drawPage(i, ctx.cgContext, bounds)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-proj-test-\(UUID().uuidString).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func sampleRGBA(in image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return (0, 0, 0, 0)
        }
        // Shift so (x, y) from top-left lands on the 1x1 pixel.
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}
