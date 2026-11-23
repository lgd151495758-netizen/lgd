import CoreGraphics
import UIKit
import XCTest
@testable import Quillmark

final class EfficiencyAndStabilityTests: XCTestCase {
    private var root: URL!
    private var library: LibraryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makePDFData(pageCount: Int = 2) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for _ in 0..<pageCount { ctx.beginPage() }
        }
    }

    private func makeStroke(y: Float = 100) -> InkStroke {
        InkStroke(
            id: UUID(),
            pen: .ballpoint,
            color: .ink,
            width: 1.8,
            smoothing: 0,
            points: [InkPoint(x: 20, y: y, force: 0.5, t: 0), InkPoint(x: 120, y: y, force: 0.5, t: 0.1)],
            tool: .pen
        )
    }

    // MARK: 1. Quick Pen Presets & Chalk Colors

    func testQuickPenPresetsSelectionCustomizationPersistenceAndReset() throws {
        let suite = "pen-presets-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var tool = ToolSettings()
        XCTAssertEqual(tool.resolvedPenPresets.count, 4)
        XCTAssertEqual(tool.resolvedPenPresets[2].lineStyle, .dashed, "slot 3 defaults to blue dashed auxiliary line")
        XCTAssertTrue(tool.resolvedPenPresets[3].color.isVeryLight, "slot 4 defaults to chalk white for dark HTML")
        XCTAssertFalse(RGBAColor.ink.isVeryLight)

        // Switching from eraser directly to preset slot 2 activates pen + blue dashed line in one tap.
        tool.select(.eraser)
        tool.selectPenPreset(at: 2)
        XCTAssertEqual(tool.kind, .pen)
        XCTAssertEqual(tool.activePenPresetIndex, 2)
        XCTAssertEqual(tool.lineStyle, .dashed)
        XCTAssertEqual(tool.color, ToolSettings.palette[1])

        // Customizing color/width/lineStyle updates the active slot in place.
        let green = ToolSettings.palette[3]
        tool.updatePenColor(green)
        tool.updatePenWidth(3.0)
        tool.updatePenLineStyle(.dotted)
        XCTAssertEqual(tool.resolvedPenPresets[2].color, green)
        XCTAssertEqual(tool.resolvedPenPresets[2].width, 3.0)
        XCTAssertEqual(tool.resolvedPenPresets[2].lineStyle, .dotted)

        // Save and reload from UserDefaults.
        tool.save(to: defaults)
        var reloaded = ToolSettings.load(from: defaults)
        XCTAssertEqual(reloaded.activePenPresetIndex, 2)
        XCTAssertEqual(reloaded.resolvedPenPresets[2].color, green)
        XCTAssertEqual(reloaded.resolvedPenPresets[2].lineStyle, .dotted)

        // Reset restores defaults cleanly.
        reloaded.resetPenPresetsToDefault()
        XCTAssertEqual(reloaded.resolvedPenPresets[2].lineStyle, .dashed)
        XCTAssertEqual(reloaded.lineStyle, .dashed)
    }

    // MARK: 2. Multi-Finger Tap Undo / Redo Gesture Controller

    @MainActor
    func testMultiTouchUndoGestureControllerTriggersUndoRedoAndNotification() throws {
        let meta = try library.createDocument(title: "gesture-test", pdfData: makePDFData(),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "g.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        let controller = MultiTouchUndoGestureController(session: session)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        controller.attach(to: host)

        XCTAssertEqual(controller.twoFingerUndoTap.numberOfTouchesRequired, 2)
        XCTAssertEqual(controller.threeFingerRedoTap.numberOfTouchesRequired, 3)
        XCTAssertFalse(controller.twoFingerUndoTap.cancelsTouchesInView)
        XCTAssertFalse(controller.threeFingerRedoTap.cancelsTouchesInView)
        XCTAssertEqual(controller.twoFingerUndoTap.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])

        var feedbackMessages: [String] = []
        let token = NotificationCenter.default.addObserver(forName: .quillmarkUndoRedoFeedback, object: nil, queue: nil) { note in
            if let msg = note.userInfo?["message"] as? String {
                feedbackMessages.append(msg)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let s1 = makeStroke(y: 60)
        session.addStroke(s1, page: 0)
        XCTAssertEqual(session.strokes(onPage: 0).count, 1)

        controller.triggerUndo()
        XCTAssertTrue(session.strokes(onPage: 0).isEmpty)
        XCTAssertEqual(feedbackMessages.last, "已撤销")

        controller.triggerRedo()
        XCTAssertEqual(session.strokes(onPage: 0).map(\.id), [s1.id])
        XCTAssertEqual(feedbackMessages.last, "已重做")

        // When disabled, gesture triggers are ignored cleanly.
        session.tool.multiFingerUndo = false
        controller.triggerUndo()
        XCTAssertEqual(session.strokes(onPage: 0).count, 1)
    }

    // MARK: 3. Multi-Tab LRU Memory Hibernation & Seamless Revival

    @MainActor
    func testTabDeckLRUHibernationAndSeamlessRevival() throws {
        let manager = TabManager()
        var metas: [DocumentMeta] = []
        for i in 1...6 {
            let meta = try library.createDocument(title: "卷\(i)", pdfData: makePDFData(pageCount: 2),
                                                  layout: .pdf, sourceKind: .pdfFile, sourceURL: "d\(i).pdf", stagedSource: nil)
            metas.append(meta)
        }

        let deck = TabDeckViewController()
        deck.maxLiveControllers = 3
        deck.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)

        for (idx, meta) in metas.enumerated() {
            let tab = manager.open(meta, library: library)
            tab.session.updateViewport(ViewportState(offsetX: 0, offsetY: CGFloat((idx + 1) * 100), zoomScale: 1.2, pageIndex: 1))
            deck.sync(tabs: manager.tabs, activeTabID: manager.activeTabID, isWorkspaceVisible: true, library: library)
            XCTAssertLessThanOrEqual(deck.liveControllerCount, 3, "live VC count must stay capped by maxLiveControllers")
        }

        // Oldest tabs (0, 1, 2) were hibernated while recent tabs (3, 4, 5) remain mounted.
        XCTAssertEqual(deck.liveControllerCount, 3)
        XCTAssertNil(deck.controller(for: metas[0].id))
        XCTAssertNotNil(deck.controller(for: metas[5].id))

        // Switching back to hibernated tab 0 revives it cleanly with its exact saved viewport intact.
        manager.selectTab(id: metas[0].id)
        deck.sync(tabs: manager.tabs, activeTabID: manager.activeTabID, isWorkspaceVisible: true, library: library)
        XCTAssertNotNil(deck.controller(for: metas[0].id))
        XCTAssertEqual(deck.liveControllerCount, 3)
        XCTAssertEqual(manager.session(for: metas[0].id)?.savedViewport?.offsetY, 100)

        // Memory warning eviction keeps only the single active tab alive.
        deck.hibernateInactiveTabs(keepingAtMost: 1)
        XCTAssertEqual(deck.liveControllerCount, 1)
        XCTAssertNotNil(deck.controller(for: metas[0].id))

        deck.teardownAllTabs()
        XCTAssertEqual(deck.liveControllerCount, 0)
    }

    // MARK: 4. Background Async Persistence & Undo Memory Cap

    func testBackgroundAsyncSaveOrderingAndDeletedDocSafety() throws {
        let meta = try library.createDocument(title: "async-save", pdfData: makePDFData(),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "a.pdf", stagedSource: nil)
        let exp = expectation(description: "async saves complete")
        exp.expectedFulfillmentCount = 2

        var first = DocumentAnnotations()
        first.updatePage(0) { $0.strokes = [makeStroke(y: 40)] }

        var second = first
        second.updatePage(0) { $0.strokes.append(makeStroke(y: 90)) }

        library.saveAnnotationsAsync(first, for: meta.id) { err in
            XCTAssertNil(err)
            exp.fulfill()
        }
        library.saveAnnotationsAsync(second, for: meta.id) { err in
            XCTAssertNil(err)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)

        let loaded = library.loadAnnotations(for: meta.id)
        XCTAssertEqual(loaded.page(0).strokes.count, 2, "serial ioQueue must preserve final write order")

        // Deleting a document before a queued async save must not recreate its folder.
        library.delete(meta.id)
        let expDeleted = expectation(description: "deleted doc save ignored")
        library.saveAnnotationsAsync(second, for: meta.id) { err in
            XCTAssertNil(err)
            expDeleted.fulfill()
        }
        wait(for: [expDeleted], timeout: 2.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.folder(for: meta.id).path))
    }

    func testUndoStackCapsReplaceAllSnapshots() throws {
        let meta = try library.createDocument(title: "undo-cap", pdfData: makePDFData(),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "u.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())

        // Perform 14 full-document clear cycles (each adds 1 insert + 1 replaceAll).
        for i in 0..<14 {
            session.addStroke(makeStroke(y: Float(30 + i * 10)), page: 0)
            session.clearAllDocumentHandwriting(keepTapes: false)
        }
        XCTAssertTrue(session.canUndo)
        // Latest clear can still be undone in 1 step.
        session.undo()
        XCTAssertEqual(session.strokes(onPage: 0).count, 1)
    }

    // MARK: 5. Smart Power-Saving Projection Refresh Policy

    func testProjectionRefreshPolicyStaticPDFInteractiveHTMLAndFrozen() throws {
        // Frozen display is always paused (0 fps).
        let frozen = ProjectionRefreshPolicy.decide(
            isFrozen: true,
            smartPowerSaving: true,
            isShowingContentOnly: true,
            prefersContinuous: true,
            secondsSinceActivity: 0.0
        )
        XCTAssertEqual(frozen.mode, .paused)
        XCTAssertFalse(frozen.shouldCaptureImmediately)

        // Static PDF: full 24fps burst during scroll/ink, then 0fps paused when still!
        let pdfActive = ProjectionRefreshPolicy.decide(
            isFrozen: false,
            smartPowerSaving: true,
            isShowingContentOnly: true,
            prefersContinuous: false,
            secondsSinceActivity: 0.2
        )
        XCTAssertEqual(pdfActive.mode, .active)

        let pdfIdle = ProjectionRefreshPolicy.decide(
            isFrozen: false,
            smartPowerSaving: true,
            isShowingContentOnly: true,
            prefersContinuous: false,
            secondsSinceActivity: 1.2
        )
        XCTAssertEqual(pdfIdle.mode, .paused)

        // Interactive HTML courseware: 24fps while interacting, 6fps low-power pulse when idle!
        let htmlActive = ProjectionRefreshPolicy.decide(
            isFrozen: false,
            smartPowerSaving: true,
            isShowingContentOnly: true,
            prefersContinuous: true,
            secondsSinceActivity: 1.0
        )
        XCTAssertEqual(htmlActive.mode, .active)

        let htmlIdle = ProjectionRefreshPolicy.decide(
            isFrozen: false,
            smartPowerSaving: true,
            isShowingContentOnly: true,
            prefersContinuous: true,
            secondsSinceActivity: 3.5
        )
        XCTAssertEqual(htmlIdle.mode, .lowPowerPulse)

        // Disabling smartPowerSaving keeps full active 24fps continuously.
        let disabled = ProjectionRefreshPolicy.decide(
            isFrozen: false,
            smartPowerSaving: false,
            isShowingContentOnly: true,
            prefersContinuous: false,
            secondsSinceActivity: 30.0
        )
        XCTAssertEqual(disabled.mode, .active)

        // Persistence check on PresentationCenter.smartPowerSaving.
        let suite = "pres-power-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = PresentationCenter(defaults: defaults)
        XCTAssertTrue(center.smartPowerSaving)
        center.smartPowerSaving = false
        let reloaded = PresentationCenter(defaults: defaults)
        XCTAssertFalse(reloaded.smartPowerSaving)
    }

    // MARK: 6. Precise Eraser Local-Only Clipping & Anti-Lag Performance

    func testPreciseEraserLocalClippingKeepsFragmentsCompactAndFast() throws {
        // 1. A 600pt two-point straight segment cut in the middle must stay compact (~2 pts per piece,
        //    NOT bloated to ~590 densified 1pt points!).
        let longLine = InkStroke(
            id: UUID(),
            pen: .ballpoint,
            color: .ink,
            width: 2,
            smoothing: 0,
            points: [],
            tool: .pen,
            baked: [
                StrokeSample(point: CGPoint(x: 0, y: 50), radius: 1),
                StrokeSample(point: CGPoint(x: 600, y: 50), radius: 1),
            ]
        )
        let cache = StrokeGeometryCache()
        let firstCut = EraserEngine.erase([longLine], from: CGPoint(x: 300, y: 30), to: CGPoint(x: 300, y: 70),
                                          radius: 5, mode: .pixel, highlighterOnly: false, cache: cache)
        XCTAssertTrue(firstCut.changed)
        XCTAssertEqual(firstCut.strokes.count, 2)
        let left = try XCTUnwrap(firstCut.strokes[0].baked)
        let right = try XCTUnwrap(firstCut.strokes[1].baked)
        XCTAssertLessThan(left.map(\.point.x).max() ?? 999, 295)
        XCTAssertGreaterThan(right.map(\.point.x).min() ?? 0, 305)
        XCTAssertLessThanOrEqual(left.count + right.count, 8, "untouched spans must not explode into 1pt samples")

        // Second cut on the compact left fragment still splits accurately.
        let secondCut = EraserEngine.erase(firstCut.strokes, from: CGPoint(x: 120, y: 30), to: CGPoint(x: 120, y: 70),
                                           radius: 5, mode: .pixel, highlighterOnly: false, cache: cache)
        XCTAssertTrue(secondCut.changed)
        XCTAssertEqual(secondCut.strokes.count, 3)

        // 2. Dense canvas stress test: 120 strokes including large circles whose AABBs overlap the eraser path.
        var densePage: [InkStroke] = []
        for i in 0..<100 {
            let y = Float(40 + i * 7)
            let pts = (0...20).map { j in InkPoint(x: Float(j) * 20, y: y, force: 0.5, t: Float(j) / 240) }
            densePage.append(InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2,
                                       smoothing: 0.3, points: pts, tool: .pen))
        }
        for i in 0..<20 {
            densePage.append(InkStroke(
                id: UUID(), pen: .ballpoint, color: ToolSettings.palette[1], width: 2,
                smoothing: 0, points: [], tool: .pen,
                geometry: .circle(center: CGPoint(x: 200, y: CGFloat(150 + i * 25)), radius: 140)
            ))
        }

        let stressCache = StrokeGeometryCache()
        var working = densePage
        let start = CFAbsoluteTimeGetCurrent()
        for step in 0..<80 {
            let a = CGPoint(x: CGFloat(step * 4), y: 120)
            let b = CGPoint(x: CGFloat((step + 1) * 4), y: 124)
            let res = EraserEngine.erase(working, from: a, to: b, radius: 8,
                                         mode: .pixel, highlighterOnly: false, cache: stressCache)
            if res.changed {
                working = res.strokes
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        stressCache.prune(keeping: Set(working.map(\.id)))
        XCTAssertLessThan(elapsed, 2.0, "80 precise-erase sweeps on 120 strokes must finish briskly")
    }

    // MARK: 7. Viewing-Only Does Not Bump `modifiedAt` (Real Ink Required)

    func testViewingScrollingAndTapeToggleDoNotBumpModifiedAtUntilInkIsDrawn() throws {
        let olderDoc = try library.createDocument(title: "旧试卷", pdfData: makePDFData(pageCount: 3),
                                                  layout: .pdf, sourceKind: .pdfFile, sourceURL: "old.pdf", stagedSource: nil)
        Thread.sleep(forTimeInterval: 0.05)
        let newerDoc = try library.createDocument(title: "新讲义", pdfData: makePDFData(pageCount: 2),
                                                  layout: .pdf, sourceKind: .pdfFile, sourceURL: "new.pdf", stagedSource: nil)
        XCTAssertEqual(library.documents.first?.id, newerDoc.id)
        let originalOlderModifiedAt = try XCTUnwrap(library.documents.first(where: { $0.id == olderDoc.id })?.modifiedAt)

        // Open olderDoc and ONLY view it: scroll viewport, resize sticky note, switch paper style, save.
        let session = DocumentSession(meta: olderDoc, library: library, tool: ToolSettings())
        session.updateViewport(ViewportState(offsetX: 0, offsetY: 650, zoomScale: 1.25, pageIndex: 2))
        session.setScratchpadFrame(CGRect(x: 40, y: 60, width: 320, height: 260))
        session.scratchpadPaper = .dot
        session.saveNow()

        // Viewport must be persisted on disk, while `modifiedAt` and Library ordering stay UNCHANGED!
        let savedViewport = library.loadAnnotations(for: olderDoc.id).viewport
        XCTAssertEqual(savedViewport?.pageIndex, 2)
        XCTAssertEqual(library.documents.first?.id, newerDoc.id, "just viewing olderDoc must not bump it above newerDoc")
        let afterViewingModifiedAt = try XCTUnwrap(library.documents.first(where: { $0.id == olderDoc.id })?.modifiedAt)
        XCTAssertEqual(afterViewingModifiedAt, originalOlderModifiedAt)

        // Now actually draw an ink stroke on olderDoc -> `modifiedAt` updates and olderDoc becomes latest!
        Thread.sleep(forTimeInterval: 0.05)
        session.addStroke(makeStroke(y: 120), page: 0)
        session.saveNow()

        XCTAssertEqual(library.documents.first?.id, olderDoc.id, "real handwriting must update modifiedAt to top")
        let afterInkModifiedAt = try XCTUnwrap(library.documents.first(where: { $0.id == olderDoc.id })?.modifiedAt)
        XCTAssertGreaterThan(afterInkModifiedAt, originalOlderModifiedAt)
    }
}
