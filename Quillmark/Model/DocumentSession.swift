import Combine
import Foundation
import PDFKit
import UIKit

/// Editing state for one open document: annotations, tool, undo/redo and autosave.
/// Every change goes through a `Command`, so undo/redo is the inverse command.
final class DocumentSession: ObservableObject {
    enum Command: Equatable {
        case insert(page: Int, stroke: InkStroke, index: Int)
        case remove(page: Int, stroke: InkStroke, index: Int)
        /// Replaces all strokes of a single page (eraser, lasso, shape edit, clear page).
        case replace(page: Int, before: [InkStroke], after: [InkStroke])
        /// Replaces the entire annotations snapshot as one undoable step (clear all document handwriting).
        case replaceAll(before: DocumentAnnotations, after: DocumentAnnotations)

        var inverse: Command {
            switch self {
            case let .insert(page, stroke, index): return .remove(page: page, stroke: stroke, index: index)
            case let .remove(page, stroke, index): return .insert(page: page, stroke: stroke, index: index)
            case let .replace(page, before, after): return .replace(page: page, before: after, after: before)
            case let .replaceAll(before, after): return .replaceAll(before: after, after: before)
            }
        }

        var page: Int? {
            switch self {
            case let .insert(page, _, _), let .remove(page, _, _), let .replace(page, _, _): return page
            case .replaceAll: return nil
            }
        }
    }

    let meta: DocumentMeta
    private(set) var pdfDocument: PDFDocument?

    @Published var tool: ToolSettings {
        didSet {
            tool.save()
            if tool.kind != .eraser && autoReturnToPenAfterErase {
                autoReturnToPenAfterErase = false
            }
        }
    }
    /// Set to `true` only when entering `.eraser` via Apple Pencil double-tap so lifting the pen
    /// tip after erasing automatically switches back to `.pen`.
    @Published private(set) var autoReturnToPenAfterErase = false
    @Published var geometryAid: GeometryAid = .none
    @Published var isScratchpadOpen: Bool = false
    @Published var scratchpadSplitMode: ScratchpadSplitMode = .floating
    @Published private(set) var scratchpadPageIndex: Int = 0
    @Published private(set) var scratchpadPageCount: Int = 1
    @Published var scratchpadPaper: ScratchpadPaperStyle = .grid {
        didSet {
            guard scratchpadPaper != oldValue else { return }
            annotations.scratchpadPaper = scratchpadPaper
            scheduleSave(contentEdited: false)
        }
    }
    var savedScratchpadFrame: CGRect? { annotations.scratchpadFrame }
    var savedViewport: ViewportState? { annotations.viewport }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Zero-based currently visible main page index (used by multi-page PDF documents).
    @Published var activeDocumentPageIndex: Int = 0
    @Published private(set) var pdfPageCount: Int = 0
    /// Multi-class annotation layers for teaching the same document across different classes.
    @Published private(set) var layers: [InkLayer] = []
    @Published private(set) var activeLayerID: UUID = DocumentAnnotations.implicitDefaultLayerID
    /// Set to `true` when `annotations.json` could not be decoded or came from a newer app version;
    /// blocks all disk writes until explicitly acknowledged so original notes are NEVER overwritten.
    @Published private(set) var isWriteProtected = false
    /// Non-nil banner message explaining why write protection was engaged on load.
    @Published private(set) var loadErrorMessage: String?
    /// Non-nil banner message when saving annotations to disk failed (e.g. storage full).
    @Published var saveErrorMessage: String?
    /// Incremented when Apple Pencil double-tap preference is `.showColorPalette`.
    @Published var colorPaletteRequestID: Int = 0

    /// Called after the strokes of a single page changed (page index; negative values are scratchpad pages).
    var pageDidChange: ((Int) -> Void)?
    /// Called after a multi-page command (`replaceAll`) or layer switch changed multiple pages at once.
    var allPagesDidChange: (() -> Void)?
    /// Called when the user selects a target page from the PDF page navigator popover.
    var requestJumpToPDFPage: ((Int) -> Void)?
    /// Called after a new blank page is inserted into the PDF on disk (passes newly inserted page index).
    var pdfDocumentDidReload: ((Int) -> Void)?

    var activeLayerName: String {
        layers.first(where: { $0.id == activeLayerID })?.name ?? annotations.activeLayerName
    }

    var hasMultipleLayers: Bool {
        layers.count > 1
    }

