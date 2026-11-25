import CoreGraphics
import Foundation
import XCTest
@testable import Quillmark

final class DataSafetyTests: XCTestCase {
    private var root: URL!
    private var library: LibraryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quillmark-safety-\(UUID().uuidString)", isDirectory: true)
        library = LibraryStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStroke(y: Float = 80) -> InkStroke {
        InkStroke(
            id: UUID(),
            pen: .ballpoint,
            color: .ink,
            width: 2,
            smoothing: 0.3,
            points: [
                InkPoint(x: 20, y: y, force: 0.5, t: 0),
                InkPoint(x: 120, y: y + 10, force: 0.5, t: 0.1),
            ],
            tool: .pen
        )
    }

    // MARK: 1. Corrupted & Future-Version Annotations Are Quarantined & Write-Protected

    func testCorruptedAnnotationsAreQuarantinedAndNeverOverwrittenOnScrollOrSave() throws {
        let meta = try library.createDocument(title: "期中压轴卷", pdfData: nil, layout: .live,
                                              sourceKind: .htmlFile, sourceURL: nil, stagedSource: nil)
        let corruptPayload = Data("{ \"version\": 1, \"pages\": BROKEN_JSON !!!".utf8)
        let annURL = library.annotationsURL(for: meta.id)
        try corruptPayload.write(to: annURL, options: .atomic)

        // Opening the session must engage write protection and quarantine a backup copy.
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        XCTAssertTrue(session.isWriteProtected)
        XCTAssertNotNil(session.loadErrorMessage)

        // Scrolling, zooming, changing paper style, or forcing saveNow MUST NOT overwrite `annotations.json`!
        session.updateViewport(ViewportState(offsetX: 0, offsetY: 420, zoomScale: 1.5, pageIndex: 0))
        session.scratchpadPaper = .dot
        session.saveNow()

        let stillOnDisk = try Data(contentsOf: annURL)
        XCTAssertEqual(stillOnDisk, corruptPayload, "write-protected session must never overwrite unreadable annotations.json")

        let folderFiles = try FileManager.default.contentsOfDirectory(atPath: library.folder(for: meta.id).path)
        let quarantineCopies = folderFiles.filter { $0.hasPrefix("annotations.corrupt-") }
        XCTAssertEqual(quarantineCopies.count, 1, "original corrupted bytes must be preserved in a quarantine copy")

        // Opening a second time reuses the identical quarantine file instead of duplicating it.
        _ = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        let folderFilesAfterSecondOpen = try FileManager.default.contentsOfDirectory(atPath: library.folder(for: meta.id).path)
        XCTAssertEqual(folderFilesAfterSecondOpen.filter { $0.hasPrefix("annotations.corrupt-") }.count, 1)

        // Explicitly lifting write protection lets the user start recording again safely.
        session.acknowledgeCorruptedLoadAndEnableSaving()
        XCTAssertFalse(session.isWriteProtected)
        XCTAssertNil(session.loadErrorMessage)
        session.addStroke(makeStroke(), page: 0)
        session.saveNow()
        XCTAssertEqual(library.loadAnnotations(for: meta.id).page(0).strokes.count, 1)
    }

    func testUnsupportedFutureVersionAnnotationsAreWriteProtected() throws {
        let meta = try library.createDocument(title: "新版批注", pdfData: nil, layout: .live,
                                              sourceKind: .htmlFile, sourceURL: nil, stagedSource: nil)
        let futurePayload = Data("{\"version\":99,\"pages\":{},\"futureRequiredField\":\"abc\"}".utf8)
        let annURL = library.annotationsURL(for: meta.id)
        try futurePayload.write(to: annURL, options: .atomic)

        if case let .unsupportedVersion(version, qURL) = library.loadAnnotationsResult(for: meta.id) {
            XCTAssertEqual(version, 99)
            XCTAssertNotNil(qURL)
        } else {
            return XCTFail("Expected .unsupportedVersion(99)")
        }

        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        XCTAssertTrue(session.isWriteProtected)
        XCTAssertTrue(session.loadErrorMessage?.contains("v99") == true)
        session.updateViewport(ViewportState(offsetX: 10, offsetY: 20, zoomScale: 1.0, pageIndex: 0))
        session.saveNow()
        XCTAssertEqual(try Data(contentsOf: annURL), futurePayload)
    }

