import Combine
import Foundation
import UIKit

/// One open document tab inside the tabbed workspace.
final class DocumentTab: Identifiable, ObservableObject {
    let id: UUID
    @Published var meta: DocumentMeta
    let session: DocumentSession

    init(meta: DocumentMeta, session: DocumentSession) {
        self.id = meta.id
        self.meta = meta
        self.session = session
    }
}

/// Manages multiple open documents in a browser-style tab bar.
/// - Opening an already-open document switches straight to its existing tab (preserving scroll/zoom/undo).
/// - Switching tabs shares the active drawing tool (`ToolSettings`) while keeping each document's
///   viewing position, undo stack, sticky note, and live DOM state completely independent.
@MainActor
final class TabManager: ObservableObject {
    @Published private(set) var tabs: [DocumentTab] = []
    @Published private(set) var activeTabID: UUID?
    @Published var isWorkspaceVisible: Bool = false

    /// Called before saving or leaving a tab so the live view controller can flush its current viewport.
    var onFlushTabState: (@MainActor (UUID) -> Void)?
    /// Resolves the live `WebInkBridge` for an open HTML tab so exports preserve live DOM state.
    var onResolveLiveBridge: (@MainActor (UUID) -> WebInkBridge?)?

    private var backgroundObserver: NSObjectProtocol?

    init() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveAllTabsInBackgroundTask()
            }
        }
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    func liveWebBridge(for id: UUID) -> WebInkBridge? {
        onResolveLiveBridge?(id)
    }

    func session(for id: UUID) -> DocumentSession? {
        tabs.first(where: { $0.id == id })?.session
    }

    var activeTab: DocumentTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    func isOpen(_ id: UUID) -> Bool {
        tabs.contains { $0.id == id }
    }

    /// Opens `meta` in a new tab (or switches to it if already open) and displays the workspace.
    /// When `targetPDFPage` is provided for a PDF document, jumps straight to that zero-based page.
    @discardableResult
    func open(_ meta: DocumentMeta, library: LibraryStore, targetPDFPage: Int? = nil) -> DocumentTab {
        let sharedTool = activeTab?.session.tool ?? ToolSettings.load()

        if let existing = tabs.first(where: { $0.id == meta.id }) {
            existing.meta = meta
            if activeTabID != existing.id {
                if let prevID = activeTabID {
                    onFlushTabState?(prevID)
                }
                if existing.session.tool != sharedTool {
                    existing.session.tool = sharedTool
                }
                activeTabID = existing.id
            }
            isWorkspaceVisible = true
            if let targetPDFPage, meta.layout != .live {
                existing.session.jumpToPDFPage(targetPDFPage)
            }
            return existing
        }

        if let prevID = activeTabID {
            onFlushTabState?(prevID)
        }
        let session = DocumentSession(meta: meta, library: library, tool: sharedTool)
        if let targetPDFPage, meta.layout != .live {
            session.jumpToPDFPage(targetPDFPage)
        }
        let tab = DocumentTab(meta: meta, session: session)
        tabs.append(tab)
        activeTabID = tab.id
        isWorkspaceVisible = true
        return tab
    }

    /// Switches to an already-open tab while inheriting the current active tool settings.
    func selectTab(id: UUID) {
        guard let target = tabs.first(where: { $0.id == id }) else { return }
        if activeTabID != id {
            if let prev = activeTab {
                onFlushTabState?(prev.id)
                if target.session.tool != prev.session.tool {
                    target.session.tool = prev.session.tool
                }
            }
            activeTabID = id
        }
        isWorkspaceVisible = true
    }

    /// Closes a tab, flushing & saving its state first. Selects an adjacent tab if it was active,
    /// or returns to the Library if it was the last open tab.
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[index]
        onFlushTabState?(id)
        closing.session.saveNow()

        let wasActive = (activeTabID == id)
        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabID = nil
            isWorkspaceVisible = false
        } else if wasActive {
            let nextIndex = min(index, tabs.count - 1)
            let nextTab = tabs[nextIndex]
            if nextTab.session.tool != closing.session.tool {
                nextTab.session.tool = closing.session.tool
            }
            activeTabID = nextTab.id
        }
    }

    /// Returns to the Library while keeping all open tabs warm in memory.
    func showLibrary() {
        saveAllTabs()
        isWorkspaceVisible = false
    }

    /// Returns from the Library back to the active open tab.
    func showWorkspace() {
        guard !tabs.isEmpty else { return }
        if activeTabID == nil {
            activeTabID = tabs.first?.id
        }
        isWorkspaceVisible = true
    }

    /// Refreshes metadata titles/timestamps from the library for any open tabs.
    func syncMetadata(from documents: [DocumentMeta]) {
        let byID = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tab in tabs {
            if let updated = byID[tab.id], tab.meta != updated {
                tab.meta = updated
            }
        }
    }

    /// Reloads annotations from disk for an open tab (e.g. after clearing ink in the Library).
    func reloadFromDisk(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.session.reloadAnnotationsFromDisk()
    }

    /// Reloads annotations from disk for every open tab (e.g. after a replace-mode backup restore).
    func reloadAllFromDisk() {
        for tab in tabs {
            tab.session.reloadAnnotationsFromDisk()
        }
    }

    func saveAllTabs() {
        for tab in tabs {
            onFlushTabState?(tab.id)
            tab.session.saveNow()
        }
    }

    /// Flushes all open tabs and pending background IO inside an iOS background task so edits made
    /// moments before switching apps or locking the iPad are never truncated on suspension.
    private func saveAllTabsInBackgroundTask() {
        let app = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = app.beginBackgroundTask(withName: "QuillmarkBackgroundSave") {
            if taskID != .invalid {
                app.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        saveAllTabs()
        LibraryStore.shared.flushPendingWrites()
        if taskID != .invalid {
            app.endBackgroundTask(taskID)
            taskID = .invalid
        }
    }
}