    /// Negative page ID for the currently active scratchpad page (`-1, -2, ...`).
    var currentScratchpadPageID: Int {
        DocumentAnnotations.scratchpadPageID(scratchpadPageIndex)
    }

    private(set) var annotations: DocumentAnnotations
    private var undoStack: [Command] = []
    private var redoStack: [Command] = []
    private let library: LibraryStore
    private var saveWork: DispatchWorkItem?
    private var retrySaveWork: DispatchWorkItem?
    private var hasUnsavedChanges = false
    /// Only becomes `true` when real ink/annotation/page edits occur (pure viewing/scrolling/zoom
    /// never bumps `meta.modifiedAt` in the Library list).
    private var hasPendingContentEdit = false
    private var saveGeneration: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private let undoLimit = 500
    /// Caps full-document `replaceAll` snapshots in `undoStack` to keep memory lean on 4GB iPads.
    private let maxReplaceAllSnapshots = 10

    init(meta: DocumentMeta, library: LibraryStore, tool: ToolSettings = ToolSettings.load()) {
        self.meta = meta
        self.library = library
        self.tool = tool
        let loadResult = library.loadAnnotationsResult(for: meta.id)
        let loaded: DocumentAnnotations
        switch loadResult {
        case .loaded(let value):
            loaded = value
        case .missing:
            loaded = DocumentAnnotations()
        case let .unsupportedVersion(version, _):
            loaded = DocumentAnnotations()
            self.isWriteProtected = true
            self.loadErrorMessage = "此文档批注格式（v\(version)）高于当前羽签版本，已开启只读保护以防覆盖原笔记，请先更新羽签。"
        case let .corrupted(_, quarantinedURL):
            loaded = DocumentAnnotations()
            self.isWriteProtected = true
            let backupName = quarantinedURL?.lastPathComponent ?? "备份副本"
            self.loadErrorMessage = "批注文件读取异常，原文件已备份为 \(backupName)，已暂停自动保存以防覆盖。可导入备份恢复，或点右侧按钮重新开始记录。"
        }
        self.annotations = loaded
        self.scratchpadPageCount = loaded.resolvedScratchpadPageCount
        self.scratchpadPaper = loaded.scratchpadPaper ?? .grid
        let pdf = PDFDocument(url: library.pdfURL(for: meta.id))
        self.pdfDocument = pdf
        self.pdfPageCount = pdf?.pageCount ?? 0
        self.layers = loaded.resolvedLayers
        self.activeLayerID = loaded.resolvedActiveLayerID
        let observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            self?.saveNow()
        }
        observers.append(observer)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func strokes(onPage page: Int) -> [InkStroke] {
        annotations.page(page).strokes
    }

    func addStroke(_ stroke: InkStroke, page: Int) {
        perform(.insert(page: page, stroke: stroke, index: strokes(onPage: page).count))
    }

    /// Commits the result of an eraser gesture as one undoable step.
    func replaceStrokes(onPage page: Int, before: [InkStroke], after: [InkStroke]) {
        guard before != after else { return }
        perform(.replace(page: page, before: before, after: after))
    }

    /// Flips a single cover tape between hidden (opaque) and revealed (translucent) without
    /// adding an undo entry, so tapping answers during a lecture never disturbs ink undo.
    func toggleTape(id: UUID, page: Int) {
        var changed = false
        annotations.updatePage(page) { pageAnnotations in
            if let index = pageAnnotations.strokes.firstIndex(where: { $0.id == id && $0.isTape }) {
                pageAnnotations.strokes[index].revealed = !pageAnnotations.strokes[index].isRevealed
                changed = true
            }
        }
        guard changed else { return }
        pageDidChange?(page)
        scheduleSave(contentEdited: false)
    }

    /// Covers (`revealed == false`) or reveals (`revealed == true`) every tape on `page`
    /// (or across all annotated pages when `page == nil`).
    func setAllTapesRevealed(_ revealed: Bool, page: Int? = nil) {
        let targetPages: [Int]
        if let page {
            targetPages = [page]
        } else {
            let mainPages = annotations.pages.keys.compactMap(Int.init).sorted()
            let scratchIDs = (0..<scratchpadPageCount).map { DocumentAnnotations.scratchpadPageID($0) }
            targetPages = mainPages + scratchIDs
        }
        var changedPages: [Int] = []
        for p in targetPages {
            var changed = false
            annotations.updatePage(p) { pageAnnotations in
                for i in pageAnnotations.strokes.indices where pageAnnotations.strokes[i].isTape {
                    if pageAnnotations.strokes[i].isRevealed != revealed {
                        pageAnnotations.strokes[i].revealed = revealed
                        changed = true
                    }
                }
            }
            if changed { changedPages.append(p) }
        }
        guard !changedPages.isEmpty else { return }
        for p in changedPages {
            pageDidChange?(p)
        }
        scheduleSave(contentEdited: false)
    }

