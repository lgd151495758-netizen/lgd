import CoreGraphics
import PDFKit
import UIKit
import XCTest
@testable import Quillmark

final class PDFAndClearInkTests: XCTestCase {
    private func makePDFData(pageCount: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { ctx in
            for i in 0..<pageCount {
                ctx.beginPage()
                let label = "Page \(i + 1)" as NSString
                label.draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
    }

    private func samplePenStroke(x0: Float = 20, x1: Float = 140, y: Float = 80) -> InkStroke {
        let pts = (0...10).map { i in
            InkPoint(x: x0 + (x1 - x0) * Float(i) / 10, y: y, force: 0.5, t: Float(i) / 240)
        }
        return InkStroke(id: UUID(), pen: .ballpoint, color: ToolSettings.palette[0], width: 2,
                         smoothing: 0, points: pts, tool: .pen)
    }

    private func sampleTapeStroke(revealed: Bool) -> InkStroke {
        let pts = [
            InkPoint(x: 50, y: 200, force: 0.5, t: 0),
            InkPoint(x: 220, y: 200, force: 0.5, t: 0.1),
        ]
        return InkStroke(id: UUID(), pen: .ballpoint, color: ToolSettings.tapePalette[0], width: 22,
                         smoothing: 0.7, points: pts, tool: .tape, revealed: revealed)
    }

    @MainActor
    func testPDFImportValidMultiPageAndCorruptRejection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let pdfFile = root.appendingPathComponent("九年级几何专题.pdf")
        try makePDFData(pageCount: 3).write(to: pdfFile)

        let meta = try await HTMLImportService.importDocument(from: .file(pdfFile), into: library)
        XCTAssertEqual(meta.layout, .pdf)
        XCTAssertEqual(meta.sourceKind, .pdfFile)
        XCTAssertEqual(meta.title, "九年级几何专题")
        XCTAssertEqual(library.documents.count, 1)

        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        XCTAssertEqual(session.pdfPageCount, 3)

        // Corrupt PDF file must throw ImportError.invalidPDF cleanly.
        let badPDF = root.appendingPathComponent("broken.pdf")
        try Data("not a valid pdf file".utf8).write(to: badPDF)
        do {
            _ = try await HTMLImportService.importDocument(from: .file(badPDF), into: library)
            XCTFail("Expected corrupt PDF import to throw")
        } catch let error as ImportError {
            XCTAssertEqual(error.errorDescription, ImportError.invalidPDF.errorDescription)
        }
    }

    func testClearSinglePageKeepTapesAndUndoRedo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clear-page-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = LibraryStore(root: root)
        let meta = try library.createDocument(title: "exam", pdfData: makePDFData(pageCount: 2),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "exam.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())

        let pen0 = samplePenStroke(y: 60)
        let shape0 = InkStroke(id: UUID(), pen: .ballpoint, color: ToolSettings.palette[1], width: 2,
                               smoothing: 0, points: [], tool: .pen,
                               geometry: .circle(center: CGPoint(x: 100, y: 120), radius: 40))
        let tape0 = sampleTapeStroke(revealed: true)
        let pen1 = samplePenStroke(y: 120)

        session.addStroke(pen0, page: 0)
        session.addStroke(shape0, page: 0)
        session.addStroke(tape0, page: 0)
        session.addStroke(pen1, page: 1)

        // Clear page 0 keeping cover tapes (and resetting tape to covered).
        session.clearHandwriting(onPage: 0, keepTapes: true)
        let afterKeep = session.strokes(onPage: 0)
        XCTAssertEqual(afterKeep.count, 1)
        XCTAssertEqual(afterKeep.first?.id, tape0.id)
        XCTAssertEqual(afterKeep.first?.isRevealed, false, "kept tapes must reset to covered for next class")
        XCTAssertEqual(session.strokes(onPage: 1), [pen1], "other PDF pages must stay untouched")

        // 1-step Undo restores pen, shape, and revealed tape state on page 0.
        session.undo()
        XCTAssertEqual(session.strokes(onPage: 0).count, 3)
        XCTAssertEqual(session.strokes(onPage: 0).last?.isRevealed, true)

        // Redo re-applies single-page clear.
        session.redo()
        XCTAssertEqual(session.strokes(onPage: 0).count, 1)
        XCTAssertEqual(session.strokes(onPage: 0).first?.isRevealed, false)

        // Clear page 0 including tapes -> empty, undoable in 1 step.
        session.clearHandwriting(onPage: 0, keepTapes: false)
        XCTAssertTrue(session.strokes(onPage: 0).isEmpty)
        session.undo()
        XCTAssertEqual(session.strokes(onPage: 0).count, 1)
    }

    func testClearAllDocumentHandwritingMultiPagePreservesStickyNotesAndOneStepUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clear-all-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = LibraryStore(root: root)
        let meta = try library.createDocument(title: "multi", pdfData: makePDFData(pageCount: 3),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "multi.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())

        var allPagesChangedCount = 0
        session.allPagesDidChange = { allPagesChangedCount += 1 }

        let pen0 = samplePenStroke(y: 50)
        let tape0 = sampleTapeStroke(revealed: true)
        let pen1 = samplePenStroke(y: 90)
        let pen2 = samplePenStroke(y: 130)
        let tape2 = sampleTapeStroke(revealed: true)
        let sticky = samplePenStroke(y: 170)

        session.addStroke(pen0, page: 0)
        session.addStroke(tape0, page: 0)
        session.addStroke(pen1, page: 1)
        session.addStroke(pen2, page: 2)
        session.addStroke(tape2, page: 2)
        session.addStroke(sticky, page: session.currentScratchpadPageID)

        // Clear all PDF pages keeping tapes -> resets tapes, removes pen strokes, preserves sticky note.
        session.clearAllDocumentHandwriting(keepTapes: true)
        XCTAssertEqual(allPagesChangedCount, 1)
        XCTAssertEqual(session.strokes(onPage: 0).map(\.id), [tape0.id])
        XCTAssertEqual(session.strokes(onPage: 0).first?.isRevealed, false)
        XCTAssertTrue(session.strokes(onPage: 1).isEmpty)
        XCTAssertEqual(session.strokes(onPage: 2).map(\.id), [tape2.id])
        XCTAssertEqual(session.strokes(onPage: 2).first?.isRevealed, false)
        XCTAssertEqual(session.strokes(onPage: -1), [sticky], "sticky-note pages must never be wiped by document clear")

        // 1-step Undo restores every PDF page at once!
        session.undo()
        XCTAssertEqual(allPagesChangedCount, 2)
        XCTAssertEqual(session.strokes(onPage: 0), [pen0, tape0])
        XCTAssertEqual(session.strokes(onPage: 1), [pen1])
        XCTAssertEqual(session.strokes(onPage: 2), [pen2, tape2])
        XCTAssertEqual(session.strokes(onPage: -1), [sticky])

        // 1-step Redo clears all 3 pages again.
        session.redo()
        XCTAssertEqual(allPagesChangedCount, 3)
        XCTAssertEqual(session.strokes(onPage: 0).count, 1)
        XCTAssertTrue(session.strokes(onPage: 1).isEmpty)
        XCTAssertEqual(session.strokes(onPage: 2).count, 1)

        // Clear ALL including tapes -> all main pages empty, sticky note intact, 1-step Undo restores.
        session.clearAllDocumentHandwriting(keepTapes: false)
        XCTAssertTrue(session.strokes(onPage: 0).isEmpty)
        XCTAssertTrue(session.strokes(onPage: 1).isEmpty)
        XCTAssertTrue(session.strokes(onPage: 2).isEmpty)
        XCTAssertEqual(session.strokes(onPage: -1), [sticky])

        session.undo()
        XCTAssertEqual(session.strokes(onPage: 0).map(\.id), [tape0.id])
        XCTAssertEqual(session.strokes(onPage: 2).map(\.id), [tape2.id])
    }

    func testLibraryStoreClearInkAndDuplicate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lib-clear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = LibraryStore(root: root)
        let meta = try library.createDocument(title: "一轮复习卷", pdfData: makePDFData(pageCount: 2),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "review.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        let pen = samplePenStroke()
        let tape = sampleTapeStroke(revealed: true)
        let sticky = samplePenStroke(y: 220)
        session.addStroke(pen, page: 0)
        session.addStroke(tape, page: 0)
        session.addStroke(sticky, page: -1)
        session.saveNow()
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: library.thumbnailURL(for: meta.id))

        // Duplicate document for a second class.
        let copy = try library.duplicate(meta.id)
        XCTAssertNotEqual(copy.id, meta.id)
        XCTAssertEqual(copy.title, "一轮复习卷 副本")
        XCTAssertEqual(copy.layout, .pdf)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.pdfURL(for: copy.id).path))
        XCTAssertEqual(library.loadAnnotations(for: copy.id).page(0).strokes.count, 2)

        // Clear ink keeping tapes on original -> removes pen & stale thumbnail, resets tape, keeps sticky note & copy intact.
        library.clearInk(for: meta.id, keepTapes: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.thumbnailURL(for: meta.id).path))
        let clearedOriginal = library.loadAnnotations(for: meta.id)
        XCTAssertEqual(clearedOriginal.page(0).strokes.map(\.id), [tape.id])
        XCTAssertEqual(clearedOriginal.page(0).strokes.first?.isRevealed, false)
        XCTAssertEqual(clearedOriginal.page(-1).strokes, [sticky])
        XCTAssertEqual(library.loadAnnotations(for: copy.id).page(0).strokes.count, 2)

        // Clear all annotations on copy -> main pages completely wiped.
        library.clearInk(for: copy.id, keepTapes: false)
        XCTAssertTrue(library.loadAnnotations(for: copy.id).page(0).strokes.isEmpty)
    }

    @MainActor
    func testPDFEditorControllerOverlayAndPresentationCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-vc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = LibraryStore(root: root)
        let meta = try library.createDocument(title: "vc-test", pdfData: makePDFData(pageCount: 2),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "vc.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        let pen = samplePenStroke()
        session.addStroke(pen, page: 0)

        let vc = EditorViewController(session: session)
        vc.view.frame = CGRect(x: 0, y: 0, width: 820, height: 1080)
        vc.view.layoutIfNeeded()

        XCTAssertEqual(vc.pdfView.document?.pageCount, 2)
        let page0 = try XCTUnwrap(vc.pdfView.document?.page(at: 0))
        let overlay = try XCTUnwrap(vc.pdfView(vc.pdfView, overlayViewFor: page0) as? PageInkView)
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        overlay.frame = CGRect(x: 0, y: 0, width: 595, height: 842)
        overlay.layoutIfNeeded()
        overlay.hiddenStrokeIDs = [pen.id]
        overlay.hiddenStrokeIDs = []

        let exp = expectation(description: "capture PDF presentation frame")
        vc.capturePresentationFrame { image, size in
            XCTAssertNotNil(image)
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)
    }
}
