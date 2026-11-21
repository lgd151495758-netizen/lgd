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
    let pdfDocument: PDFDocument?

    @Published var tool: ToolSettings {
        didSet { tool.save() }
    }
    @Published var geometryAid: GeometryAid = .none
    @Published var isScratchpadOpen: Bool = false
    @Published var scratchpadSplitMode: ScratchpadSplitMode = .floating
    @Published private(set) var scratchpadPageIndex: Int = 0
    @Published private(set) var scratchpadPageCount: Int = 1
    @Published var scratchpadPaper: ScratchpadPaperStyle = .grid {
        didSet {
            guard scratchpadPaper != oldValue else { return }
            annotations.scratchpadPaper = scratchpadPaper
            scheduleSave()
        }
    }
    var savedScratchpadFrame: CGRect? { annotations.scratchpadFrame }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Zero-based currently visible main page index (used by multi-page PDF documents).
    @Published var activeDocumentPageIndex: Int = 0

    /// Called after the strokes of a single page changed (page index; negative values are scratchpad pages).
    var pageDidChange: ((Int) -> Void)?
    /// Called after a multi-page command (`replaceAll`) changed multiple pages at once.
    var allPagesDidChange: (() -> Void)?

    var pdfPageCount: Int {
        pdfDocument?.pageCount ?? 0
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
    private var hasUnsavedChanges = false
    private var observers: [NSObjectProtocol] = []
    private let undoLimit = 500

    init(meta: DocumentMeta, library: LibraryStore, tool: ToolSettings = ToolSettings.load()) {
        self.meta = meta
        self.library = library
        self.tool = tool
        let loaded = library.loadAnnotations(for: meta.id)
        self.annotations = loaded
        self.scratchpadPageCount = loaded.resolvedScratchpadPageCount
        self.scratchpadPaper = loaded.scratchpadPaper ?? .grid
        self.pdfDocument = PDFDocument(url: library.pdfURL(for: meta.id))
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
        scheduleSave()
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
        scheduleSave()
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
        scheduleSave()
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
        scheduleSave()
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

    /// Clears handwriting across all main document pages as one undoable step (preserving sticky-note pages).
    /// When `keepTapes` is `true`, Cover Tapes are preserved and reset to covered (`revealed = false`).
    func clearAllDocumentHandwriting(keepTapes: Bool) {
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

    /// Apple Pencil (2nd generation) double-tap, following the user's system preference.
    func handlePencilDoubleTap(_ action: UIPencilPreferredAction) {
        switch action {
        case .ignore:
            return
        case .switchPrevious:
            tool.switchToPrevious()
        default:
            tool.toggleEraser()
        }
    }

    func perform(_ command: Command) {
        execute(command)
        undoStack.append(command)
        if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
        redoStack.removeAll()
        updateFlags()
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
            if let index = pageAnnotations.strokes.firstIndex(where: { $0.id == id }) {
                pageAnnotations.strokes[index].points = points
                changed = true
            }
        }
        guard changed else { return }
        undoStack = undoStack.map { command in
            if case let .insert(p, stroke, index) = command, stroke.id == id {
                var refined = stroke
                refined.points = points
                return .insert(page: p, stroke: refined, index: index)
            }
            return command
        }
        pageDidChange?(page)
        scheduleSave()
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard hasUnsavedChanges else { return }
        do {
            try library.saveAnnotations(annotations, for: meta.id)
            hasUnsavedChanges = false
        } catch {
            NSLog("Quillmark: failed to save annotations: \(error)")
        }
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
        }
        if let page = command.page {
            pageDidChange?(page)
        } else if let allPagesDidChange {
            allPagesDidChange()
        } else {
            pageDidChange?(0)
        }
        scheduleSave()
    }

    private func updateFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func scheduleSave() {
        hasUnsavedChanges = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
