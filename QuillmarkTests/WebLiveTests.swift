import UIKit
import WebKit
import XCTest
@testable import Quillmark

/// Runs the real in-page runtime inside WebKit (simulator host app).
@MainActor
final class WebLiveTests: XCTestCase {
    private var bridge: WebInkBridge!

    private static let html = """
    <!doctype html><html><head><meta charset="utf-8"><title>Live</title>
    <style>body{margin:0;font:16px -apple-system;} .box{height:120px;background:#eee;} p{margin:0;padding:4px 0;}</style>
    </head><body>
    <div id="top" class="box">Top block</div>
    <p id="note">Anchor paragraph text for testing</p>
    <section><p>First plain paragraph</p><p>Second plain paragraph is the target</p></section>
    <button id="btn" onclick="document.getElementById('top').style.height='300px'">Grow</button>
    </body></html>
    """

    override func setUp() async throws {
        bridge = WebInkBridge(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
        window?.addSubview(bridge.webView)
        try await load(Self.html)
    }

    override func tearDown() async throws {
        bridge.webView.removeFromSuperview()
        bridge = nil
    }

    private func load(_ html: String) async throws {
        bridge.resetForNavigation()
        bridge.webView.loadHTMLString(html, baseURL: nil)
        let ready = await waitUntil(timeout: 30) { self.bridge.isReady }
        XCTAssertTrue(ready, "runtime did not start")
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func run(_ script: String) async throws {
        _ = try await bridge.webView.callAsyncJavaScript(script + "; return true;", arguments: [:], in: nil, contentWorld: .page)
    }

    private func stroke(at point: CGPoint, anchoredTo pick: WebInkBridge.AnchorPick) -> InkStroke {
        let points = (0..<20).map { i in
            InkPoint(x: Float(point.x) + Float(i) * 2, y: Float(point.y), force: 0.5, t: Float(i) / 240)
        }
        var stroke = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0, points: points, tool: .pen)
        stroke = stroke.translated(by: CGPoint(x: -pick.origin.x, y: -pick.origin.y))
        stroke.anchor = pick.anchor
        return stroke
    }

    func testRuntimeIsInjected() {
        XCTAssertFalse(WebInkBridge.runtimeSource.isEmpty)
        XCTAssertTrue(bridge.isReady)
    }

    func testInkFollowsItsElementAndHidesWithIt() async throws {
        let picked = await bridge.pickAnchor(at: CGPoint(x: 40, y: 130))
        let pick = try XCTUnwrap(picked)
        XCTAssertEqual(pick.anchor.selector, "#note")
        XCTAssertEqual(pick.anchor.fingerprint, "Anchor paragraph text for testing")
        XCTAssertEqual(pick.origin.y, 120, accuracy: 1)

        let ink = stroke(at: CGPoint(x: 40, y: 130), anchoredTo: pick)
        bridge.sync([ink])
        let placed = await waitUntil { self.bridge.placements[ink.id]?.visible == true }
        XCTAssertTrue(placed)
        XCTAssertEqual(bridge.placements[ink.id]?.origin.y ?? 0, 120, accuracy: 1)

        // Content above grows (like expanding a section): the ink moves down with its paragraph.
        try await run("document.getElementById('top').style.height = '320px'")
        let moved = await waitUntil { abs((self.bridge.placements[ink.id]?.origin.y ?? 0) - 320) < 1 }
        XCTAssertTrue(moved, "ink did not follow its element, y=\(bridge.placements[ink.id]?.origin.y ?? -1)")

        // The paragraph is hidden (collapsed): its ink is hidden too.
        try await run("document.getElementById('note').style.display = 'none'")
        let hidden = await waitUntil { self.bridge.placements[ink.id]?.visible == false }
        XCTAssertTrue(hidden)

        try await run("document.getElementById('note').style.display = ''")
        let shownAgain = await waitUntil { self.bridge.placements[ink.id]?.visible == true }
        XCTAssertTrue(shownAgain)
    }

    func testInkIsFoundAgainAfterReloadEvenIfThePageChanged() async throws {
        let picked = await bridge.pickAnchor(at: CGPoint(x: 40, y: 188))
        let pick = try XCTUnwrap(picked)
        XCTAssertEqual(pick.anchor.fingerprint, "Second plain paragraph is the target")
        XCTAssertTrue(pick.anchor.selector.hasSuffix("p:nth-of-type(2)"), pick.anchor.selector)
        let ink = stroke(at: CGPoint(x: 40, y: 188), anchoredTo: pick)
        bridge.sync([ink])
        _ = await waitUntil { self.bridge.placements[ink.id] != nil }
        let originalY = try XCTUnwrap(bridge.placements[ink.id]?.origin.y)

        // Same page with an extra paragraph inserted before the target: the CSS path now points at
        // another element, so the text fingerprint must be used.
        let changed = Self.html.replacingOccurrences(of: "<section>",
                                                     with: "<section><p style=\"height:200px;padding:0\">Inserted later</p>")
        try await load(changed)
        bridge.sync([ink])
        let found = await waitUntil { self.bridge.placements[ink.id]?.visible == true }
        XCTAssertTrue(found)
        XCTAssertEqual(bridge.placements[ink.id]?.origin.y ?? 0, originalY + 200, accuracy: 2)
    }

    func testRemovingStrokesClearsThePage() async throws {
        let picked = await bridge.pickAnchor(at: CGPoint(x: 40, y: 130))
        let pick = try XCTUnwrap(picked)
        let a = stroke(at: CGPoint(x: 40, y: 130), anchoredTo: pick)
        let b = stroke(at: CGPoint(x: 40, y: 140), anchoredTo: pick)
        bridge.sync([a, b])
        _ = await waitUntil { self.bridge.placements.count == 2 }
        var count = try await bridge.webView.callAsyncJavaScript("return window.__qm.count();", arguments: [:],
                                                                  in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(count, 2)
        bridge.sync([b])
        try await Task.sleep(nanoseconds: 300_000_000)
        count = try await bridge.webView.callAsyncJavaScript("return window.__qm.count();", arguments: [:],
                                                              in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(count, 1)
    }

    func testPageButtonsStillWork() async throws {
        try await run("document.getElementById('btn').click()")
        let height = try await bridge.webView.callAsyncJavaScript("return document.getElementById('top').offsetHeight;",
                                                                   arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(height, 300, "the ink layer must not break page scripts")
    }

    func testViewportFollowsDeviceWidth() async throws {
        let width = try await bridge.webView.callAsyncJavaScript("return document.documentElement.clientWidth;",
                                                                  arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(width, 800)
    }

    func testCoverTapeClickTogglesAndAnchorPickPassesThrough() async throws {
        let picked = await bridge.pickAnchor(at: CGPoint(x: 40, y: 130))
        let pick = try XCTUnwrap(picked)
        XCTAssertEqual(pick.anchor.selector, "#note")

        let points = (0..<20).map { i in
            InkPoint(x: Float(20 + i * 4), y: 130, force: 0.5, t: Float(i) / 240)
        }
        var tape = InkStroke(id: UUID(), pen: .ballpoint, color: ToolSettings.tapePalette[0],
                             width: 26, smoothing: 0.5, points: points, tool: .tape,
                             lineStyle: .solid, revealed: false)
        tape = tape.translated(by: CGPoint(x: -pick.origin.x, y: -pick.origin.y))
        tape.anchor = pick.anchor

        var toggledID: UUID?
        bridge.onToggleTape = { toggledID = $0 }
        bridge.sync([tape])
        let placed = await waitUntil { self.bridge.placements[tape.id]?.visible == true }
        XCTAssertTrue(placed)

        // Clicking the tape SVG path must post toggleTape back to Swift.
        try await run("""
        var p = document.querySelector('#__qm_layer path');
        if (p) { p.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true })); }
        """)
        let toggled = await waitUntil { toggledID == tape.id }
        XCTAssertTrue(toggled, "clicking a cover tape must notify WebInkBridge.onToggleTape")

        // Picking an anchor on top of an existing interactive cover tape must still find #note underneath.
        let pickedThrough = await bridge.pickAnchor(at: CGPoint(x: 40, y: 130))
        XCTAssertEqual(pickedThrough?.anchor.selector, "#note")
    }

    func testShadedGeometricShapeRendersFillAndOutlinePaths() async throws {
        let picked = await bridge.pickAnchor(at: CGPoint(x: 40, y: 130))
        let pick = try XCTUnwrap(picked)

        let built = ShapeBuilder.build(preset: .rightTriangle, from: CGPoint(x: 20, y: 120), to: CGPoint(x: 120, y: 200))
        var shapeStroke = InkStroke(id: UUID(), pen: .ballpoint, color: ToolSettings.palette[1],
                                    width: 2, smoothing: 0, points: [], tool: .pen,
                                    lineStyle: .dashed, geometry: built.primitive, fillColor: ToolSettings.palette[1])
        shapeStroke = shapeStroke.translated(by: CGPoint(x: -pick.origin.x, y: -pick.origin.y))
        shapeStroke.anchor = pick.anchor

        bridge.sync([shapeStroke])
        let placed = await waitUntil { self.bridge.placements[shapeStroke.id]?.visible == true }
        XCTAssertTrue(placed)

        let pathCount = try await bridge.webView.callAsyncJavaScript(
            "return document.querySelectorAll('#__qm_layer svg path').length;",
            arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(pathCount, 2, "shaded geometric stroke must render both fill and outline SVG paths")
    }

    func testImageTapGuardBlocksSingleTapAllowsDoubleTapAndNeverBlocksButtons() async throws {
        let pageHTML = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin: 0; }
        .zoom-img { width: 200px; height: 140px; cursor: zoom-in; display: block; }
        .fig-box { width: 220px; height: 160px; cursor: pointer; display: block; }
        #lightbox { display: none; position: fixed; left: 0; top: 0; width: 100vw; height: 100vh; background: rgba(0,0,0,0.8); }
        #lightbox.open { display: block; }
        </style></head><body>
        <button id="iconBtn" onclick="window.__btnClicks = (window.__btnClicks || 0) + 1">
          <svg width="24" height="24" viewBox="0 0 24 24"><circle id="btnIcon" cx="12" cy="12" r="10"/></svg>
          切换原图
        </button>
        <div id="stepCard" class="step-card" onclick="window.__stepClicks = (window.__stepClicks || 0) + 1">步骤 1</div>
        <img id="zoomImg" class="zoom-img"
             src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
             onclick="window.__imgZooms = (window.__imgZooms || 0) + 1; document.getElementById('lightbox').classList.add('open')">
        <div class="fig-box" onclick="window.__svgZooms = (window.__svgZooms || 0) + 1">
          <svg id="diagramSvg" width="200" height="140" viewBox="0 0 200 140">
            <rect id="diagramRect" x="10" y="10" width="180" height="120" fill="#eee"/>
          </svg>
        </div>
        <div id="lightbox" onclick="window.__lbCloses = (window.__lbCloses || 0) + 1; this.classList.remove('open')">
          <img id="lbImg" class="zoom-img"
               src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7">
        </div>
        </body></html>
        """
        try await load(pageHTML)

        var guardHintCount = 0
        bridge.onImageTapGuarded = { guardHintCount += 1 }

        // 1. Normal buttons (including clicking an <svg> icon inside a <button>) & step cards stay single-tap!
        try await run("""
        document.getElementById('btnIcon').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: 20, clientY: 20 }));
        document.getElementById('stepCard').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: 20, clientY: 60 }));
        """)
        let btnClicks = try await bridge.webView.callAsyncJavaScript("return window.__btnClicks || 0;", arguments: [:], in: nil, contentWorld: .page) as? Int
        let stepClicks = try await bridge.webView.callAsyncJavaScript("return window.__stepClicks || 0;", arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(btnClicks, 1, "button with nested SVG icon must still fire on single tap")
        XCTAssertEqual(stepClicks, 1, "text step-card button must still fire on single tap")

        // 2. Single tap on zoomable <img> is intercepted (no accidental lightbox pop) and fires iPad hint.
        try await run("""
        document.getElementById('zoomImg').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: 100, clientY: 120 }));
        """)
        let imgZoomAfterSingle = try await bridge.webView.callAsyncJavaScript("return window.__imgZooms || 0;", arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(imgZoomAfterSingle, 0, "single tap on zoomable image must be blocked to prevent accidental zoom")
        let hintReceived = await waitUntil { guardHintCount >= 1 }
        XCTAssertTrue(hintReceived, "single tap on zoomable image should notify host for subtle iPad-only toast")

        // 3. Rapid double-tap (reset guard timer first for CI determinism) opens the lightbox natively.
        try await run("""
        window.__qm.setImageTapGuard(true);
        var img = document.getElementById('zoomImg');
        img.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: 100, clientY: 120 }));
        window.__imgZoomBetweenTaps = window.__imgZooms || 0;
        img.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: 104, clientY: 122 }));
        """)
        let imgZoomBetween = try await bridge.webView.callAsyncJavaScript("return window.__imgZoomBetweenTaps || 0;", arguments: [:], in: nil, contentWorld: .page) as? Int
        let imgZoomAfterDouble = try await bridge.webView.callAsyncJavaScript("return window.__imgZooms || 0;", arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(imgZoomBetween, 0, "first tap of double-tap must remain blocked")
        XCTAssertEqual(imgZoomAfterDouble, 1, "second tap of double-tap on zoomable image must open lightbox")

        // 4. Single tap on the enlarged <img> inside the open fullscreen lightbox closes it immediately!
        try await run("""
        document.getElementById('lbImg').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: 100, clientY: 100 }));
        """)
        let lbCloses = try await bridge.webView.callAsyncJavaScript("return window.__lbCloses || 0;", arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(lbCloses, 1, "single tap inside an open lightbox must dismiss it immediately")

        // 5. Large diagram <svg> inside clickable .fig-box: single tap blocked, rapid double-tap opens!
        try await run("""
        window.__qm.setImageTapGuard(true);
        var rect = document.getElementById('diagramRect');
        rect.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: 110, clientY: 300 }));
        window.__svgZoomAfterFirst = window.__svgZooms || 0;
        rect.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, clientX: 114, clientY: 302 }));
        """)
        let svgZoomAfterFirst = try await bridge.webView.callAsyncJavaScript("return window.__svgZoomAfterFirst || 0;", arguments: [:], in: nil, contentWorld: .page) as? Int
        let svgZoomAfterDouble = try await bridge.webView.callAsyncJavaScript("return window.__svgZooms || 0;", arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(svgZoomAfterFirst, 0, "single tap on zoomable diagram SVG must be blocked")
        XCTAssertEqual(svgZoomAfterDouble, 1, "double tap on zoomable diagram SVG must open lightbox")
    }
}
