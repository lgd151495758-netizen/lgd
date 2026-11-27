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

    // MARK: 2. No Multi-Touch Tap Undo/Redo Gestures Attached (Prevents Accidental Palm Undo)

    @MainActor
    func testCanvasesDoNotAttachMultiTouchTapUndoGestures() throws {
        let meta = try library.createDocument(title: "gesture-test", pdfData: makePDFData(),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "g.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())

        let pdfEditor = EditorViewController(session: session)
        pdfEditor.loadViewIfNeeded()
        let pdfMultiFingerTaps = (pdfEditor.view.gestureRecognizers ?? [])
            .compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTouchesRequired >= 2 }
        XCTAssertTrue(pdfMultiFingerTaps.isEmpty, "PDF canvas must not attach multi-finger tap undo/redo gestures")

        let scratchpad = ScratchpadCanvasView(session: session)
        let scratchMultiFingerTaps = (scratchpad.gestureRecognizers ?? [])
            .compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTouchesRequired >= 2 }
        XCTAssertTrue(scratchMultiFingerTaps.isEmpty, "Scratchpad canvas must not attach multi-finger tap undo/redo gestures")
    }

    @MainActor
    func testPinchToZoomIsNeverBlockedOrDeadlockedByInkOrOverlayRecognizers() throws {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let pinch = UIPinchGestureRecognizer()
        scrollView.addGestureRecognizer(pinch)
        let scrollPan = scrollView.panGestureRecognizer
        let plainTap = UITapGestureRecognizer()

        XCTAssertTrue(InkGestureRecognizer.isPinchGesture(pinch))
        XCTAssertFalse(InkGestureRecognizer.isPinchGesture(scrollPan))
        XCTAssertTrue(InkGestureRecognizer.isScrollOrZoomGesture(pinch))
        XCTAssertTrue(InkGestureRecognizer.isScrollOrZoomGesture(scrollPan))
        XCTAssertFalse(InkGestureRecognizer.isScrollOrZoomGesture(plainTap))

        let ink = InkGestureRecognizer(target: nil, action: nil)
        // Idle in Pencil mode: never blocks pinch or scroll.
        ink.allowsFingerDrawing = false
        XCTAssertFalse(ink.canPrevent(pinch), "Idle ink recognizer must never prevent pinch-to-zoom")
        XCTAssertFalse(ink.canPrevent(scrollPan), "Idle ink recognizer must never prevent scroll pan")

        // Finger Drawing mode (2-finger scroll pan): never kills 2-finger pinch or 2-finger scroll,
        // while still blocking 1-finger pan/tap.
        ink.allowsFingerDrawing = true
        scrollPan.minimumNumberOfTouches = 2
        XCTAssertFalse(ink.canPrevent(pinch), "Ink recognizer must never kill pinch-to-zoom in Finger Drawing mode")
        XCTAssertFalse(ink.canPrevent(scrollPan), "Ink recognizer must never kill 2-finger scroll in Finger Drawing mode")
        XCTAssertTrue(ink.canPrevent(plainTap), "Ink recognizer still prevents 1-finger taps in Finger Drawing mode")

        // Verify EditorViewController delegate never deadlocks pinch, AND strictly prevents
        // simultaneous scrollView pan during Apple Pencil mode (critical for palm rejection!).
        let pdfMeta = try library.createDocument(title: "pinch-pdf", pdfData: makePDFData(),
                                                 layout: .pdf, sourceKind: .pdfFile, sourceURL: "p.pdf", stagedSource: nil)
        let pdfSession = DocumentSession(meta: pdfMeta, library: library, tool: ToolSettings())
        let pdfEditor = EditorViewController(session: pdfSession)
        pdfEditor.loadViewIfNeeded()
        let pdfInk = try XCTUnwrap((pdfEditor.view.gestureRecognizers ?? []).first { $0 is InkGestureRecognizer })

        // Simulate a newly-created PDFView pinch recognizer whose default allowedTouchTypes still includes `.pencil`.
        let simulatedPDFPinch = UIPinchGestureRecognizer()
        simulatedPDFPinch.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
        ]
        pdfEditor.pdfView.addGestureRecognizer(simulatedPDFPinch)
        XCTAssertFalse(
            pdfEditor.gestureRecognizer(pdfInk, shouldBeRequiredToFailBy: simulatedPDFPinch),
            "PDF pinch recognizer must never wait for Pencil-only inkRecognizer to fail"
        )
        // In Apple Pencil mode, inkRecognizer must NOT run simultaneously with scroll pan (palm rejection!).
        scrollPan.minimumNumberOfTouches = 1
        XCTAssertFalse(
            pdfEditor.gestureRecognizer(pdfInk, shouldRecognizeSimultaneouslyWith: scrollPan),
            "Apple Pencil writing must NEVER run simultaneously with scrollView pan"
        )
        // In Finger Drawing mode (with no Pencil active), 2-finger pinch can coexist until 2nd finger cancels ink.
        pdfSession.tool.fingerDrawing = true
        XCTAssertTrue(
            pdfEditor.gestureRecognizer(pdfInk, shouldRecognizeSimultaneouslyWith: simulatedPDFPinch),
            "Finger Drawing mode allows 2-finger pinch to start cleanly"
        )

        // Verify GeometryToolOverlayView recognizes simultaneously with pinch gestures (not 1-finger pan).
        let overlay = GeometryToolOverlayView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let overlayRecognizers = overlay.gestureRecognizers ?? []
        XCTAssertFalse(overlayRecognizers.isEmpty)
        for rec in overlayRecognizers {
            XCTAssertTrue(overlay.gestureRecognizer(rec, shouldRecognizeSimultaneouslyWith: pinch))
            XCTAssertFalse(overlay.gestureRecognizer(rec, shouldRecognizeSimultaneouslyWith: scrollPan))
        }
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
        // ISO8601 dates serialize at whole-second precision; backdate `olderDoc` by 10s so ordering is deterministic.
        var backdated = olderDoc
        backdated.modifiedAt = Date().addingTimeInterval(-10)
        try LibraryStore.encoder.encode(backdated).write(to: library.metaURL(for: olderDoc.id), options: .atomic)
        let newerDoc = try library.createDocument(title: "新讲义", pdfData: makePDFData(pageCount: 2),
                                                  layout: .pdf, sourceKind: .pdfFile, sourceURL: "new.pdf", stagedSource: nil)
        XCTAssertEqual(library.documents.first?.id, newerDoc.id)
        let originalOlderModifiedAt = try XCTUnwrap(library.documents.first(where: { $0.id == olderDoc.id })?.modifiedAt)

        // Open olderDoc and ONLY view it: scroll viewport, resize sticky note, switch paper style, save.
        let session = DocumentSession(meta: backdated, library: library, tool: ToolSettings())
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

        // Now actually draw an ink stroke on olderDoc -> `modifiedAt` updates beyond newerDoc's timestamp!
        Thread.sleep(forTimeInterval: 1.1)
        session.addStroke(makeStroke(y: 120), page: 0)
        session.saveNow()

        XCTAssertEqual(library.documents.first?.id, olderDoc.id, "real handwriting must update modifiedAt to top")
        let afterInkModifiedAt = try XCTUnwrap(library.documents.first(where: { $0.id == olderDoc.id })?.modifiedAt)
        XCTAssertGreaterThan(afterInkModifiedAt, originalOlderModifiedAt)
    }

    // MARK: 8. Apple Pencil Double-Tap Eraser Auto-Returns to Pen on Lift

    func testPencilDoubleTapAutoReturnsToPenOnLiftButManualEraserStays() throws {
        let meta = try library.createDocument(title: "double-tap", pdfData: makePDFData(),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "dt.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        XCTAssertEqual(session.tool.kind, .pen)
        XCTAssertFalse(session.autoReturnToPenAfterErase)

        // 1. Apple Pencil double-tap switches to eraser and arms one-shot auto-return.
        session.handlePencilDoubleTap(.switchEraser)
        XCTAssertEqual(session.tool.kind, .eraser)
        XCTAssertTrue(session.autoReturnToPenAfterErase)

        // Lifting the pen tip after erasing automatically switches straight back to `.pen`.
        session.didFinishEraseStroke()
        XCTAssertEqual(session.tool.kind, .pen)
        XCTAssertFalse(session.autoReturnToPenAfterErase)

        // 2. Also works when Apple Pencil system preference is `.switchPrevious` landing on `.eraser`.
        session.handlePencilDoubleTap(.switchPrevious)
        XCTAssertEqual(session.tool.kind, .eraser)
        XCTAssertTrue(session.autoReturnToPenAfterErase)
        session.didFinishEraseStroke()
        XCTAssertEqual(session.tool.kind, .pen)
        XCTAssertFalse(session.autoReturnToPenAfterErase)

        // 3. Double-tapping a second time before erasing cancels auto-return cleanly.
        session.handlePencilDoubleTap(.switchEraser)
        XCTAssertTrue(session.autoReturnToPenAfterErase)
        session.handlePencilDoubleTap(.switchEraser)
        XCTAssertEqual(session.tool.kind, .pen)
        XCTAssertFalse(session.autoReturnToPenAfterErase)

        // 4. Manually tapping the Eraser button in the toolbar stays in eraser mode after lifting.
        session.selectToolManually(.eraser)
        XCTAssertEqual(session.tool.kind, .eraser)
        XCTAssertFalse(session.autoReturnToPenAfterErase)
        session.didFinishEraseStroke()
        XCTAssertEqual(session.tool.kind, .eraser, "manual eraser selection must not auto-deselect")
    }

    // MARK: 9. Compact 4 Quick Colors + Custom Color Palette

    func testQuickFourColorsCustomizationPersistenceAndReset() throws {
        let suite = "quick-colors-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var tool = ToolSettings()
        XCTAssertEqual(tool.resolvedQuickColors.count, 4)
        XCTAssertEqual(tool.resolvedQuickColors, ToolSettings.defaultQuickColors)
        XCTAssertEqual(ToolSettings.extendedPalette.count, 16)

        // Replace slot 3 with chalk white and verify active color + persistence.
        let chalkWhite = RGBAColor(0.97, 0.97, 0.99)
        tool.setQuickColor(chalkWhite, at: 3)
        XCTAssertEqual(tool.color, chalkWhite)
        XCTAssertEqual(tool.resolvedQuickColors[3], chalkWhite)

        tool.save(to: defaults)
        var reloaded = ToolSettings.load(from: defaults)
        XCTAssertEqual(reloaded.resolvedQuickColors[3], chalkWhite)
        XCTAssertEqual(reloaded.color, chalkWhite)

        reloaded.resetQuickColorsToDefault()
        XCTAssertEqual(reloaded.resolvedQuickColors, ToolSettings.defaultQuickColors)
    }

    // MARK: 10. P1 Classroom Projection Privacy, Geometry Mirror Toggle & Capture Scale

    func testPresentationFreezeSafeClearContentSourceGeometryToggleAndCaptureScale() throws {
        let suite = "presentation-p1-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        final class MockSource: PresentationContentSource {
            let presentationView = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
            func presentationViewportDidChange() {}
            func capturePresentationFrame(completion: @escaping (UIImage?, CGSize) -> Void) {
                completion(nil, .zero)
            }
        }

        let center = PresentationCenter(defaults: defaults)
        XCTAssertTrue(center.showGeometryToolsOnExternalDisplay, "geometry tools should mirror to big screen by default")

        center.showGeometryToolsOnExternalDisplay = false
        let reloadedCenter = PresentationCenter(defaults: defaults)
        XCTAssertFalse(reloadedCenter.showGeometryToolsOnExternalDisplay)

        // Freezing and then returning to the Library (`clearContentSource`) MUST preserve `isFrozen = true`
        // so the teacher can open answer keys in the Library without exposing them to students.
        let source = MockSource()
        center.setContentSource(source)
        center.isFrozen = true
        center.clearContentSource(source)
        XCTAssertTrue(center.isFrozen, "returning to Library while frozen must never auto-unfreeze the projector")

        // Adaptive PDF capture scale stays strictly bounded inside [1.0, 2.0].
        let scaleFor1000pt = center.preferredPDFCaptureScale(forCaptureWidth: 1000, screenScale: 2.0)
        XCTAssertGreaterThanOrEqual(scaleFor1000pt, 1.0)
        XCTAssertLessThanOrEqual(scaleFor1000pt, 2.0)
        XCTAssertEqual(scaleFor1000pt, 1.92, accuracy: 0.02)

        let scaleForWide = center.preferredPDFCaptureScale(forCaptureWidth: 2400, screenScale: 2.0)
        XCTAssertEqual(scaleForWide, 1.0, accuracy: 0.001)

        let scaleForNarrow = center.preferredPDFCaptureScale(forCaptureWidth: 500, screenScale: 2.0)
        XCTAssertEqual(scaleForNarrow, 2.0, accuracy: 0.001)
    }

    // MARK: 11. Independent Pen vs Shape Styles & Bold Width Preset

    func testIndependentPenAndShapeStylesAndQuickColorIsolation() throws {
        let suite = "pen-vs-shape-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ToolSettings.widthPresets.count, 4)
        XCTAssertTrue(ToolSettings.widthPresets.contains(4.6))

        var tool = ToolSettings()
        let red = RGBAColor(0.80, 0.16, 0.16)
        let blue = RGBAColor(0.10, 0.27, 0.66)

        // Configure Pen to classic black 1.8pt solid.
        tool.kind = .pen
        tool.color = .ink
        tool.width = 1.8
        tool.lineStyle = .solid

        // Switch to Shape and customize to dashed 4.6pt red auxiliary lines.
        tool.select(.shape)
        tool.resolvedShapeColor = red
        tool.resolvedShapeWidth = 4.6
        tool.resolvedShapeLineStyle = .dashed

        XCTAssertEqual(tool.activeStrokeColor, red)
        XCTAssertEqual(tool.activeStrokeWidth, 4.6)
        XCTAssertEqual(tool.activeLineStyle, .dashed)

        // Pinning a quick color while in Shape mode (`applyToPen: false`) must NOT alter Pen's color.
        tool.setQuickColor(blue, at: 2, applyToPen: false)
        XCTAssertEqual(tool.resolvedQuickColors[2], blue)
        XCTAssertEqual(tool.color, .ink)

        // Switching back to Pen restores untouched handwriting settings.
        tool.select(.pen)
        XCTAssertEqual(tool.activeStrokeColor, .ink)
        XCTAssertEqual(tool.activeStrokeWidth, 1.8)
        XCTAssertEqual(tool.activeLineStyle, .solid)

        // Persistence round-trip preserves both Pen and Shape styles independently.
        tool.save(to: defaults)
        var reloaded = ToolSettings.load(from: defaults)
        XCTAssertEqual(reloaded.color, .ink)
        XCTAssertEqual(reloaded.width, 1.8)
        XCTAssertEqual(reloaded.lineStyle, .solid)
        reloaded.select(.shape)
        XCTAssertEqual(reloaded.activeStrokeColor, red)
        XCTAssertEqual(reloaded.activeStrokeWidth, 4.6)
        XCTAssertEqual(reloaded.activeLineStyle, .dashed)
    }

    // MARK: 12. Pencil Color-Palette Action & O(1) Refine-Stroke Undo Patching

    func testPencilDoubleTapShowColorPaletteAndRefineStrokeUndoPatch() throws {
        let meta = try library.createDocument(title: "refine-palette", pdfData: makePDFData(),
                                              layout: .pdf, sourceKind: .pdfFile, sourceURL: "rp.pdf", stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        let initialReq = session.colorPaletteRequestID

        session.handlePencilDoubleTap(.showColorPalette)
        XCTAssertEqual(session.colorPaletteRequestID, initialReq &+ 1)
        XCTAssertEqual(session.tool.kind, .pen, "showColorPalette must not switch away from pen")

        session.handlePencilDoubleTap(.showInkAttributes)
        XCTAssertEqual(session.colorPaletteRequestID, initialReq &+ 2)

        // Add a stroke and refine its points with updated Pencil force values.
        let original = makeStroke(y: 100)
        session.addStroke(original, page: 0)
        var refinedPoints = original.points
        refinedPoints[0].force = 0.92
        refinedPoints[1].force = 0.88
        session.refineStroke(id: original.id, page: 0, points: refinedPoints)

        XCTAssertEqual(session.strokes(onPage: 0).first?.points[0].force ?? 0, 0.92, accuracy: 0.001)

        // Undo removes the stroke; Redo must restore the REFINED force points from the patched undo entry.
        session.undo()
        XCTAssertTrue(session.strokes(onPage: 0).isEmpty)
        session.redo()
        XCTAssertEqual(session.strokes(onPage: 0).first?.points[0].force ?? 0, 0.92, accuracy: 0.001)
    }

    // MARK: 13. Scratchpad Live Overlay Translates Projected Compass & Protractor

    func testScratchpadLiveOverlayTranslatesProjectedCompassAndProtractor() {
        var compass = CompassState()
        compass.center = CGPoint(x: 120, y: 150)
        compass.radius = 80
        var compassOverlay = ScratchpadLiveOverlay()
        compassOverlay.geometryAid = .compass(compass, sweep: nil, strokeColor: RGBAColor.ink.cgColor)
        XCTAssertFalse(compassOverlay.isEmpty)

        let shiftedCompass = compassOverlay.translated(by: CGPoint(x: 40, y: 65))
        if case let .compass(moved, _, _) = shiftedCompass.geometryAid {
            XCTAssertEqual(moved.center.x, 160, accuracy: 0.001)
            XCTAssertEqual(moved.center.y, 215, accuracy: 0.001)
        } else {
            XCTFail("Expected translated compass geometry aid")
        }

        var protractor = ProtractorState()
        protractor.center = CGPoint(x: 200, y: 240)
        var protractorOverlay = ScratchpadLiveOverlay()
        protractorOverlay.geometryAid = .protractor(protractor)
        XCTAssertFalse(protractorOverlay.isEmpty)

        let shiftedProtractor = protractorOverlay.translated(by: CGPoint(x: -30, y: 50))
        if case let .protractor(moved) = shiftedProtractor.geometryAid {
            XCTAssertEqual(moved.center.x, 170, accuracy: 0.001)
            XCTAssertEqual(moved.center.y, 290, accuracy: 0.001)
        } else {
            XCTFail("Expected translated protractor geometry aid")
        }
    }
}
