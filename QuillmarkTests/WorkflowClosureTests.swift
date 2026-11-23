import CoreGraphics
import PDFKit
import UIKit
import XCTest
@testable import Quillmark

final class WorkflowClosureTests: XCTestCase {
    private var root: URL!
    private var library: LibraryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("closure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makePDFData(pageCount: Int = 2) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { ctx in
            for i in 0..<pageCount {
                ctx.beginPage()
                let text = "Question \(i + 1)" as NSString
                text.draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
    }

    private func makeSolidImage(size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func makeRedStroke(y: Float = 160) -> InkStroke {
        let pts = (0...12).map { i in
            InkPoint(x: 80 + Float(i) * 18, y: y, force: 0.7, t: Float(i) / 120)
        }
        return InkStroke(id: UUID(), pen: .ballpoint, color: RGBAColor(0.92, 0.10, 0.10),
                         width: 8, smoothing: 0, points: pts, tool: .pen)
    }

    private func makeBlueTape(y: Float = 320, revealed: Bool = true) -> InkStroke {
        let pts = [
            InkPoint(x: 80, y: y, force: 0.5, t: 0),
            InkPoint(x: 320, y: y, force: 0.5, t: 0.1),
        ]
        return InkStroke(id: UUID(), pen: .ballpoint, color: RGBAColor(0.15, 0.45, 0.90),
                         width: 32, smoothing: 0, points: pts, tool: .tape, revealed: revealed)
    }

    private func samplePixelColor(in image: UIImage, at point: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let cgImage = image.cgImage else { return nil }
        let x = min(max(0, Int(round(point.x))), cgImage.width - 1)
        let y = min(max(0, Int(round(point.y))), cgImage.height - 1)
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height))
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }

    // MARK: 1. Library Organization (Folders, Rename, Pin, Move)

    func testFoldersRenamePinAndDeletePreservesDocuments() throws {
        let f1 = try library.createFolder(name: "九年级几何")
        let f2 = try library.createFolder(name: "期中复习")
        XCTAssertEqual(library.folders.count, 2)

        let doc = try library.createDocument(
            title: "原始标题",
            pdfData: makePDFData(),
            layout: .pdf,
            sourceKind: .pdfFile,
            sourceURL: "orig.pdf",
            stagedSource: nil,
            folderID: f1.id
        )
        XCTAssertEqual(doc.folderID, f1.id)
        XCTAssertFalse(doc.pinned)

        try library.renameDocument(doc.id, to: "31.1 圆的基本性质")
        try library.togglePin(doc.id)
        try library.moveDocument(doc.id, toFolder: f2.id)
        try library.renameFolder(f2.id, to: "九下期中复习")

        // Reload from disk to verify persistence.
        let reloaded = LibraryStore(root: library.root)
        XCTAssertEqual(reloaded.folderName(for: f2.id), "九下期中复习")
        let savedDoc = try XCTUnwrap(reloaded.documents.first(where: { $0.id == doc.id }))
        XCTAssertEqual(savedDoc.title, "31.1 圆的基本性质")
        XCTAssertTrue(savedDoc.pinned)
        XCTAssertEqual(savedDoc.folderID, f2.id)

        // Deleting folder must keep the document intact as uncategorized.
        reloaded.deleteFolder(f2.id)
        let afterDelete = try XCTUnwrap(reloaded.documents.first(where: { $0.id == doc.id }))
        XCTAssertNil(afterDelete.folderID)
        XCTAssertEqual(afterDelete.title, "31.1 圆的基本性质")
    }

    // MARK: 2. Blank Math Notebooks & Image-to-PDF Import