    // MARK: Scratchpad Pages

    func toggleScratchpad() {
        isScratchpadOpen.toggle()
    }

    func toggleScratchpadSplitMode() {
        scratchpadSplitMode = (scratchpadSplitMode == .floating) ? .full : .floating
    }

    func setScratchpadFrame(_ frame: CGRect) {
        guard annotations.scratchpadFrame != frame else { return }
        annotations.scratchpadFrame = frame
        scheduleSave(contentEdited: false)
    }

    func updateViewport(_ viewport: ViewportState) {
        guard viewport.isValid else { return }
        if let existing = annotations.viewport, existing.isApproximatelyEqual(to: viewport) {
            return
        }
        annotations.viewport = viewport
        scheduleSave(contentEdited: false)
    }

    /// Reloads annotations from disk (e.g. after clearing ink from the Library while a tab stays open).
    func reloadAnnotationsFromDisk() {
        saveWork?.cancel()
        saveWork = nil
        retrySaveWork?.cancel()
        retrySaveWork = nil
        hasUnsavedChanges = false
        hasPendingContentEdit = false
        saveErrorMessage = nil
        let loaded: DocumentAnnotations
        switch library.loadAnnotationsResult(for: meta.id) {
        case .loaded(let value):
            loaded = value
            isWriteProtected = false
            loadErrorMessage = nil
        case .missing:
            loaded = DocumentAnnotations()
            isWriteProtected = false
            loadErrorMessage = nil
        case let .unsupportedVersion(version, _):
            loaded = DocumentAnnotations()
            isWriteProtected = true
            loadErrorMessage = "此文档批注格式（v\(version)）高于当前羽签版本，已开启只读保护以防覆盖原笔记，请先更新羽签。"
        case let .corrupted(_, quarantinedURL):
            loaded = DocumentAnnotations()
            isWriteProtected = true
            let backupName = quarantinedURL?.lastPathComponent ?? "备份副本"
            loadErrorMessage = "批注文件读取异常，原文件已备份为 \(backupName)，已暂停自动保存以防覆盖。可导入备份恢复，或点右侧按钮重新开始记录。"
        }
        annotations = loaded
        scratchpadPageCount = loaded.resolvedScratchpadPageCount
        if scratchpadPageIndex >= scratchpadPageCount {
            scratchpadPageIndex = max(0, scratchpadPageCount - 1)
        }
        if let paper = loaded.scratchpadPaper {
            scratchpadPaper = paper
        }
        refreshPublishedLayers()
        undoStack.removeAll()
        redoStack.removeAll()
        updateFlags()
        if let allPagesDidChange {
            allPagesDidChange()
        } else {
            pageDidChange?(0)
        }
    }

    // MARK: Multi-Class Annotation Layers

    func switchLayer(to id: UUID) {
        guard id != activeLayerID else { return }
        guard annotations.switchToLayer(id) else { return }
        applyLayerChange(contentEdited: false)
    }

    @discardableResult
    func createLayer(name: String, template: DocumentAnnotations.NewLayerTemplate) -> InkLayer {
        let created = annotations.createLayer(name: name, template: template)
        applyLayerChange(contentEdited: true)
        return created
    }

    func renameLayer(id: UUID, to newName: String) {
        guard annotations.renameLayer(id, to: newName) else { return }
        refreshPublishedLayers()
        hasUnsavedChanges = true
        hasPendingContentEdit = true
        saveNow()
    }

    func deleteLayer(id: UUID) {
        guard annotations.deleteLayer(id) else { return }
        applyLayerChange(contentEdited: true)
    }

    private func applyLayerChange(contentEdited: Bool) {
        scratchpadPageCount = annotations.resolvedScratchpadPageCount
        scratchpadPageIndex = min(max(0, scratchpadPageIndex), max(0, scratchpadPageCount - 1))
        refreshPublishedLayers()
        undoStack.removeAll()
        redoStack.removeAll()
        updateFlags()
        if let allPagesDidChange {
            allPagesDidChange()
        } else {
            pageDidChange?(0)
        }
        hasUnsavedChanges = true
        if contentEdited {
            hasPendingContentEdit = true
        }
        saveNow()
    }

