import Foundation
import PDFKit
import UIKit
import XCTest
@testable import Quillmark

final class FullTextSearchTests: XCTestCase {
    private var root: URL!
    private var library: LibraryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quillmark-search-\(UUID().uuidString)", isDirectory: true)
        library = LibraryStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makePDFData(pages: [String]) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { ctx in
            for text in pages {
                ctx.beginPage()
                if !text.isEmpty {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 16),
                        .foregroundColor: UIColor.black,
                    ]
                    (text as NSString).draw(in: CGRect(x: 40, y: 60, width: 515, height: 700), withAttributes: attrs)
                }
            }
        }
    }

    private func createHTMLDocument(title: String,
                                    html: String,
                                    entryName: String = "index.html",
                                    folderID: UUID? = nil) throws -> DocumentMeta {
        let staging = root.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try html.write(to: staging.appendingPathComponent(entryName), atomically: true, encoding: .utf8)
        return try library.createDocument(
            title: title,
            pdfData: nil,
            layout: .live,
            sourceKind: .htmlFile,
            sourceURL: entryName,
            stagedSource: staging,
            sourceEntry: entryName,
            folderID: folderID
        )
    }

    // MARK: - 1. HTML & WebArchive Extraction

    func testHTMLTextExtractionSkipsNoisePreservesChineseAndTracksHeadings() {
        let html = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="UTF-8" />
          <title>中心投影课件</title>
          <style>.hidden-css-token { color: red; }</style>
          <script>const hiddenScriptToken = "should_not_match";</script>
        </head>
        <body>
          <!-- hiddenCommentToken -->
          <section data-expr="a > b">
            <h2>一、中心投影与三要素</h2>
            <p>光线照射到物体后形成的影子叫做物体的<strong>投影</strong>；角度满足 &alpha; &le; 90&deg;，运算 2 &times; 3 &lt; 8 &amp; &#20013;&#x6587;。</p>
            <table>
              <tr><td>情形①</td><td>平行于投影面</td><td>一定放大</td></tr>
            </table>
          </section>
          <section>
            <h3>二、相似三角形判定</h3>
            <p>由 <span class="math">AB &parallel; A&prime;B&prime;</span> 可得相似比。</p>
          </section>
          <noscript>hiddenNoscriptToken</noscript>
          <template>hiddenTemplateToken</template>
        </body>
        </html>
        """

        let segments = HTMLTextExtractor.extractSegments(fromHTML: html)
        XCTAssertEqual(segments.count, 2)

        XCTAssertEqual(segments[0].sectionTitle, "一、中心投影与三要素")
        XCTAssertTrue(segments[0].text.contains("叫做物体的投影；"))
        XCTAssertTrue(segments[0].text.contains("α ≤ 90°"))
        XCTAssertTrue(segments[0].text.contains("2 × 3 < 8 & 中文"))
        XCTAssertTrue(segments[0].text.contains("情形① 平行于投影面 一定放大"))

        XCTAssertEqual(segments[1].sectionTitle, "二、相似三角形判定")
        XCTAssertTrue(segments[1].text.contains("AB ∥ A′B′"))

        let joined = segments.map(\.text).joined(separator: "\n")
        XCTAssertFalse(joined.contains("hidden-css-token"))
        XCTAssertFalse(joined.contains("hiddenScriptToken"))
        XCTAssertFalse(joined.contains("hiddenCommentToken"))
        XCTAssertFalse(joined.contains("hiddenNoscriptToken"))
        XCTAssertFalse(joined.contains("hiddenTemplateToken"))
    }

    func testWebArchiveExtractionIncludesMainAndSubframeHTML() throws {
        let mainHTML = Data("<html><body><h1>主网页标题</h1><p>二次函数对称轴公式</p></body></html>".utf8)
        let subHTML = Data("<html><body><h2>子框架附录</h2><p>圆周角定理推论</p></body></html>".utf8)
        let archiveDict: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": mainHTML,
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "utf-8",
            ],
            "WebSubframeArchives": [
                [
                    "WebMainResource": [
                        "WebResourceData": subHTML,
                        "WebResourceMIMEType": "text/html",
                        "WebResourceTextEncodingName": "utf-8",
                    ],
                ],
            ],
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: archiveDict, format: .binary, options: 0)
        let segments = HTMLTextExtractor.extractSegments(fromWebArchiveData: plistData)
        let combined = segments.map(\.text).joined(separator: "\n")

        XCTAssertTrue(combined.contains("二次函数对称轴公式"))
        XCTAssertTrue(combined.contains("圆周角定理推论"))
    }

    // MARK: - 2. Cross-Document PDF + HTML Full-Text Search

    @MainActor
    func testCrossDocumentFullTextSearchAcrossPDFAndHTML() async throws {
        let geometryFolder = try library.createFolder(name: "九年级几何")
        let algebraFolder = try library.createFolder(name: "九年级代数")

        let pdfData = makePDFData(pages: [
            "第一页：一元二次方程求根公式与判别式复习",
            "第二页：已知抛物线顶点坐标，求三角形面积最大值（1）与 ABC 长度",
            "第三页：圆的切线判定定理与弦切角综合练习",
        ])
        let pdfMeta = try library.createDocument(
            title: "九上期中综合练习",
            pdfData: pdfData,
            layout: .pdf,
            sourceKind: .pdfFile,
            sourceURL: "midterm.pdf",
            stagedSource: nil,
            folderID: algebraFolder.id
        )

        let htmlMeta = try createHTMLDocument(
            title: "30.1 中心投影互动课件",
            html: """
            <html><body>
              <h2>一、中心投影概念</h2>
              <p>路灯下的影子属于中心投影，利用相似三角形求解影长。</p>
              <h2>二、拓展对比</h2>
              <p>复习抛物线与投影的综合建模问题。</p>
            </body></html>
            """,
            folderID: geometryFolder.id
        )

        let blankMeta = try BlankNotebookService.createNotebook(
            title: "课堂草稿本",
            paper: .grid,
            orientation: .portraitA4,
            pageCount: 2,
            folderID: nil,
            into: library
        )

        let engine = LibrarySearchEngine()

        // 1. Single token appearing in BOTH PDF (page 2) and HTML (section 2)
        let parabolaResults = await engine.searchNow(query: "抛物线", in: library)
        XCTAssertEqual(Set(parabolaResults.map(\.id)), Set([pdfMeta.id, htmlMeta.id]))

        let pdfResult = try XCTUnwrap(parabolaResults.first(where: { $0.id == pdfMeta.id }))
        XCTAssertEqual(pdfResult.matches.count, 1)
        XCTAssertEqual(pdfResult.matches[0].pageIndex, 1, "Zero-based page index 1 corresponds to Page 2")
        XCTAssertEqual(pdfResult.matches[0].locationLabel, "第 2 页")
        XCTAssertFalse(pdfResult.matches[0].highlightRanges.isEmpty)
        for r in pdfResult.matches[0].highlightRanges {
            XCTAssertEqual(String(pdfResult.matches[0].snippet[r]), "抛物线")
        }

        let htmlResult = try XCTUnwrap(parabolaResults.first(where: { $0.id == htmlMeta.id }))
        XCTAssertEqual(htmlResult.matches.first?.pageIndex, nil)
        XCTAssertEqual(htmlResult.matches.first?.locationLabel, "二、拓展对比")

        // 2. Multi-keyword AND query (only PDF has both "抛物线" and "面积")
        let multiResults = await engine.searchNow(query: "抛物线 面积", in: library)
        XCTAssertEqual(multiResults.map(\.id), [pdfMeta.id])
        XCTAssertGreaterThanOrEqual(multiResults[0].matches[0].highlightRanges.count, 2)

        // 3. Full-width/half-width and case-insensitive matching: "(1) abc" matches "（1）... ABC"
        let widthCaseResults = await engine.searchNow(query: "(1) abc", in: library)
        XCTAssertEqual(widthCaseResults.map(\.id), [pdfMeta.id])

        // 4. Document type and folder filtering
        let webOnly = await engine.searchNow(query: "抛物线", in: library, documentFilter: .web)
        XCTAssertEqual(webOnly.map(\.id), [htmlMeta.id])

        let pdfOnly = await engine.searchNow(query: "抛物线", in: library, documentFilter: .pdf)
        XCTAssertEqual(pdfOnly.map(\.id), [pdfMeta.id])

        let geometryOnly = await engine.searchNow(query: "抛物线", in: library, folderFilterID: geometryFolder.id)
        XCTAssertEqual(geometryOnly.map(\.id), [htmlMeta.id])

        // 5. Blank notebooks are never mistakenly flagged as needing scanned-PDF OCR
        let blankInput = try XCTUnwrap(SearchDocumentInput.snapshot(from: library).first(where: { $0.meta.id == blankMeta.id }))
        let blankCache = DocumentTextExtractor.extract(input: blankInput, performOCR: false)
        XCTAssertFalse(blankCache.hasUnrecognizedImagePages)
    }

    // MARK: - 3. Per-Document Disk Cache & Fingerprint Invalidation

    @MainActor
    func testDiskCachePersistsAndInvalidatesWhenSourceFileChanges() async throws {
        let htmlMeta = try createHTMLDocument(
            title: "动态更新讲义",
            html: "<html><body><h2>第一章</h2><p>原始关键词：勾股定理逆定理</p></body></html>"
        )

        let engine = LibrarySearchEngine()
        let firstHits = await engine.searchNow(query: "勾股定理逆定理", in: library)
        XCTAssertEqual(firstHits.map(\.id), [htmlMeta.id])

        let cacheURL = library.searchTextCacheURL(for: htmlMeta.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "Disk search cache should be written")

        // Mutate the underlying HTML source file with new content and a distinct modification timestamp.
        let entryURL = library.sourceFolder(for: htmlMeta.id).appendingPathComponent("index.html")
        try "<html><body><h2>更新章节</h2><p>新内容：垂径定理与圆心角</p></body></html>"
            .write(to: entryURL, atomically: true, encoding: .utf8)
        let futureDate = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: futureDate], ofItemAtPath: entryURL.path)

        let oldHits = await engine.searchNow(query: "勾股定理逆定理", in: library)
        XCTAssertTrue(oldHits.isEmpty, "Stale text cache must invalidate when source fingerprint changes")

        let newHits = await engine.searchNow(query: "垂径定理", in: library)
        XCTAssertEqual(newHits.map(\.id), [htmlMeta.id])
        XCTAssertEqual(newHits[0].matches.first?.locationLabel, "更新章节")
    }

    // MARK: - 4. TabManager Direct PDF Page Jump

    @MainActor
    func testTabManagerQueuesAndClampsTargetPDFPageOnOpen() throws {
        let pdfData = makePDFData(pages: ["第1页", "第2页", "第3页"])
        let pdfMeta = try library.createDocument(
            title: "多页试卷",
            pdfData: pdfData,
            layout: .pdf,
            sourceKind: .pdfFile,
            sourceURL: "exam.pdf",
            stagedSource: nil
        )

        let tabManager = TabManager()
        let tab = tabManager.open(pdfMeta, library: library, targetPDFPage: 2)
        XCTAssertTrue(tabManager.isWorkspaceVisible)
        XCTAssertEqual(tab.session.activeDocumentPageIndex, 2)
        XCTAssertEqual(tab.session.consumePendingJumpToPDFPage(), 2)
        XCTAssertNil(tab.session.consumePendingJumpToPDFPage(), "Pending page jump is consumed once")

        // Re-opening already-open tab with an out-of-range page clamps safely to last page.
        _ = tabManager.open(pdfMeta, library: library, targetPDFPage: 99)
        XCTAssertEqual(tab.session.activeDocumentPageIndex, 2)
        XCTAssertEqual(tab.session.consumePendingJumpToPDFPage(), 2)
    }
}