    func testBlankNotebookCreationAllPaperStylesAndOrientations() throws {
        for style in ScratchpadPaperStyle.allCases {
            let portraitMeta = try BlankNotebookService.createNotebook(
                title: "竖版-\(style.rawValue)",
                paper: style,
                orientation: .portraitA4,
                pageCount: 3,
                into: library
            )
            let pdf = try XCTUnwrap(PDFDocument(url: library.pdfURL(for: portraitMeta.id)))
            XCTAssertEqual(pdf.pageCount, 3)
            let size = try XCTUnwrap(pdf.page(at: 0)?.bounds(for: .cropBox).size)
            XCTAssertEqual(size.width, 595.28, accuracy: 1.0)
            XCTAssertEqual(size.height, 841.89, accuracy: 1.0)
        }

        let wideMeta = try BlankNotebookService.createNotebook(
            title: "宽屏板书",
            paper: .graph,
            orientation: .landscape16x9,
            pageCount: 2,
            into: library
        )
        let widePDF = try XCTUnwrap(PDFDocument(url: library.pdfURL(for: wideMeta.id)))
        XCTAssertEqual(widePDF.pageCount, 2)
        let wideSize = try XCTUnwrap(widePDF.page(at: 0)?.bounds(for: .cropBox).size)
        XCTAssertEqual(wideSize.width, 960, accuracy: 1.0)
        XCTAssertEqual(wideSize.height, 540, accuracy: 1.0)
    }

    @MainActor
    func testImageImportToMultiPagePDF() async throws {
        let portraitImg = makeSolidImage(size: CGSize(width: 600, height: 900), color: .systemTeal)
        let landscapeImg = makeSolidImage(size: CGSize(width: 1200, height: 600), color: .systemOrange)

        let meta = try ImageImportService.importImages([portraitImg, landscapeImg], title: "学生错题拍照", into: library)
        XCTAssertEqual(meta.layout, .pdf)
        XCTAssertEqual(meta.sourceKind, .imageSet)
        let pdf = try XCTUnwrap(PDFDocument(url: library.pdfURL(for: meta.id)))
        XCTAssertEqual(pdf.pageCount, 2)
        let p0 = try XCTUnwrap(pdf.page(at: 0)?.bounds(for: .cropBox).size)
        let p1 = try XCTUnwrap(pdf.page(at: 1)?.bounds(for: .cropBox).size)
        XCTAssertLessThan(p0.width, p0.height, "portrait photo gets portrait A4 page")
        XCTAssertGreaterThan(p1.width, p1.height, "landscape photo gets landscape A4 page")

        // Also test direct image file import via HTMLImportService.
        let pngURL = root.appendingPathComponent("作业第1题.png")
        try XCTUnwrap(portraitImg.pngData()).write(to: pngURL)
        let imported = try await HTMLImportService.importDocument(from: .file(pngURL), into: library)
        XCTAssertEqual(imported.title, "作业第1题")
        XCTAssertEqual(imported.layout, .pdf)
    }

    // MARK: 3. Multi-Class Annotation Layers

