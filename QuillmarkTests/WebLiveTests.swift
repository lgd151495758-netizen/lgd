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
        let ready = await waitUntil { self.bridge.isReady }
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
}
