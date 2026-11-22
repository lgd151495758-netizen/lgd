import CoreGraphics
import UIKit
import XCTest
@testable import Quillmark

final class TabsAndViewportTests: XCTestCase {
    private func makePDFData(pageCount: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { ctx in
            for i in 0..<pageCount {
                ctx.beginPage()
                let label = "Page \(i + 1)" as NSString
                label.draw(at: CGPoint(x: 36, y: 36), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
    }

    private func sampleStroke(y: Float = 80) -> InkStroke {
        let pts = [
            InkPoint(x: 20, y: y, force: 0.5, t: 0),
            InkPoint(x: 140, y: y, force: 0.5, t: 0.1),
        ]
        return InkStroke(id: UUID(), pen: .ballpoint, color: ToolSettings.palette[0], width: 2,
                         smoothing: 0, points: pts, tool: .pen)
    }

    func testViewportStateCodableBackwardCompatibilityAndClamping() throws {
        // Legacy annotations JSON without `viewport` decodes cleanly.
        let legacyJSON = #"{"version": 1, "pages": {}}"#
        let legacy = try LibraryStore.decoder.decode(DocumentAnnotations.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.viewport)

        // Valid viewport round-trips cleanly.
        let vp = ViewportState(offsetX: 120.5, offsetY: 1480.25, zoomScale: 1.35, pageIndex: 3)
        XCTAssertTrue(vp.isValid)
        var ann = DocumentAnnotations()
        ann.viewport = vp
        let encoded = try LibraryStore.encoder.encode(ann)
        let decoded = try LibraryStore.decoder.decode(DocumentAnnotations.self, from: encoded)
        XCTAssertEqual(decoded.viewport, vp)

        // Invalid NaN / zero zoom values are rejected.
        XCTAssertFalse(ViewportState(offsetX: .nan, offsetY: 0, zoomScale: 1, pageIndex: nil).isValid)
        XCTAssertFalse(ViewportState(offsetX: 0, offsetY: .infinity, zoomScale: 1, pageIndex: nil).isValid)
        XCTAssertFalse(ViewportState(offsetX: 0, offsetY: 0, zoomScale: 0, pageIndex: nil).isValid)

        // Approximate equality filters tiny jitter while detecting real scroll/page/zoom changes.
        XCTAssertTrue(vp.isApproximatelyEqual(to: ViewportState(offsetX: 121.0, offsetY: 1480.8, zoomScale: 1.354, pageIndex: 3)))
        XCTAssertFalse(vp.isApproximatelyEqual(to: ViewportState(offsetX: 120.5, offsetY: 1495.0, zoomScale: 1.35, pageIndex: 3)))
        XCTAssertFalse(vp.isApproximatelyEqual(to: ViewportState(offsetX: 120.5, offsetY: 1480.25, zoomScale: 1.35, pageIndex: 4)))

        // Clamping keeps offsets safely inside scrollable bounds.
        let clamped1 = ViewportState.clampedOffset(CGPoint(x: -50, y: 9999),
                                                   contentSize: CGSize(width: 820, height: 2400),
                                                   boundsSize: CGSize(width: 820, height: 1000))
        XCTAssertEqual(clamped1.x, 0, accuracy: 0.01)
        XCTAssertEqual(clamped1.y, 1400, accuracy: 0.01)

        let clampedSmall = ViewportState.clampedOffset(CGPoint(x: 200, y: 500),
                                                       contentSize: CGSize(width: 400, height: 600),
                                                       boundsSize: CGSize(width: 820, height: 1000))
        XCTAssertEqual(clampedSmall, .zero)
    }

    func testDocumentSessionViewportPersistenceAndReloadFromDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-sess-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = LibraryStore(root: root)
        let meta = try library.createDocument(title: "卷一", pdfData: makePDFData(pageCount: 4),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "a.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        session.addStroke(sampleStroke(), page: 0)
        let saved = ViewportState(offsetX: 0, offsetY: 1920, zoomScale: 1.25, pageIndex: 2)
        session.updateViewport(saved)
        session.saveNow()

        // Reopening loads the exact saved viewport.
        let reopened = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        XCTAssertEqual(reopened.savedViewport, saved)

        // Clearing ink in library + reloading from disk refreshes open session and clears undo stack.
        var reloadedCallbacks = 0
        reopened.allPagesDidChange = { reloadedCallbacks += 1 }
        reopened.addStroke(sampleStroke(y: 150), page: 0)
        XCTAssertTrue(reopened.canUndo)

        library.clearInk(for: meta.id, keepTapes: false)
        reopened.reloadAnnotationsFromDisk()
        XCTAssertTrue(reopened.strokes(onPage: 0).isEmpty)
        XCTAssertFalse(reopened.canUndo)
        XCTAssertEqual(reopened.savedViewport, saved, "clearing handwriting must preserve saved viewing position")
        XCTAssertEqual(reloadedCallbacks, 1)
    }

    @MainActor
    func testTabManagerOpenSwitchDeduplicateToolSyncAndCloseNeighbor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tabs-mgr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = LibraryStore(root: root)
        let docA = try library.createDocument(title: "试卷A", pdfData: makePDFData(pageCount: 3),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "a.pdf", stagedSource: nil)
        let docB = try library.createDocument(title: "解析B", pdfData: nil,
                                              layout: .live, sourceKind: .htmlFile, sourceURL: "b.html", stagedSource: nil)
        let docC = try library.createDocument(title: "笔记C", pdfData: makePDFData(pageCount: 2),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "c.pdf", stagedSource: nil)

        let manager = TabManager()
        var flushedIDs: [UUID] = []
        manager.onFlushTabState = { flushedIDs.append($0) }

        let tabA = manager.open(docA, library: library)
        let tabB = manager.open(docB, library: library)
        let tabC = manager.open(docC, library: library)
        XCTAssertEqual(manager.tabs.map(\.id), [docA.id, docB.id, docC.id])
        XCTAssertEqual(manager.activeTabID, docC.id)
        XCTAssertTrue(manager.isWorkspaceVisible)

        // Independent viewing positions & undo stacks per tab.
        tabA.session.updateViewport(ViewportState(offsetX: 0, offsetY: 640, zoomScale: 1.1, pageIndex: 1))
        tabB.session.updateViewport(ViewportState(offsetX: 0, offsetY: 1840, zoomScale: 1.0, pageIndex: nil))
        tabC.session.updateViewport(ViewportState(offsetX: 12, offsetY: 420, zoomScale: 1.4, pageIndex: 0))

        // Re-opening docA switches to existing tabA (no duplicate tab).
        let reopenedA = manager.open(docA, library: library)
        XCTAssertTrue(reopenedA === tabA)
        XCTAssertEqual(manager.tabs.count, 3)
        XCTAssertEqual(manager.activeTabID, docA.id)

        // Tool selection syncs across tab switch, while each tab keeps its own viewport.
        tabA.session.tool.color = ToolSettings.palette[2]
        tabA.session.tool.width = 4.0
        manager.selectTab(id: docB.id)
        XCTAssertEqual(manager.activeTabID, docB.id)
        XCTAssertEqual(tabB.session.tool.color, ToolSettings.palette[2])
        XCTAssertEqual(tabB.session.tool.width, 4.0)
        XCTAssertEqual(tabA.session.savedViewport?.offsetY, 640)
        XCTAssertEqual(tabB.session.savedViewport?.offsetY, 1840)

        // Return to Library keeps all 3 tabs warm in memory.
        manager.showLibrary()
        XCTAssertFalse(manager.isWorkspaceVisible)
        XCTAssertEqual(manager.tabs.count, 3)
        manager.showWorkspace()
        XCTAssertTrue(manager.isWorkspaceVisible)
        XCTAssertEqual(manager.activeTabID, docB.id)

        // Closing active middle tab B flushes & activates right neighbor C.
        manager.closeTab(id: docB.id)
        XCTAssertTrue(flushedIDs.contains(docB.id))
        XCTAssertEqual(manager.tabs.map(\.id), [docA.id, docC.id])
        XCTAssertEqual(manager.activeTabID, docC.id)

        // Closing remaining tabs hides workspace cleanly.
        manager.closeTab(id: docC.id)
        XCTAssertEqual(manager.activeTabID, docA.id)
        manager.closeTab(id: docA.id)
        XCTAssertTrue(manager.tabs.isEmpty)
        XCTAssertNil(manager.activeTabID)
        XCTAssertFalse(manager.isWorkspaceVisible)
    }

    @MainActor
    func testTabDeckViewControllerPreservesLiveInstancesAcrossTabSwitches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tabs-deck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = LibraryStore(root: root)
        let docA = try library.createDocument(title: "PDF-A", pdfData: makePDFData(pageCount: 2),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "a.pdf", stagedSource: nil)
        let docB = try library.createDocument(title: "PDF-B", pdfData: makePDFData(pageCount: 3),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "b.pdf", stagedSource: nil)

        let manager = TabManager()
        manager.open(docA, library: library)
        manager.open(docB, library: library)

        let deck = TabDeckViewController()
        deck.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        deck.sync(tabs: manager.tabs, activeTabID: manager.activeTabID, isWorkspaceVisible: true, library: library)

        let vcA = try XCTUnwrap(deck.controller(for: docA.id))
        let vcB = try XCTUnwrap(deck.controller(for: docB.id))
        XCTAssertTrue(vcA.isManagedByTabDeck)
        XCTAssertTrue(vcB.isManagedByTabDeck)
        XCTAssertTrue(vcA.view.isHidden)
        XCTAssertFalse(vcB.view.isHidden)

        // Switch back to A -> exact same live instances preserved (0ms reload-free switch).
        manager.selectTab(id: docA.id)
        deck.sync(tabs: manager.tabs, activeTabID: manager.activeTabID, isWorkspaceVisible: true, library: library)
        XCTAssertTrue(deck.controller(for: docA.id) === vcA)
        XCTAssertTrue(deck.controller(for: docB.id) === vcB)
        XCTAssertFalse(vcA.view.isHidden)
        XCTAssertTrue(vcB.view.isHidden)

        // Hide workspace (go to Library) and return -> both live VCs still preserved.
        manager.showLibrary()
        deck.sync(tabs: manager.tabs, activeTabID: manager.activeTabID, isWorkspaceVisible: false, library: library)
        manager.showWorkspace()
        deck.sync(tabs: manager.tabs, activeTabID: manager.activeTabID, isWorkspaceVisible: true, library: library)
        XCTAssertTrue(deck.controller(for: docA.id) === vcA)
        XCTAssertTrue(deck.controller(for: docB.id) === vcB)

        // Closing Tab B removes only vcB cleanly.
        manager.closeTab(id: docB.id)
        deck.sync(tabs: manager.tabs, activeTabID: manager.activeTabID, isWorkspaceVisible: true, library: library)
        XCTAssertNil(deck.controller(for: docB.id))
        XCTAssertTrue(deck.controller(for: docA.id) === vcA)

        deck.teardownAllTabs()
        XCTAssertNil(deck.controller(for: docA.id))
    }
}
