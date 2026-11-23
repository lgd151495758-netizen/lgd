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
final class TabDeckViewController: UIViewController {
    private var controllers: [UUID: DocumentTabViewController] = [:]
    private var currentActiveID: UUID?
    private var currentWorkspaceVisible: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true
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

    func sync(tabs: [DocumentTab], activeTabID: UUID?, isWorkspaceVisible: Bool, library: LibraryStore) {
        loadViewIfNeeded()

        // 1. Remove closed tabs cleanly.
        let openIDs = Set(tabs.map(\.id))
        for id in Array(controllers.keys) where !openIDs.contains(id) {
            if let vc = controllers.removeValue(forKey: id) {
                let wasCurrent = (currentActiveID == id)
                vc.saveStateNow()
                vc.setTabActive(false, releasePresentation: wasCurrent && tabs.isEmpty)
                vc.willMove(toParent: nil)
                vc.view.removeFromSuperview()
                vc.removeFromParent()
                if wasCurrent {
                    currentActiveID = nil
                }
            }
        }

        // 2. Mount newly opened tabs (keeping existing live VCs untouched).
        for tab in tabs where controllers[tab.id] == nil {
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
        currentActiveID = nil
        currentWorkspaceVisible = false
    }
}