    private func refreshPublishedLayers() {
        layers = annotations.resolvedLayers
        activeLayerID = annotations.resolvedActiveLayerID
    }

    // MARK: PDF Navigation & Blank Page Insertion

    func jumpToPDFPage(_ index: Int) {
        guard pdfPageCount > 0 else { return }
        let clamped = min(max(0, index), pdfPageCount - 1)
        activeDocumentPageIndex = clamped
        requestJumpToPDFPage?(clamped)
    }

    /// Inserts a crisp vector blank page (`blank`/`grid`/`dot`/`graph`) directly after `pageIndex`
    /// in the underlying PDF, shifting annotation page indices across every class layer cleanly.
    @discardableResult
    func insertBlankPDFPage(after pageIndex: Int, paper: ScratchpadPaperStyle) throws -> Int {
        guard let doc = pdfDocument, doc.pageCount > 0 else {
            throw ImportError.invalidPDF
        }
        let clampedAnchor = min(max(0, pageIndex), doc.pageCount - 1)
        let insertIndex = clampedAnchor + 1
        let referenceSize: CGSize
        if let refPage = doc.page(at: clampedAnchor) {
            let box = refPage.bounds(for: .cropBox)
            let rot = ((refPage.rotation % 360) + 360) % 360
            referenceSize = (rot == 90 || rot == 270)
                ? CGSize(width: box.height, height: box.width)
                : box.size
        } else {
            referenceSize = NotebookOrientation.portraitA4.pageSize
        }

        guard let blankPage = BlankNotebookService.makeSingleBlankPage(size: referenceSize, paper: paper) else {
            throw ImportError.invalidPDF
        }

        doc.insert(blankPage, at: insertIndex)
        guard let updatedData = doc.dataRepresentation() else {
            doc.removePage(at: insertIndex)
            throw ImportError.invalidPDF
        }
        let pdfURL = library.pdfURL(for: meta.id)
        try updatedData.write(to: pdfURL, options: .atomic)

        // Reload a fresh PDFDocument from disk so PDFView renders cleanly with no stale page caches.
        let reloaded = PDFDocument(url: pdfURL) ?? doc
        pdfDocument = reloaded
        pdfPageCount = reloaded.pageCount

        annotations.shiftPageIndicesForInsertedPage(at: insertIndex)
        refreshPublishedLayers()
        undoStack.removeAll()
        redoStack.removeAll()
        updateFlags()
        activeDocumentPageIndex = insertIndex
        hasUnsavedChanges = true
        hasPendingContentEdit = true
        saveNow()
        pdfDocumentDidReload?(insertIndex)
        return insertIndex
    }

    func selectScratchpadPage(_ index: Int) {
        let clamped = min(max(0, index), max(0, scratchpadPageCount - 1))
        guard clamped != scratchpadPageIndex else { return }
        scratchpadPageIndex = clamped
    }

    func addScratchpadPage() {
        let newIdx = annotations.appendScratchpadPage()
        scratchpadPageCount = annotations.resolvedScratchpadPageCount
        scratchpadPageIndex = newIdx
        scheduleSave(contentEdited: false)
    }

    func clearCurrentScratchpadPage() {
        let pageID = currentScratchpadPageID
        let current = strokes(onPage: pageID)
        guard !current.isEmpty else { return }
        replaceStrokes(onPage: pageID, before: current, after: [])
    }

    /// Clears handwriting on a single page as one undoable step. When `keepTapes` is `true`,
    /// Cover Tapes remain on the page and reset to covered (`revealed = false`).
    func clearHandwriting(onPage page: Int, keepTapes: Bool) {
        let before = strokes(onPage: page)
        guard !before.isEmpty else { return }
        let after: [InkStroke]
        if keepTapes {
            after = before.compactMap { stroke in
                guard stroke.isTape else { return nil }
                var covered = stroke
                covered.revealed = false
                return covered
            }
        } else {
            after = []
        }
        replaceStrokes(onPage: page, before: before, after: after)
    }

    /// Refreshes published layer stroke counts (call before opening the Layers popover).
    func refreshLayerSummaries() {
        annotations.syncActiveLayerFromTopLevel()
        refreshPublishedLayers()
    }

