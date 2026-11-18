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
        /// Replaces all strokes of a page (one eraser gesture).
        case replace(page: Int, before: [InkStroke], after: [InkStroke])

        var inverse: Command {
            switch self {
            case let .insert(page, stroke, index): return .remove(page: page, stroke: stroke, index: index)
            case let .remove(page, stroke, index): return .insert(page: page, stroke: stroke, index: index)
            case let .replace(page, before, after): return .replace(page: page, before: after, after: before)
            }
        }

        var page: Int {
            switch self {
            case let .insert(page, _, _), let .remove(page, _, _), let .replace(page, _, _): return page
            }
        }
    }

    let meta: DocumentMeta
    let pdfDocument: PDFDocument?

    @Published var tool: ToolSettings {
        didSet { tool.save() }
    }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Called after the strokes of a page changed (page index).
    var pageDidChange: ((Int) -> Void)?

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
        self.annotations = library.loadAnnotations(for: meta.id)
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
        }
        pageDidChange?(command.page)
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
