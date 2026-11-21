import CoreGraphics
import UIKit
import XCTest
@testable import Quillmark

final class ScratchpadAndFreezeTests: XCTestCase {
    private func sampleStroke(x0: Float, x1: Float, y: Float) -> InkStroke {
        let pts = (0...10).map { i in
            InkPoint(x: x0 + (x1 - x0) * Float(i) / 10, y: y, force: 0.5, t: Float(i) / 240)
        }
        return InkStroke(id: UUID(), pen: .ballpoint, color: ToolSettings.palette[1], width: 2,
                         smoothing: 0, points: pts, tool: .pen)
    }

    func testScratchpadAnnotationsPersistenceAndBackwardCompatibility() throws {
        // 1. Legacy v1.0 JSON without scratchpad fields decodes cleanly with 1 empty page.
        let legacyJSON = """
        {"version": 1, "pages": {}}
        """
        let legacy = try JSONDecoder().decode(DocumentAnnotations.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.resolvedScratchpadPageCount, 1)
        XCTAssertNil(legacy.scratchpadPaper)
        XCTAssertTrue(legacy.page(DocumentAnnotations.scratchpadPageID(0)).strokes.isEmpty)

        // 2. Negative page IDs write into `scratchpadPages` without polluting `pages`.
        var ann = DocumentAnnotations()
        let s0 = sampleStroke(x0: 10, x1: 110, y: 40)
        let s1 = sampleStroke(x0: 20, x1: 120, y: 80)
        ann.updatePage(DocumentAnnotations.scratchpadPageID(0)) { $0.strokes.append(s0) }
        let idx1 = ann.appendScratchpadPage()
        XCTAssertEqual(idx1, 1)
        ann.updatePage(DocumentAnnotations.scratchpadPageID(1)) { $0.strokes.append(s1) }
        ann.scratchpadPaper = .graph
        ann.scratchpadFrame = CGRect(x: 320, y: 180, width: 440, height: 320)

        XCTAssertTrue(ann.pages.isEmpty, "scratchpad strokes must live in scratchpadPages, not main pages")
        XCTAssertEqual(ann.resolvedScratchpadPageCount, 2)
        XCTAssertEqual(ann.page(DocumentAnnotations.scratchpadPageID(0)).strokes, [s0])
        XCTAssertEqual(ann.page(DocumentAnnotations.scratchpadPageID(1)).strokes, [s1])
        XCTAssertEqual(ann.scratchpadFrame, CGRect(x: 320, y: 180, width: 440, height: 320))

        let encoded = try LibraryStore.encoder.encode(ann)
        let decoded = try LibraryStore.decoder.decode(DocumentAnnotations.self, from: encoded)
        XCTAssertEqual(decoded, ann)
    }

    func testStickyNoteLayoutDefaultMoveResizeAndRotationClamping() {
        let landscape = CGRect(x: 0, y: 0, width: 1180, height: 740)
        let initial = StickyNoteLayout.defaultFrame(in: landscape)
        XCTAssertGreaterThanOrEqual(initial.width, StickyNoteLayout.minSize.width)
        XCTAssertGreaterThanOrEqual(initial.height, StickyNoteLayout.minSize.height)
        XCTAssertTrue(landscape.contains(initial))

        // Dragging past top-left clamps neatly inside edgeMargin.
        let movedTopLeft = StickyNoteLayout.clamped(initial.offsetBy(dx: -2000, dy: -2000), in: landscape)
        XCTAssertEqual(movedTopLeft.minX, StickyNoteLayout.edgeMargin, accuracy: 0.5)
        XCTAssertEqual(movedTopLeft.minY, StickyNoteLayout.edgeMargin, accuracy: 0.5)

        // Bottom-right resize expands & respects minimum size while pinning top-left.
        let start = CGRect(x: 200, y: 120, width: 400, height: 300)
        let grown = StickyNoteLayout.resizingBottomRight(from: start, delta: CGPoint(x: 80, y: 60), in: landscape)
        XCTAssertEqual(grown.minX, 200, accuracy: 0.5)
        XCTAssertEqual(grown.minY, 120, accuracy: 0.5)
        XCTAssertEqual(grown.width, 480, accuracy: 0.5)
        XCTAssertEqual(grown.height, 360, accuracy: 0.5)

        let shrunk = StickyNoteLayout.resizingBottomRight(from: start, delta: CGPoint(x: -500, y: -500), in: landscape)
        XCTAssertEqual(shrunk.width, StickyNoteLayout.minSize.width, accuracy: 0.5)
        XCTAssertEqual(shrunk.height, StickyNoteLayout.minSize.height, accuracy: 0.5)

        // Bottom-left resize keeps right edge pinned while resizing width leftward.
        let leftResized = StickyNoteLayout.resizingBottomLeft(from: start, delta: CGPoint(x: -50, y: 40), in: landscape)
        XCTAssertEqual(leftResized.maxX, start.maxX, accuracy: 0.5)
        XCTAssertEqual(leftResized.minX, 150, accuracy: 0.5)
        XCTAssertEqual(leftResized.width, 450, accuracy: 0.5)
        XCTAssertEqual(leftResized.height, 340, accuracy: 0.5)

        // Rotating from landscape to narrower portrait keeps the sticky note reachable on screen.
        let portrait = CGRect(x: 0, y: 0, width: 820, height: 1080)
        let farRight = CGRect(x: 700, y: 200, width: 420, height: 320)
        let rotated = StickyNoteLayout.clamped(farRight, in: portrait)
        XCTAssertLessThanOrEqual(rotated.maxX, portrait.width - StickyNoteLayout.edgeMargin + 0.5)
        XCTAssertGreaterThanOrEqual(rotated.minX, StickyNoteLayout.edgeMargin - 0.5)
    }

