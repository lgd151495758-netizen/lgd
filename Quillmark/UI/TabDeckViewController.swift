import UIKit

/// Common lifecycle contract for document editors hosted inside `TabDeckViewController`.
protocol DocumentTabViewController: UIViewController {
    var session: DocumentSession { get }
    var isManagedByTabDeck: Bool { get set }
    func setTabActive(_ active: Bool, releasePresentation: Bool)
    func saveStateNow()
}

/// Hosts multiple live `WebEditorViewController` / `EditorViewController` children in memory so
/// switching document tabs is instant (0ms) and preserves exact scroll position, zoom, active PDF
/// page, live HTML DOM state, undo stack, and floating sticky-note layout.
///
/// To protect 4GB iPads (e.g. iPad Air 4) when many heavy PDFs/HTML coursewares are open at once,
/// keeps at most `maxLiveControllers` most-recently-used editors mounted and automatically
/// hibernates older inactive tabs (flushing their exact `ViewportState` & annotations first).
/// Switching back to a hibernated tab remounts it seamlessly at the exact saved viewport.
final class TabDeckViewController: UIViewController {
    /// Maximum simultaneous heavy editor view controllers kept live in RAM.
    var maxLiveControllers: Int = 4

    private var controllers: [UUID: DocumentTabViewController] = [:]
    /// Most recently used tab IDs (oldest at index 0, most recent at the end).
    private var lruOrder: [UUID] = []
    private var currentActiveID: UUID?
    private var currentWorkspaceVisible: Bool = false
    private var memoryWarningObserver: NSObjectProtocol?

    var liveControllerCount: Int { controllers.count }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true
        if memoryWarningObserver == nil {
            memoryWarningObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.hibernateInactiveTabs(keepingAtMost: 1)
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PresentationCenter.shared.registerSceneAccessory(on: self)
        if currentWorkspaceVisible, let id = currentActiveID {
            controllers[id]?.setTabActive(true, releasePresentation: false)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let id = currentActiveID {
            controllers[id]?.saveStateNow()
            controllers[id]?.setTabActive(false, releasePresentation: true)
        }
        PresentationCenter.shared.unregisterSceneAccessory(from: self)
    }

    func controller(for id: UUID) -> DocumentTabViewController? {
        controllers[id]
    }

    func flushTabState(for id: UUID) {
        controllers[id]?.saveStateNow()
    }

    func liveWebBridge(for id: UUID) -> WebInkBridge? {
        (controllers[id] as? WebEditorViewController)?.exportBridge
    }

    /// Evicts least-recently-used inactive tab view controllers while keeping at most `limit` live
    /// editors (and never evicting the currently active tab). Hibernated tabs keep their
    /// `DocumentSession` and exact `ViewportState` so switching back restores cleanly.
    func hibernateInactiveTabs(keepingAtMost limit: Int) {
        let cap = max(1, limit)
        guard controllers.count > cap else { return }

        var candidates = lruOrder.filter { id in
            id != currentActiveID && controllers[id] != nil
        }
        // Include any mounted inactive controller not yet tracked in lruOrder.
        for id in controllers.keys where id != currentActiveID && !candidates.contains(id) {
            candidates.insert(id, at: 0)
        }

        for id in candidates {
            guard controllers.count > cap else { break }
            evictController(for: id, releasePresentation: false)
        }
    }

    func sync(tabs: [DocumentTab], activeTabID: UUID?, isWorkspaceVisible: Bool, library: LibraryStore) {
        loadViewIfNeeded()

        // 1. Remove closed tabs cleanly.
        let openIDs = Set(tabs.map(\.id))
        lruOrder.removeAll { !openIDs.contains($0) }
        for id in Array(controllers.keys) where !openIDs.contains(id) {
            let wasCurrent = (currentActiveID == id)
            evictController(for: id, releasePresentation: wasCurrent && tabs.isEmpty)
            if wasCurrent {
                currentActiveID = nil
            }
        }

        // 2. Always ensure the active tab is mounted (reviving it if previously hibernated),
        //    plus warm other open tabs up to the LRU memory cap.
        let limit = max(1, maxLiveControllers)
        if let activeTabID,
           controllers[activeTabID] == nil,
           let activeTab = tabs.first(where: { $0.id == activeTabID }) {
            mountController(for: activeTab, library: library)
        }
        for tab in tabs where controllers[tab.id] == nil {
            guard controllers.count < limit else { break }
            mountController(for: tab, library: library)
        }

        // Track LRU recency so active tab is always most recently used.
        if let activeTabID, openIDs.contains(activeTabID) {
            touchLRU(activeTabID)
        }

        // 3. Toggle visibility and bring active child to front.
        for (id, child) in controllers {
            let isTarget = (id == activeTabID)
            child.view.isHidden = !isTarget
            child.view.isUserInteractionEnabled = isTarget
        }
        if let activeTabID, let activeVC = controllers[activeTabID] {
            view.bringSubviewToFront(activeVC.view)
        }

        // 4. Manage active lifecycle & PresentationCenter handoff (preserving Freeze across tab switches).
        if !isWorkspaceVisible {
            if currentWorkspaceVisible, let prevID = currentActiveID, let prevVC = controllers[prevID] {
                prevVC.saveStateNow()
                prevVC.setTabActive(false, releasePresentation: true)
            }
            currentWorkspaceVisible = false
            currentActiveID = activeTabID
            hibernateInactiveTabs(keepingAtMost: limit)
            return
        }

        if currentActiveID != activeTabID || !currentWorkspaceVisible {
            if let prevID = currentActiveID, prevID != activeTabID, let prevVC = controllers[prevID] {
                prevVC.saveStateNow()
                prevVC.setTabActive(false, releasePresentation: false)
            }
            if let nextID = activeTabID, let nextVC = controllers[nextID] {
                nextVC.setTabActive(true, releasePresentation: false)
            }
            currentActiveID = activeTabID
            currentWorkspaceVisible = true
        }

        // 5. Enforce LRU cap after lifecycle handoff so the newly active tab is protected.
        hibernateInactiveTabs(keepingAtMost: limit)
    }

    func teardownAllTabs() {
        for (id, vc) in controllers {
            vc.saveStateNow()
            vc.setTabActive(false, releasePresentation: id == currentActiveID)
            vc.willMove(toParent: nil)
            vc.view.removeFromSuperview()
            vc.removeFromParent()
        }
        controllers.removeAll()
        lruOrder.removeAll()
        currentActiveID = nil
        currentWorkspaceVisible = false
    }

    // MARK: Helpers

    private func mountController(for tab: DocumentTab, library: LibraryStore) {
        let child: DocumentTabViewController
        if tab.meta.layout == .live {
            child = WebEditorViewController(session: tab.session, library: library)
        } else {
            child = EditorViewController(session: tab.session)
        }
        child.isManagedByTabDeck = true
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        child.view.isHidden = true
        child.view.isUserInteractionEnabled = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child.didMove(toParent: self)
        child.setTabActive(false, releasePresentation: false)
        controllers[tab.id] = child
        touchLRU(tab.id)
    }

    private func evictController(for id: UUID, releasePresentation: Bool) {
        guard let vc = controllers.removeValue(forKey: id) else { return }
        vc.saveStateNow()
        vc.setTabActive(false, releasePresentation: releasePresentation)
        vc.willMove(toParent: nil)
        vc.view.removeFromSuperview()
        vc.removeFromParent()
    }

    private func touchLRU(_ id: UUID) {
        lruOrder.removeAll { $0 == id }
        lruOrder.append(id)
    }
}
