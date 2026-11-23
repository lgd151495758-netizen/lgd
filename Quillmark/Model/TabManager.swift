import Combine
import Foundation

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
    @discardableResult
    func open(_ meta: DocumentMeta, library: LibraryStore) -> DocumentTab {
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
            return existing
        }

        if let prevID = activeTabID {
            onFlushTabState?(prevID)
        }
        let session = DocumentSession(meta: meta, library: library, tool: sharedTool)
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
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
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

    func saveAllTabs() {
        for tab in tabs {
            onFlushTabState?(tab.id)
            tab.session.saveNow()
        }
    }
}