    func testDocumentSessionScratchpadMultiPageClearAndUndoRedo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let meta = try library.createDocument(title: "scratch", pdfData: Data(), layout: .live,
                                              sourceKind: .htmlFile, sourceURL: nil, stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())

        var changedPages: [Int] = []
        session.pageDidChange = { changedPages.append($0) }

        XCTAssertFalse(session.isScratchpadOpen)
        XCTAssertEqual(session.scratchpadPageIndex, 0)
        XCTAssertEqual(session.scratchpadPageCount, 1)
        XCTAssertEqual(session.currentScratchpadPageID, -1)

        // Add stroke on main page 0 and scratchpad page 0.
        let mainStroke = sampleStroke(x0: 0, x1: 50, y: 10)
        let scratchStroke0 = sampleStroke(x0: 10, x1: 90, y: 50)
        session.addStroke(mainStroke, page: 0)
        session.addStroke(scratchStroke0, page: session.currentScratchpadPageID)
        XCTAssertEqual(session.strokes(onPage: 0), [mainStroke])
        XCTAssertEqual(session.strokes(onPage: -1), [scratchStroke0])

        // Clear scratchpad page 0 -> single undoable step that leaves main page 0 untouched!
        session.clearCurrentScratchpadPage()
        XCTAssertTrue(session.strokes(onPage: -1).isEmpty)
        XCTAssertEqual(session.strokes(onPage: 0), [mainStroke])

        session.undo()
        XCTAssertEqual(session.strokes(onPage: -1), [scratchStroke0], "undo must restore cleared scratchpad page")

        // Add second scratchpad page & save/reload from disk.
        session.addScratchpadPage()
        XCTAssertEqual(session.scratchpadPageCount, 2)
        XCTAssertEqual(session.scratchpadPageIndex, 1)
        XCTAssertEqual(session.currentScratchpadPageID, -2)

        let scratchStroke1 = sampleStroke(x0: 30, x1: 140, y: 100)
        session.addStroke(scratchStroke1, page: session.currentScratchpadPageID)
        session.scratchpadPaper = .dot
        session.saveNow()

        let reloaded = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        XCTAssertEqual(reloaded.scratchpadPageCount, 2)
        XCTAssertEqual(reloaded.scratchpadPaper, .dot)
        XCTAssertEqual(reloaded.strokes(onPage: -1), [scratchStroke0])
        XCTAssertEqual(reloaded.strokes(onPage: -2), [scratchStroke1])
        XCTAssertTrue(changedPages.contains(-1))
        XCTAssertTrue(changedPages.contains(-2))
    }

    @MainActor
    func testScratchpadCleanRenderAcrossAllPaperStylesAndLiveOverlayTranslation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("render-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let meta = try library.createDocument(title: "render", pdfData: Data(), layout: .live,
                                              sourceKind: .htmlFile, sourceURL: nil, stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())

        let tri = InkStroke(id: UUID(), pen: .ballpoint, color: ToolSettings.palette[2], width: 2,
                            smoothing: 0, points: [], tool: .pen,
                            geometry: .polygon(vertices: [
                                CGPoint(x: 40, y: 40), CGPoint(x: 160, y: 40), CGPoint(x: 100, y: 140),
                            ], closed: true),
                            fillColor: ToolSettings.palette[2])
        session.addStroke(tri, page: session.currentScratchpadPageID)

        let canvas = ScratchpadCanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        for style in ScratchpadPaperStyle.allCases {
            canvas.paperStyle = style
            let image = canvas.renderCleanImage(size: CGSize(width: 400, height: 300))
            XCTAssertGreaterThan(image.size.width, 399)
            XCTAssertGreaterThan(image.size.height, 299)
            XCTAssertNotNil(image.cgImage)
        }

        // Verify live overlay translation shifts paths cleanly for Split-Mode projection alignment.
        let rectPath = CGPath(rect: CGRect(x: 10, y: 20, width: 50, height: 30), transform: nil)
        let overlay = ScratchpadLiveOverlay(strokePath: rectPath, strokeColor: UIColor.red.cgColor, strokeOpacity: 1)
        XCTAssertFalse(overlay.isEmpty)
        let shifted = overlay.translated(by: CGPoint(x: 0, y: 320))
        XCTAssertEqual(shifted.strokePath?.boundingBox.minY ?? 0, 340, accuracy: 0.01)
    }

    func testPresentationFreezeStateAndDetachReset() {
        let suiteName = "quillmark.freeze.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let center = PresentationCenter(defaults: defaults)
        XCTAssertFalse(center.isFrozen)
        center.isFrozen = true
        XCTAssertTrue(center.isFrozen)

        // Detaching external display resets freeze so reconnecting starts live cleanly.
        center.detach()
        XCTAssertFalse(center.isFrozen)
    }
}