    // MARK: 2. Tolerant Enum Decoding & NaN Sanitization

    func testTolerantEnumDecodingAndNonFiniteFloatSanitization() throws {
        // Unknown future enum values gracefully fall back instead of throwing.
        let json = """
        {
          "version": 1,
          "scratchpadPaper": "isometricFutureStyle",
          "pages": {
            "0": {
              "strokes": [{
                "id": "11111111-2222-3333-4444-555555555555",
                "pen": "futureLaserPen",
                "color": {"r": 0.1, "g": 0.2, "b": 0.3, "a": 1.0},
                "width": 2.0,
                "smoothing": 0.3,
                "points": [{"x": 10, "y": 20, "force": 0.5, "azimuth": 0, "altitude": 1.5, "t": 0}],
                "tool": "futureCalligraphyTool",
                "lineStyle": "doubleDashFuture"
              }]
            }
          }
        }
        """
        let decoded = try LibraryStore.makeDecoder().decode(DocumentAnnotations.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.scratchpadPaper, .grid)
        let stroke = try XCTUnwrap(decoded.page(0).strokes.first)
        XCTAssertEqual(stroke.pen, .ballpoint)
        XCTAssertEqual(stroke.tool, .pen)
        XCTAssertEqual(stroke.lineStyle, .solid)

        // NaN / Infinity values are scrubbed before JSON encoding so saves never break permanently.
        let meta = try library.createDocument(title: "nan-guard", pdfData: nil, layout: .live,
                                              sourceKind: .htmlFile, sourceURL: nil, stagedSource: nil)
        var dirty = DocumentAnnotations()
        var badStroke = makeStroke()
        badStroke.width = .nan
        badStroke.points[0].x = .infinity
        badStroke.geometry = .circle(center: CGPoint(x: CGFloat.nan, y: 50), radius: CGFloat.infinity, showCenterMark: true)
        dirty.pages["0"] = PageAnnotations(strokes: [badStroke])
        dirty.viewport = ViewportState(offsetX: CGFloat.nan, offsetY: 10, zoomScale: 1, pageIndex: 0)
        dirty.scratchpadFrame = CGRect(x: CGFloat.nan, y: 0, width: 200, height: 200)

        XCTAssertNoThrow(try library.saveAnnotations(dirty, for: meta.id))
        let reloaded = library.loadAnnotations(for: meta.id)
        XCTAssertEqual(reloaded.page(0).strokes.count, 1)
        XCTAssertNil(reloaded.viewport)
        XCTAssertNil(reloaded.scratchpadFrame)
        XCTAssertTrue(reloaded.page(0).strokes[0].width.isFinite)
    }

    // MARK: 3. Duplicate-ID Folder Repair & TabManager Crash Guard

    @MainActor
    func testFolderUUIDMismatchRepairAndTabManagerSyncDoesNotCrash() throws {
        let original = try library.createDocument(title: "原试卷", pdfData: nil, layout: .live,
                                                  sourceKind: .htmlFile, sourceURL: nil, stagedSource: nil)
        // Simulate a user manually copying a `.qmark` folder in Finder (different folder UUID, same `meta.id`!).
        let copiedID = UUID()
        let copiedFolder = library.folder(for: copiedID)
        try FileManager.default.copyItem(at: library.folder(for: original.id), to: copiedFolder)

        library.reload()
        XCTAssertEqual(library.documents.count, 2)
        let ids = Set(library.documents.map(\.id))
        XCTAssertEqual(ids, Set([original.id, copiedID]), "reload must auto-repair folder-vs-meta UUID mismatch")

        // Even if duplicate DocumentMeta entries were passed directly, TabManager.syncMetadata must never trap.
        let tabs = TabManager()
        tabs.open(original, library: library)
        tabs.syncMetadata(from: [original, original])
        XCTAssertEqual(tabs.tabs.count, 1)
    }

    // MARK: 4. Streaming Backup V2, Replace Policy, V1 Compatibility & Local Rotating Backups

