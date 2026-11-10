import PDFKit
import UIKit
import XCTest
@testable import Quillmark

final class DocumentTests: XCTestCase {
    private var root: URL!
    private var library: LibraryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        library = LibraryStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func samplePDF(pages: Int = 2) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.28, height: 841.89))
        return renderer.pdfData { context in
            for _ in 0..<pages { context.beginPage() }
        }
    }

    private func sampleStroke(_ x: Float = 10) -> InkStroke {
        InkStroke(id: UUID(), pen: .fountain, color: .ink, width: 2, smoothing: 0.4,
                  points: [InkPoint(x: x, y: 10, force: 0.4, t: 0), InkPoint(x: x + 20, y: 30, force: 0.6, t: 0.05)])
    }

    func testAnnotationsRoundTrip() throws {
        var annotations = DocumentAnnotations()
        annotations.updatePage(3) { $0.strokes.append(sampleStroke()) }
        let data = try LibraryStore.encoder.encode(annotations)
        let decoded = try LibraryStore.decoder.decode(DocumentAnnotations.self, from: data)
        XCTAssertEqual(decoded, annotations)
        XCTAssertEqual(decoded.page(3).strokes.count, 1)
        XCTAssertTrue(decoded.page(0).strokes.isEmpty)
    }

    func testCreateReloadAndDelete() throws {
        let meta = try library.createDocument(title: "测试", pdfData: samplePDF(), layout: .pagedA4,
                                              sourceKind: .htmlFile, sourceURL: "a.html", stagedSource: nil)
        XCTAssertEqual(library.documents.map(\.id), [meta.id])
        XCTAssertEqual(PDFDocument(url: library.pdfURL(for: meta.id))?.pageCount, 2)

        let reopened = LibraryStore(root: root)
        XCTAssertEqual(reopened.documents.first?.title, "测试")
        XCTAssertEqual(reopened.documents.first?.layout, .pagedA4)

        library.delete(meta.id)
        XCTAssertTrue(library.documents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.folder(for: meta.id).path))
    }

    func testStagedSourceIsKept() throws {
        let staged = root.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try "<p>hi</p>".write(to: staged.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let meta = try library.createDocument(title: "s", pdfData: samplePDF(), layout: .longPage,
                                              sourceKind: .htmlFile, sourceURL: nil, stagedSource: staged)
        let copied = library.folder(for: meta.id).appendingPathComponent("source/index.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
    }

    func testSessionUndoRedoAndSave() throws {
        let meta = try library.createDocument(title: "s", pdfData: samplePDF(), layout: .pagedA4,
                                              sourceKind: .htmlFile, sourceURL: nil, stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        var changedPages: [Int] = []
        session.pageDidChange = { changedPages.append($0) }

        let first = sampleStroke(10)
        let second = sampleStroke(50)
        session.addStroke(first, page: 1)
        session.addStroke(second, page: 1)
        XCTAssertEqual(session.strokes(onPage: 1).map(\.id), [first.id, second.id])
        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.canRedo)

        session.undo()
        XCTAssertEqual(session.strokes(onPage: 1).map(\.id), [first.id])
        XCTAssertTrue(session.canRedo)
        session.redo()
        XCTAssertEqual(session.strokes(onPage: 1).map(\.id), [first.id, second.id])
        XCTAssertEqual(changedPages, [1, 1, 1, 1])

        var refined = second.points
        refined[0].force = 0.99
        session.refineStroke(id: second.id, page: 1, points: refined)
        XCTAssertEqual(session.strokes(onPage: 1).last?.points[0].force, 0.99)
        session.undo()
        session.redo()
        XCTAssertEqual(session.strokes(onPage: 1).last?.points[0].force, 0.99, "redo keeps the refined force")

        session.saveNow()
        let loaded = library.loadAnnotations(for: meta.id)
        XCTAssertEqual(loaded.page(1).strokes.count, 2)
    }

    func testURLNormalization() {
        XCTAssertEqual(HTMLImportService.normalizedWebURL("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(HTMLImportService.normalizedWebURL(" http://a.b/c ")?.absoluteString, "http://a.b/c")
        XCTAssertNil(HTMLImportService.normalizedWebURL(""))
        XCTAssertNil(HTMLImportService.normalizedWebURL("ftp://x.y"))
    }

    func testStagingCopiesSiblingResourceFolder() throws {
        let source = root.appendingPathComponent("src", isDirectory: true)
        let files = source.appendingPathComponent("page_files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try "<img src='page_files/a.png'>".write(to: source.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: files.appendingPathComponent("a.png"))
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let entry = try HTMLImportService.stageLocalHTML(source.appendingPathComponent("page.html"), into: staging)
        XCTAssertEqual(entry.lastPathComponent, "page.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("page_files/a.png").path))

        let folderStaging = root.appendingPathComponent("staging2", isDirectory: true)
        try FileManager.default.createDirectory(at: folderStaging, withIntermediateDirectories: true)
        let folderEntry = try HTMLImportService.stageLocalHTML(source, into: folderStaging)
        XCTAssertEqual(folderEntry.lastPathComponent, "page.html")
    }
}