    /// Clears handwriting across all main document pages as one undoable step (preserving sticky-note pages).
    /// When `keepTapes` is `true`, Cover Tapes are preserved and reset to covered (`revealed = false`).
    func clearAllDocumentHandwriting(keepTapes: Bool) {
        annotations.syncActiveLayerFromTopLevel()
        let before = annotations
        var after = annotations
        var updatedPages: [String: PageAnnotations] = [:]
        if keepTapes {
            for (key, page) in before.pages {
                let kept: [InkStroke] = page.strokes.compactMap { stroke in
                    guard stroke.isTape else { return nil }
                    var covered = stroke
                    covered.revealed = false
                    return covered
                }
                if !kept.isEmpty {
                    updatedPages[key] = PageAnnotations(strokes: kept)
                }
            }
        }
        after.pages = updatedPages
        after.syncActiveLayerFromTopLevel()
        guard after != before else { return }
        perform(.replaceAll(before: before, after: after))
    }

    func toggleGeometryAid(_ aid: GeometryAid) {
        if geometryAid == aid {
            geometryAid = .none
        } else {
            geometryAid = aid
            if tool.kind == .eraser || tool.kind == .laser || tool.kind == .lasso {
                tool.select(.pen)
            }
        }
    }

    /// Selects a tool explicitly from the toolbar UI (manual eraser selection stays in eraser mode).
    func selectToolManually(_ kind: ToolKind) {
        autoReturnToPenAfterErase = false
        tool.select(kind)
        if kind == .pen {
            tool.pen = .ballpoint
        }
    }

    /// Apple Pencil (2nd generation) double-tap, following the user's system preference.
    /// Switching into `.eraser` via double-tap arms one-shot auto-return back to `.pen` once the
    /// pen tip lifts off the screen after erasing.
    func handlePencilDoubleTap(_ action: UIPencilPreferredAction) {
        let previousKind = tool.kind
        switch action {
        case .ignore:
            return
        case .showColorPalette, .showInkAttributes:
            colorPaletteRequestID &+= 1
            return
        case .switchPrevious:
            tool.switchToPrevious()
        case .switchEraser:
            tool.toggleEraser()
        @unknown default:
            return
        }
        if tool.kind == .eraser && previousKind != .eraser {
            autoReturnToPenAfterErase = true
            NotificationCenter.default.post(
                name: .quillmarkUndoRedoFeedback,
                object: nil,
                userInfo: ["message": "已切换至橡皮（抬笔自动回画笔）"]
            )
        } else {
            autoReturnToPenAfterErase = false
            if tool.kind == .pen && previousKind == .eraser {
                NotificationCenter.default.post(
                    name: .quillmarkUndoRedoFeedback,
                    object: nil,
                    userInfo: ["message": "已切换回画笔"]
                )
            }
        }
    }

    /// Called when an erase touch ends (pen tip lifts off screen) across PDF, HTML, or Scratchpad.
    func didFinishEraseStroke() {
        guard autoReturnToPenAfterErase, tool.kind == .eraser else { return }
        autoReturnToPenAfterErase = false
        tool.select(.pen)
        tool.pen = .ballpoint
    }

    func perform(_ command: Command) {
        execute(command)
        undoStack.append(command)
        if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
        trimExcessReplaceAllSnapshots()
        redoStack.removeAll()
        updateFlags()
    }

    private func trimExcessReplaceAllSnapshots() {
        var replaceAllIndices: [Int] = []
        for (idx, cmd) in undoStack.enumerated() {
            if case .replaceAll = cmd {
                replaceAllIndices.append(idx)
            }
        }
        guard replaceAllIndices.count > maxReplaceAllSnapshots else { return }
        let overflow = replaceAllIndices.count - maxReplaceAllSnapshots
        let toDrop = Set(replaceAllIndices.prefix(overflow))
        undoStack = undoStack.enumerated().compactMap { idx, cmd in
            toDrop.contains(idx) ? nil : cmd
        }
    }

    func undo() {
        guard let command = undoStack.popLast() else { return }
        execute(command.inverse)
        redoStack.append(command)
        updateFlags()
    }

    func redo() {
        guard let command = redoStack.popLast() else { return }
        execute(command)
        undoStack.append(command)
        updateFlags()
    }