    func testStreamingBackupV2ReplacePolicyV1CompatibilityAndRotatingLocalBackups() async throws {
        let folder = try library.createFolder(name: "九年级几何")
        let doc = try library.createDocument(title: "圆的切线专题", pdfData: Data("%PDF-1.4\n%%EOF".utf8),
                                             layout: .pdf, sourceKind: .pdfFile, sourceURL: "circle.pdf",
                                             stagedSource: nil, folderID: folder.id)
        let session = DocumentSession(meta: doc, library: library, tool: ToolSettings())
        session.addStroke(makeStroke(y: 60), page: 0)
        session.addStroke(makeStroke(y: 120), page: 0)
        session.saveNow()

        XCTAssertNil(library.lastBackupDate)
        XCTAssertTrue(library.needsBackupReminder)

        // 1. Export streaming V2 backup off-main into rotating local Backups/ folder.
        let localBackupURL = try await BackupArchiveService.exportFullLibraryAsync(from: library, saveToLocalBackups: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localBackupURL.path))
        let magic = try Data(contentsOf: localBackupURL).prefix(6)
        XCTAssertEqual(String(decoding: magic, as: UTF8.self), "QMBK02")
        XCTAssertNotNil(library.lastBackupDate)
        XCTAssertFalse(library.needsBackupReminder)

        // 2. Wipe the document's ink locally, then restore with `.replaceExisting` to recover all 2 strokes!
        library.clearInk(for: doc.id, keepTapes: false)
        XCTAssertEqual(library.loadAnnotations(for: doc.id).page(0).strokes.count, 0)

        let replaceSummary = try await BackupArchiveService.importBackupAsync(
            from: localBackupURL,
            into: library,
            duplicatePolicy: .replaceExisting
        )
        XCTAssertEqual(replaceSummary.replacedExistingDocuments, 1)
        XCTAssertEqual(replaceSummary.importedDocuments, 0)
        XCTAssertEqual(library.loadAnnotations(for: doc.id).page(0).strokes.count, 2,
                       "replaceExisting restore must recover lost strokes over existing ID")

        // 3. Verify future-version V2 archive triggers `.unsupportedVersion` BEFORE decoding payload.
        var futureV2 = Data("QMBK02".utf8)
        var ver = UInt32(99).bigEndian
        futureV2.append(withUnsafeBytes(of: &ver) { Data($0) })
        let futureURL = root.appendingPathComponent("future.qmbackup")
        try futureV2.write(to: futureURL, options: .atomic)
        do {
            _ = try BackupArchiveService.importBackup(from: futureURL, into: library)
            XCTFail("Expected unsupportedVersion error")
        } catch let error as BackupError {
            if case .unsupportedVersion(99) = error {
                // Expected!
            } else {
                XCTFail("Unexpected BackupError: \(error)")
            }
        }

        // 4. Verify legacy V1 (`QMBK01`) archives still restore cleanly.
        let legacyDocMeta = DocumentMeta(id: UUID(), title: "旧版备份试卷", createdAt: Date(), modifiedAt: Date(),
                                         layout: .pdf, sourceKind: .pdfFile, sourceURL: "legacy.pdf")
        var legacyAnn = DocumentAnnotations()
        legacyAnn.pages["0"] = PageAnnotations(strokes: [makeStroke()])
        let legacyPayload = BackupArchiveService.ArchivePayload(
            schemaVersion: 1,
            exportedAt: Date(),
            isFullLibrary: false,
            folders: [],
            documents: [
                BackupArchiveService.ArchivedDocument(
                    meta: legacyDocMeta,
                    annotations: legacyAnn,
                    pdfData: Data("%PDF-1.4\n%%EOF".utf8),
                    thumbnailData: nil,
                    sourceFiles: [:]
                ),
            ]
        )
        let legacyURL = root.appendingPathComponent("legacy-v1.qmbackup")
        try BackupArchiveService.encodeArchive(legacyPayload).write(to: legacyURL, options: .atomic)
        let v1Summary = try await BackupArchiveService.importBackupAsync(from: legacyURL, into: library)
        XCTAssertEqual(v1Summary.importedDocuments, 1)
        XCTAssertEqual(library.loadAnnotations(for: legacyDocMeta.id).page(0).strokes.count, 1)
    }
}