    func testMultiClassAnnotationLayersAndLegacyCompatibility() throws {
        let meta = try library.createDocument(title: "压轴题讲义", pdfData: makePDFData(),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "a.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())

        // Legacy default single layer before adding any second class.
        XCTAssertEqual(session.layers.count, 1)
        XCTAssertFalse(session.hasMultipleLayers)

        let pen1 = makeRedStroke(y: 120)
        let tape1 = makeBlueTape(y: 260, revealed: true)
        let scratch1 = makeRedStroke(y: 80)
        session.addStroke(pen1, page: 0)
        session.addStroke(tape1, page: 0)
        session.addStroke(scratch1, page: -1)
        let firstLayerID = session.activeLayerID
        session.renameLayer(id: firstLayerID, to: "九(1)班")

        // Create second class layer inheriting cover tapes (reset to covered) without class 1's handwriting.
        let class2 = session.createLayer(name: "九(2)班", template: .keepTapesFromCurrent)
        XCTAssertEqual(session.layers.count, 2)
        XCTAssertTrue(session.hasMultipleLayers)
        XCTAssertEqual(session.activeLayerName, "九(2)班")
        XCTAssertEqual(session.strokes(onPage: 0).count, 1)
        XCTAssertEqual(session.strokes(onPage: 0).first?.isTape, true)
        XCTAssertEqual(session.strokes(onPage: 0).first?.isRevealed, false, "inherited tapes reset to covered")
        XCTAssertTrue(session.strokes(onPage: -1).isEmpty, "class 2 gets fresh scratchpad")

        let pen2 = makeRedStroke(y: 200)
        session.addStroke(pen2, page: 0)
        session.saveNow()

        // Switch back to class 1 -> original handwriting, revealed tape, and scratchpad intact!
        session.switchLayer(to: firstLayerID)
        XCTAssertEqual(session.activeLayerName, "九(1)班")
        XCTAssertEqual(session.strokes(onPage: 0).map(\.id), [pen1.id, tape1.id])
        XCTAssertEqual(session.strokes(onPage: 0).last?.isRevealed, true)
        XCTAssertEqual(session.strokes(onPage: -1).map(\.id), [scratch1.id])

        // Reopen fresh session from disk to verify persistence of both class layers.
        let reopened = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        XCTAssertEqual(reopened.layers.count, 2)
        XCTAssertEqual(reopened.activeLayerName, "九(1)班")
        reopened.switchLayer(to: class2.id)
        XCTAssertEqual(reopened.strokes(onPage: 0).count, 2)

        // Deleting class 2 returns safely to class 1; deleting the last remaining layer is blocked.
        reopened.deleteLayer(id: class2.id)
        XCTAssertEqual(reopened.layers.count, 1)
        XCTAssertEqual(reopened.activeLayerID, firstLayerID)
        reopened.deleteLayer(id: firstLayerID)
        XCTAssertEqual(reopened.layers.count, 1, "must keep at least one layer")
    }

    // MARK: 4. PDF Blank Page Insertion Shifting All Class Layers

    func testPDFBlankPageInsertionShiftsAllClassLayers() throws {
        let meta = try library.createDocument(title: "几何专题", pdfData: makePDFData(pageCount: 2),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "geo.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())

        let class1Page0 = makeRedStroke(y: 100)
        let class1Page1 = makeRedStroke(y: 200)
        session.addStroke(class1Page0, page: 0)
        session.addStroke(class1Page1, page: 1)
        let class1ID = session.activeLayerID

        let class2 = session.createLayer(name: "九(2)班", template: .blank)
        let class2Page1 = makeRedStroke(y: 300)
        session.addStroke(class2Page1, page: 1)

        // Insert a blank grid page right after page 0 (becomes new page 1; old page 1 becomes page 2).
        let insertedIndex = try session.insertBlankPDFPage(after: 0, paper: .grid)
        XCTAssertEqual(insertedIndex, 1)
        XCTAssertEqual(session.pdfPageCount, 3)

        // Verify class 2 shifted page 1 -> page 2.
        XCTAssertTrue(session.strokes(onPage: 1).isEmpty)
        XCTAssertEqual(session.strokes(onPage: 2).map(\.id), [class2Page1.id])

        // Verify class 1 ALSO shifted page 1 -> page 2 while page 0 stayed on page 0.
        session.switchLayer(to: class1ID)
        XCTAssertEqual(session.strokes(onPage: 0).map(\.id), [class1Page0.id])
        XCTAssertTrue(session.strokes(onPage: 1).isEmpty)
        XCTAssertEqual(session.strokes(onPage: 2).map(\.id), [class1Page1.id])
        XCTAssertNotNil(class2.id)
    }

    // MARK: 5. Annotated PDF & PNG Export (Vector Ink, Tape Modes, Scratchpad)

    @MainActor
    func testAnnotatedPDFExportVectorTapeModesAndScratchpad() async throws {
        let meta = try library.createDocument(title: "期中讲评卷", pdfData: makePDFData(pageCount: 2),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "midterm.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        session.addStroke(makeRedStroke(y: 160), page: 0)
        session.addStroke(makeBlueTape(y: 320, revealed: false), page: 0)
        session.addStroke(makeRedStroke(y: 140), page: -1)
        session.saveNow()

        // 1. Export asDisplayed + includeScratchpad -> 2 PDF pages + 1 non-empty scratchpad page = 3 pages.
        let asDisplayedResult = try await DocumentExportService.export(
            meta: meta,
            annotations: session.annotations,
            library: library,
            options: ExportOptions(format: .annotatedPDF, tapeMode: .asDisplayed, includeScratchpad: true)
        )
        XCTAssertEqual(asDisplayedResult.pageCount, 3)
        let exportedPDF = try XCTUnwrap(PDFDocument(url: asDisplayedResult.fileURL))
        XCTAssertEqual(exportedPDF.pageCount, 3)

        // Rasterize page 0 and verify both red stroke (y=160) and opaque blue tape (y=320) rendered cleanly!
        let page0PNG = try DocumentExportService.renderSinglePDFPagePNG(exportedPDF, pageIndex: 0, targetWidthPixels: 595)
        let page0Img = try XCTUnwrap(UIImage(data: page0PNG))
        let redSample = try XCTUnwrap(samplePixelColor(in: page0Img, at: CGPoint(x: 150, y: 160)))
        XCTAssertGreaterThan(redSample.r, 0.7)
        XCTAssertLessThan(redSample.g, 0.35)
        let blueTapeSample = try XCTUnwrap(samplePixelColor(in: page0Img, at: CGPoint(x: 180, y: 320)))
        XCTAssertGreaterThan(blueTapeSample.b, 0.65)
        XCTAssertLessThan(blueTapeSample.r, 0.4)

        // 2. Export revealAll (解析版) without scratchpad -> 2 pages, blue tape must be omitted (white background).
        let answerResult = try await DocumentExportService.export(
            meta: meta,
            annotations: session.annotations,
            library: library,
            options: ExportOptions(format: .annotatedPDF, tapeMode: .revealAll, includeScratchpad: false)
        )
        XCTAssertEqual(answerResult.pageCount, 2)
        XCTAssertTrue(answerResult.filename.contains("解析版"))
        let answerPDF = try XCTUnwrap(PDFDocument(url: answerResult.fileURL))
        let answerPNG = try DocumentExportService.renderSinglePDFPagePNG(answerPDF, pageIndex: 0, targetWidthPixels: 595)
        let answerImg = try XCTUnwrap(UIImage(data: answerPNG))
        let uncoveredSample = try XCTUnwrap(samplePixelColor(in: answerImg, at: CGPoint(x: 180, y: 320)))
        XCTAssertGreaterThan(uncoveredSample.r, 0.9, "revealAll export must remove opaque tape")
        XCTAssertGreaterThan(uncoveredSample.g, 0.9)

        // 3. Export currentPagePNG & stitchedPNG.
        let singlePNG = try await DocumentExportService.export(
            meta: meta,
            annotations: session.annotations,
            library: library,
            options: ExportOptions(format: .currentPagePNG, tapeMode: .coverAll, includeScratchpad: false, currentPageIndex: 0)
        )
        XCTAssertEqual(singlePNG.pageCount, 1)
        let singleImg = try XCTUnwrap(UIImage(contentsOfFile: singlePNG.fileURL.path))

        let stitchedPNG = try await DocumentExportService.export(
            meta: meta,
            annotations: session.annotations,
            library: library,
            options: ExportOptions(format: .stitchedPNG, tapeMode: .asDisplayed, includeScratchpad: true)
        )
        XCTAssertEqual(stitchedPNG.pageCount, 3)
        let stitchedImg = try XCTUnwrap(UIImage(contentsOfFile: stitchedPNG.fileURL.path))
        XCTAssertGreaterThan(stitchedImg.size.height, singleImg.size.height * 1.8)
    }

    // MARK: 6. Portable Backup Archive (.qmbackup) Round-Trip

    func testBackupArchiveSingleAndFullLibraryRoundTripWithHTMLResources() throws {
        let folder = try library.createFolder(name: "初三冲刺")

        // Doc 1: PDF with two class layers + pin + folder.
        let pdfMeta = try library.createDocument(
            title: "二次函数压轴",
            pdfData: makePDFData(pageCount: 2),
            layout: .pdf,
            sourceKind: .pdfFile,
            sourceURL: "quad.pdf",
            stagedSource: nil,
            folderID: folder.id
        )
        try library.togglePin(pdfMeta.id)
        let pdfSession = DocumentSession(meta: pdfMeta, library: library, tool: ToolSettings())
        pdfSession.addStroke(makeRedStroke(), page: 0)
        pdfSession.addStroke(makeBlueTape(revealed: true), page: 0)
        pdfSession.createLayer(name: "九(3)班", template: .keepTapesFromCurrent)
        pdfSession.saveNow()

        // Doc 2: Live HTML document with nested resource subdirectory.
        let htmlStaging = root.appendingPathComponent("html-src", isDirectory: true)
        let assetsDir = htmlStaging.appendingPathComponent("page_files/img", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try "<html><body><h1>圆的性质</h1><img src='page_files/img/fig.png'></body></html>"
            .write(to: htmlStaging.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let figBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])
        try figBytes.write(to: assetsDir.appendingPathComponent("fig.png"))

        let htmlMeta = try library.createDocument(
            title: "互动网页讲义",
            pdfData: nil,
            layout: .live,
            sourceKind: .htmlFile,
            sourceURL: "index.html",
            stagedSource: htmlStaging,
            sourceEntry: "index.html",
            folderID: folder.id
        )

        // Export full library backup.
        let fullBackupURL = try BackupArchiveService.exportFullLibrary(from: library)
        XCTAssertEqual(fullBackupURL.pathExtension, BackupArchiveService.fileExtension)

        // Restore into a brand-new empty LibraryStore.
        let restoredLib = LibraryStore(root: root.appendingPathComponent("RestoredLibrary", isDirectory: true))
        let summary1 = try BackupArchiveService.importBackup(from: fullBackupURL, into: restoredLib)
        XCTAssertEqual(summary1.importedDocuments, 2)
        XCTAssertEqual(summary1.importedFolders, 1)
        XCTAssertEqual(summary1.skippedExistingDocuments, 0)
        XCTAssertEqual(restoredLib.folders.first?.name, "初三冲刺")

        let restoredPDFMeta = try XCTUnwrap(restoredLib.documents.first(where: { $0.id == pdfMeta.id }))
        XCTAssertTrue(restoredPDFMeta.pinned)
        XCTAssertEqual(restoredPDFMeta.folderID, folder.id)
        let restoredAnns = restoredLib.loadAnnotations(for: pdfMeta.id)
        XCTAssertEqual(restoredAnns.resolvedLayers.count, 2)
        XCTAssertEqual(restoredAnns.activeLayerName, "九(3)班")

        let restoredFig = restoredLib.sourceFolder(for: htmlMeta.id).appendingPathComponent("page_files/img/fig.png")
        XCTAssertEqual(try Data(contentsOf: restoredFig), figBytes)

        // Re-importing the same full backup skips existing docs cleanly.
        let summary2 = try BackupArchiveService.importBackup(from: fullBackupURL, into: restoredLib)
        XCTAssertEqual(summary2.importedDocuments, 0)
        XCTAssertEqual(summary2.skippedExistingDocuments, 2)

        // Single-document backup imported into a library that already has it creates an independent copy.
        let singleBackupURL = try BackupArchiveService.exportDocument(pdfMeta.id, from: library)
        let singleSummary = try BackupArchiveService.importBackup(from: singleBackupURL, into: restoredLib)
        XCTAssertEqual(singleSummary.importedDocuments, 1)
        XCTAssertNotEqual(singleSummary.firstImportedID, pdfMeta.id)
        XCTAssertEqual(restoredLib.documents.count, 3)

        // Corrupt backup file throws BackupError.invalidArchive cleanly.
        let corruptURL = root.appendingPathComponent("corrupt.qmbackup")
        try Data("not a valid backup".utf8).write(to: corruptURL)
        XCTAssertThrowsError(try BackupArchiveService.importBackup(from: corruptURL, into: restoredLib))
    }
}