    /// Replaces the points of an existing stroke without an undo entry. Used when Apple Pencil
    /// delivers the final force values shortly after the stroke has been committed.
    func refineStroke(id: UUID, page: Int, points: [InkPoint]) {
        var changed = false
        annotations.updatePage(page) { pageAnnotations in
            if let index = pageAnnotations.strokes.lastIndex(where: { $0.id == id }) {
                pageAnnotations.strokes[index].points = points
                changed = true
            }
        }
        guard changed else { return }
        // Patch only the matching undo entry from the top of the stack (O(1) in normal writing).
        for idx in undoStack.indices.reversed() {
            if case let .insert(p, stroke, insertIdx) = undoStack[idx], stroke.id == id {
                var refined = stroke
                refined.points = points
                undoStack[idx] = .insert(page: p, stroke: refined, index: insertIdx)
                break
            }
        }
        pageDidChange?(page)
        scheduleSave(contentEdited: true)
    }

    /// Explicitly lifts write protection after the user acknowledges a corrupted-file warning
    /// (the unreadable original has already been preserved as a `.corrupt-*.json` backup).
    func acknowledgeCorruptedLoadAndEnableSaving() {
        isWriteProtected = false
        loadErrorMessage = nil
        if hasUnsavedChanges {
            saveNow()
        }
    }

    func retrySaveNow() {
        retrySaveWork?.cancel()
        retrySaveWork = nil
        saveNow()
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        retrySaveWork?.cancel()
        retrySaveWork = nil
        guard !isWriteProtected else { return }
        guard hasUnsavedChanges else {
            library.flushPendingWrites()
            return
        }
        saveGeneration &+= 1
        let markModified = hasPendingContentEdit
        annotations.syncActiveLayerFromTopLevel()
        do {
            try library.saveAnnotations(annotations, for: meta.id, markModified: markModified)
            hasUnsavedChanges = false
            hasPendingContentEdit = false
            saveErrorMessage = nil
        } catch {
            NSLog("Quillmark: failed to save annotations: \(error)")
            saveErrorMessage = "批注保存失败（\(error.localizedDescription)），请检查存储空间或点重试。"
        }
    }

    /// Background autosave triggered after the 1-second debounce so 120Hz handwriting never stutters.
    private func saveInBackground() {
        saveWork = nil
        guard !isWriteProtected, hasUnsavedChanges else { return }
        saveGeneration &+= 1
        let targetGeneration = saveGeneration
        let markModified = hasPendingContentEdit
        annotations.syncActiveLayerFromTopLevel()
        let snapshot = annotations
        library.saveAnnotationsAsync(snapshot, for: meta.id, markModified: markModified) { [weak self] error in
            guard let self else { return }
            if let error {
                NSLog("Quillmark: background save failed: \(error)")
                self.saveErrorMessage = "自动保存失败（\(error.localizedDescription)），将自动重试，请检查存储空间。"
                self.scheduleSaveRetry()
                return
            }
            if self.saveGeneration == targetGeneration {
                self.hasUnsavedChanges = false
                self.hasPendingContentEdit = false
                self.saveErrorMessage = nil
            }
        }
    }

    private func scheduleSaveRetry() {
        retrySaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveInBackground()
        }
        retrySaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func execute(_ command: Command) {
        switch command {
        case let .insert(page, stroke, index):
            annotations.updatePage(page) { p in
                p.strokes.insert(stroke, at: min(max(0, index), p.strokes.count))
            }
        case let .remove(page, stroke, _):
            annotations.updatePage(page) { p in
                p.strokes.removeAll { $0.id == stroke.id }
            }
        case let .replace(page, _, after):
            annotations.updatePage(page) { p in
                p.strokes = after
            }
        case let .replaceAll(_, after):
            annotations = after
            scratchpadPageCount = after.resolvedScratchpadPageCount
            if let paper = after.scratchpadPaper {
                scratchpadPaper = paper
            }
            refreshPublishedLayers()
        }
        if let page = command.page {
            pageDidChange?(page)
        } else if let allPagesDidChange {
            allPagesDidChange()
        } else {
            pageDidChange?(0)
        }
        scheduleSave(contentEdited: true)
    }

    private func updateFlags() {
        let nextUndo = !undoStack.isEmpty
        let nextRedo = !redoStack.isEmpty
        if canUndo != nextUndo { canUndo = nextUndo }
        if canRedo != nextRedo { canRedo = nextRedo }
    }

    private func scheduleSave(contentEdited: Bool) {
        guard !isWriteProtected else { return }
        hasUnsavedChanges = true
        if contentEdited {
            hasPendingContentEdit = true
        }
        saveGeneration &+= 1
        saveWork?.cancel()
        if UIApplication.shared.applicationState != .active {
            saveNow()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.saveInBackground() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
