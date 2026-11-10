import PDFKit
import XCTest
@testable import Quillmark

/// Exercises the real WebKit → PDF pipeline inside the simulator host app.
final class HTMLConversionTests: XCTestCase {
    private func writeSampleHTML() throws -> (file: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("html-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paragraph = "<p>羽签测试段落 Quillmark sample paragraph used to fill several printed pages of content.</p>"
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>样例网页</title>
        <style>body{font-family:-apple-system;font-size:18px;} h1{background:#ffd54f;}</style></head>
        <body><h1>标题</h1>\(String(repeating: paragraph, count: 160))</body></html>
        """
        let file = folder.appendingPathComponent("index.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        return (file, folder)
    }

    @MainActor
    func testPagedA4Conversion() async throws {
        let sample = try writeSampleHTML()
        let output = try await HTMLPDFConverter.convert(.file(sample.file, readAccess: sample.folder), layout: .pagedA4)
        let document = try XCTUnwrap(PDFDocument(data: output.pdfData))
        XCTAssertGreaterThan(document.pageCount, 1)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, HTMLPDFConverter.a4.width, accuracy: 1)
        XCTAssertEqual(bounds.height, HTMLPDFConverter.a4.height, accuracy: 1)
        XCTAssertEqual(output.title, "样例网页")
        XCTAssertTrue(document.string?.contains("Quillmark") ?? false, "printed pages keep selectable text")
    }

    @MainActor
    func testLongPageConversion() async throws {
        let sample = try writeSampleHTML()
        let output = try await HTMLPDFConverter.convert(.file(sample.file, readAccess: sample.folder), layout: .longPage)
        let document = try XCTUnwrap(PDFDocument(data: output.pdfData))
        XCTAssertGreaterThanOrEqual(document.pageCount, 1)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertGreaterThan(bounds.height, bounds.width * 2)
    }
}
