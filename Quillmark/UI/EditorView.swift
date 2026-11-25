import SwiftUI

/// Tabbed document editing workspace: compact browser-style tab bar (iPad-only) + floating toolbar
/// + live `TabDeckViewController` hosting multiple HTML & PDF documents simultaneously with
/// instant 0ms switching and exact viewing-position preservation.
struct WorkspaceView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var library: LibraryStore
    @ObservedObject private var presentation = PresentationCenter.shared

    @State private var showQuickOpenPopover = false
    @State private var showPresentationPopover = false
    @State private var exportTargetMeta: DocumentMeta?
    @State private var isFocusMode = false
    @State private var undoToastText: String?
    @State private var undoToastCanUndo = false
    @State private var undoToastDismissWork: DispatchWorkItem?

    let onCreateNotebook: () -> Void
    let onImportPDF: () -> Void
    let onImportHTML: () -> Void
    let onImportURL: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if !isFocusMode {
                    tabBar
                    Divider()
                    if let activeTab = tabManager.activeTab {
                        ToolbarView(session: activeTab.session)
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                    }
                }
                if let activeTab = tabManager.activeTab {
                    SessionSafetyBanner(session: activeTab.session)
                }
                if presentation.isFrozen {
                    Button {
                        presentation.isFrozen = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "snowflake")
                            Text("大屏画面已冻结 · 可自由切换标签或翻页，轻点此处恢复实时同步")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("恢复大屏实时同步")
                }
                TabDeckRepresentable(tabManager: tabManager, library: library)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isFocusMode, let activeTab = tabManager.activeTab {
                HStack {
                    Spacer()
                    FocusModeFloatingBar(
                        session: activeTab.session,
                        presentation: presentation,
                        onExitFocus: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isFocusMode = false
                            }
                        }
                    )
                }
                .padding(.top, presentation.isFrozen ? 38 : 10)
                .padding(.trailing, 14)
            }

            if let toast = undoToastText {
                HStack(spacing: 10) {
                    Text(toast)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    if undoToastCanUndo, let activeSession = tabManager.activeTab?.session, activeSession.canUndo {
                        Button("撤销") {
                            activeSession.undo()
                            undoToastDismissWork?.cancel()
                            withAnimation(.easeIn(duration: 0.15)) {
                                undoToastText = nil
                                undoToastCanUndo = false
                            }
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.yellow)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.80), in: Capsule())
                .padding(.top, isFocusMode ? 16 : 108)
                .allowsHitTesting(undoToastCanUndo)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .background(Color(.systemBackground))
        .ignoresSafeArea(edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: .quillmarkUndoRedoFeedback)) { note in
            guard let msg = note.userInfo?["message"] as? String else { return }
            let showUndo = (note.userInfo?["showUndo"] as? Bool) ?? false
            let duration: TimeInterval = showUndo ? 2.8 : (msg.count > 10 ? 2.0 : 0.95)
            undoToastDismissWork?.cancel()
            withAnimation(.easeOut(duration: 0.15)) {
                undoToastText = msg
                undoToastCanUndo = showUndo
            }
            let work = DispatchWorkItem {
                withAnimation(.easeIn(duration: 0.2)) {
                    undoToastText = nil
                    undoToastCanUndo = false
                }
            }
            undoToastDismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
        .sheet(item: $exportTargetMeta) { meta in
            ExportDocumentSheet(
                meta: meta,
                library: library,
                activeSession: tabManager.session(for: meta.id),
                liveBridge: tabManager.liveWebBridge(for: meta.id)
            )
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            Button {
                tabManager.showLibrary()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                    Text("文档库")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回文档库")

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tabManager.tabs) { tab in
                            DocumentTabPill(
                                tab: tab,
                                isActive: tab.id == tabManager.activeTabID,
                                onSelect: { tabManager.selectTab(id: tab.id) },
                                onClose: { tabManager.closeTab(id: tab.id) }
                            )
                            .id(tab.id)
                        }

                        Button {
                            showQuickOpenPopover = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 30, height: 30)
                                .background(Color(.tertiarySystemFill), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("在新标签页打开文档")
                        .popover(isPresented: $showQuickOpenPopover) {
                            QuickOpenDocumentPopover(
                                library: library,
                                tabManager: tabManager,
                                dismiss: { showQuickOpenPopover = false },
                                onCreateNotebook: {
                                    showQuickOpenPopover = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        onCreateNotebook()
                                    }
                                },
                                onImportPDF: {
                                    showQuickOpenPopover = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        onImportPDF()
                                    }
                                },
                                onImportHTML: {
                                    showQuickOpenPopover = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        onImportHTML()
                                    }
                                },
                                onImportURL: {
                                    showQuickOpenPopover = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        onImportURL()
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 1)
                }
                .onChange(of: tabManager.activeTabID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                if let activeTab = tabManager.activeTab {
                    ActiveTabTrailingControls(
                        session: activeTab.session,
                        onExport: {
                            tabManager.saveAllTabs()
                            exportTargetMeta = activeTab.meta
                        }
                    )
                }
                if presentation.isExternalDisplayConnected {
                    Button {
                        presentation.isFrozen.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: presentation.isFrozen ? "snowflake" : "pause.circle")
                            Text(presentation.isFrozen ? "已冻结" : "冻结")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(presentation.isFrozen ? Color.white : Color.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(presentation.isFrozen ? Color.orange : Color.secondary.opacity(0.16),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(presentation.isFrozen ? "取消冻结大屏" : "冻结大屏画面")
                }
                Button {
                    presentation.scanDisplays()
                    showPresentationPopover = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "airplayvideo")
                        if presentation.isExternalDisplayConnected {
                            Text(presentation.contentOnly ? "投屏中" : "镜像中")
                                .font(.caption.weight(.medium))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(presentation.isExternalDisplayConnected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                                in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("投屏设置")
                .popover(isPresented: $showPresentationPopover) {
                    PresentationPopover(presentation: presentation)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isFocusMode = true
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("进入专注书写模式（折叠顶栏）")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }
}

private struct DocumentTabPill: View {
    @ObservedObject var tab: DocumentTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 5) {
                    Image(systemName: tab.meta.layout == .live ? "doc.richtext" : "doc.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tab.meta.layout == .live ? Color.accentColor : Color.red.opacity(0.85))
                    Text(tab.meta.title)
                        .font(.subheadline.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: isActive ? 175 : 145, alignment: .leading)
                }
                .padding(.leading, 10)
                .padding(.trailing, 2)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.secondary.opacity(isActive ? 0.14 : 0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 5)
            .accessibilityLabel("关闭标签页 \(tab.meta.title)")
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? Color(.systemBackground) : Color(.tertiarySystemFill).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .shadow(color: isActive ? Color.black.opacity(0.08) : Color.clear, radius: 3, y: 1)
    }
}

/// Observes the active tab's `DocumentSession` directly so page numbers, class layers, export,
/// and clear options update live.
private struct ActiveTabTrailingControls: View {
    @ObservedObject var session: DocumentSession
    let onExport: () -> Void

    @State private var showPageNavigator = false
    @State private var showLayersPopover = false
    @State private var pendingClearAllKeepTapes: Bool?

    var body: some View {
        HStack(spacing: 6) {
            if session.pdfPageCount >= 1 && session.meta.layout != .live {
                Button {
                    showPageNavigator = true
                } label: {
                    HStack(spacing: 3) {
                        Text("\(session.activeDocumentPageIndex + 1)/\(session.pdfPageCount)")
                            .font(.caption.monospacedDigit().weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("页面导航：第 \(session.activeDocumentPageIndex + 1) 页，共 \(session.pdfPageCount) 页")
                .popover(isPresented: $showPageNavigator) {
                    PDFPageNavigatorPopover(session: session) {
                        showPageNavigator = false
                    }
                }
            }

            Button {
                session.refreshLayerSummaries()
                showLayersPopover = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.3.layers.3d")
                    Text(session.hasMultipleLayers ? session.activeLayerName : "图层")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: 74)
                }
                .foregroundStyle(session.hasMultipleLayers ? Color.accentColor : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(session.hasMultipleLayers ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.14),
                            in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换班级板书图层")
            .popover(isPresented: $showLayersPopover) {
                ClassLayersPopover(session: session) {
                    showLayersPopover = false
                }
            }

            Button(action: onExport) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                    Text("导出")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导出带批注 PDF 或图片")

            clearMenu
        }
    }

    private var clearMenu: some View {
        Menu {
            if session.meta.layout == .live {
                Button {
                    pendingClearAllKeepTapes = true
                } label: {
                    Label("清空手写（保留胶带）", systemImage: "eraser.line.dashed")
                }
                Button(role: .destructive) {
                    pendingClearAllKeepTapes = false
                } label: {
                    Label("清空全部批注（含胶带）", systemImage: "trash")
                }
            } else {
                if session.pdfPageCount > 1 {
                    Button {
                        session.clearHandwriting(onPage: session.activeDocumentPageIndex, keepTapes: true)
                        NotificationCenter.default.post(
                            name: .quillmarkUndoRedoFeedback,
                            object: nil,
                            userInfo: ["message": "已清空第 \(session.activeDocumentPageIndex + 1) 页手写", "showUndo": true]
                        )
                    } label: {
                        Label("清空第 \(session.activeDocumentPageIndex + 1) 页手写（保留胶带）",
                              systemImage: "eraser.line.dashed")
                    }
                    Button(role: .destructive) {
                        pendingClearAllKeepTapes = true
                    } label: {
                        Label("清空整份 PDF 手写（保留胶带）", systemImage: "doc.on.doc")
                    }
                } else {
                    Button {
                        pendingClearAllKeepTapes = true
                    } label: {
                        Label("清空手写（保留胶带）", systemImage: "eraser.line.dashed")
                    }
                }
                Button(role: .destructive) {
                    pendingClearAllKeepTapes = false
                } label: {
                    Label("清空全部批注（含胶带）", systemImage: "trash")
                }
            }
            if session.isScratchpadOpen {
                Divider()
                Button {
                    session.clearCurrentScratchpadPage()
                    NotificationCenter.default.post(
                        name: .quillmarkUndoRedoFeedback,
                        object: nil,
                        userInfo: ["message": "已清空当前便签页", "showUndo": true]
                    )
                } label: {
                    Label("清空当前便签页", systemImage: "note.text")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                Text("清空")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.14), in: Capsule())
        }
        .accessibilityLabel("清空手写")
        .confirmationDialog(
            pendingClearAllKeepTapes == false ? "清空整份文档的全部批注（含胶带）？" : "清空整份文档的手写（保留胶带）？",
            isPresented: Binding(
                get: { pendingClearAllKeepTapes != nil },
                set: { if !$0 { pendingClearAllKeepTapes = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingClearAllKeepTapes == false ? "清空全部批注" : "清空手写（保留胶带）", role: .destructive) {
                if let keepTapes = pendingClearAllKeepTapes {
                    session.clearAllDocumentHandwriting(keepTapes: keepTapes)
                    pendingClearAllKeepTapes = nil
                    NotificationCenter.default.post(
                        name: .quillmarkUndoRedoFeedback,
                        object: nil,
                        userInfo: ["message": keepTapes ? "已清空整份手写（保留胶带）" : "已清空全部批注", "showUndo": true]
                    )
                }
            }
            Button("取消", role: .cancel) {
                pendingClearAllKeepTapes = nil
            }
        } message: {
            Text(pendingClearAllKeepTapes == false
                 ? "将清空当前图层的所有手写、图形与遮盖胶带（清空后仍可立即点击撤销）。"
                 : "将清空当前图层的所有手写与图形，已贴好的遮盖胶带会保留并恢复为遮盖状态。")
        }
    }
}

private struct QuickOpenDocumentPopover: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var tabManager: TabManager
    let dismiss: () -> Void
    let onCreateNotebook: () -> Void
    let onImportPDF: () -> Void
    let onImportHTML: () -> Void
    let onImportURL: () -> Void

    @State private var query = ""

    private var filteredDocuments: [DocumentMeta] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return library.documents }
        return library.documents.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("打开文档到新标签页")
                    .font(.headline)
                Spacer()
            }

            HStack(spacing: 6) {
                Button(action: onCreateNotebook) {
                    Label("空白本", systemImage: "note.text.badge.plus")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(action: onImportPDF) {
                    Label("PDF", systemImage: "doc.fill")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(action: onImportHTML) {
                    Label("HTML", systemImage: "doc.badge.plus")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(action: onImportURL) {
                    Label("网址", systemImage: "globe")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
            }

            if library.documents.count > 4 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索文档名称…", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            if filteredDocuments.isEmpty {
                Text("没有匹配的文档")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredDocuments) { meta in
                            let isCurrent = tabManager.activeTabID == meta.id
                            let isOpened = tabManager.isOpen(meta.id)
                            Button {
                                tabManager.open(meta, library: library)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: meta.layout == .live ? "doc.richtext" : "doc.fill")
                                        .foregroundStyle(meta.layout == .live ? Color.accentColor : Color.red.opacity(0.85))
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(meta.title)
                                            .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(meta.layout.displayName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if isCurrent {
                                        Text("当前")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor, in: Capsule())
                                    } else if isOpened {
                                        Text("已打开")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct PresentationPopover: View {
    @ObservedObject var presentation: PresentationCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("投屏模式")
                .font(.headline)

            Toggle("仅投内容", isOn: $presentation.contentOnly)

            Text("开启后，教室外接大屏（AirPlay 或有线 HDMI）只显示文档与批注内容；标签栏、工具栏与文档库列表仅在 iPad 上显示。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if presentation.contentOnly {
                Picker("缩放方式", selection: $presentation.fillMode) {
                    ForEach(PresentationFillMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("大屏显示尺规（圆规 / 量角器）", isOn: $presentation.showGeometryToolsOnExternalDisplay)
                Text("开启后，在 iPad 上使用圆规作图或量角器测角时，学生大屏会实时同步显示圆规臂、量角器刻度盘与数字角度读数（自动隐藏操作按钮）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if presentation.isExternalDisplayConnected {
                Toggle("冻结大屏画面", isOn: $presentation.isFrozen)
                Text("冻结后学生端大屏保持当前画面不变，即使返回文档库或切换标签页看答案也不会泄露给学生，关闭冻结后立即恢复同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("智能节能投屏", isOn: $presentation.smartPowerSaving)
            Text("开启后，PDF 静止时暂停后台截屏、互动网页空闲自动降频（60fps 笔迹与激光笔实时同步不受影响），可显著降低长时间上课的机身发热与耗电。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(presentation.isExternalDisplayConnected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                Text(presentation.connectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                presentation.scanDisplays()
            } label: {
                Label("重新检测外接屏幕", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
        }
        .padding(18)
        .frame(width: 310)
    }
}

private struct TabDeckRepresentable: UIViewControllerRepresentable {
    @ObservedObject var tabManager: TabManager
    let library: LibraryStore

    func makeUIViewController(context: Context) -> TabDeckViewController {
        let controller = TabDeckViewController()
        tabManager.onFlushTabState = { [weak controller] id in
            controller?.flushTabState(for: id)
        }
        tabManager.onResolveLiveBridge = { [weak controller] id in
            controller?.liveWebBridge(for: id)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: TabDeckViewController, context: Context) {
        tabManager.onFlushTabState = { [weak uiViewController] id in
            uiViewController?.flushTabState(for: id)
        }
        tabManager.onResolveLiveBridge = { [weak uiViewController] id in
            uiViewController?.liveWebBridge(for: id)
        }
        uiViewController.sync(
            tabs: tabManager.tabs,
            activeTabID: tabManager.activeTabID,
            isWorkspaceVisible: tabManager.isWorkspaceVisible,
            library: library
        )
    }

    static func dismantleUIViewController(_ uiViewController: TabDeckViewController, coordinator: ()) {
        uiViewController.teardownAllTabs()
    }
}

/// Compact floating capsule shown in the top-trailing corner during Focus Writing Mode
/// (strictly on the iPad SwiftUI overlay, never projected onto the external display).
private struct SessionSafetyBanner: View {
    @ObservedObject var session: DocumentSession

    var body: some View {
        VStack(spacing: 0) {
            if let loadError = session.loadErrorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.white)
                    Text(loadError)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("解除只读") {
                        session.acknowledgeCorruptedLoadAndEnableSaving()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white, in: Capsule())
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.92))
            }

            if let saveError = session.saveErrorMessage {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.white)
                    Text(saveError)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("重试保存") {
                        session.retrySaveNow()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white, in: Capsule())
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.95))
            }
        }
    }
}

private struct FocusModeFloatingBar: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var presentation: PresentationCenter
    let onExitFocus: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                session.selectToolManually(.pen)
            } label: {
                Image(systemName: "pencil")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(session.tool.kind == .pen ? Color.accentColor : Color.primary)
                    .frame(width: 34, height: 34)
                    .background(session.tool.kind == .pen ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换画笔")

            Button {
                session.selectToolManually(.laser)
            } label: {
                Image(systemName: "laser.burst")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(session.tool.kind == .laser ? Color.accentColor : Color.primary)
                    .frame(width: 34, height: 34)
                    .background(session.tool.kind == .laser ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换激光笔")

            Button {
                session.selectToolManually(.eraser)
            } label: {
                Image(systemName: "eraser")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(session.tool.kind == .eraser ? Color.accentColor : Color.primary)
                    .frame(width: 34, height: 34)
                    .background(session.tool.kind == .eraser ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换橡皮")

            Button {
                session.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.subheadline.weight(.medium))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!session.canUndo)
            .accessibilityLabel("撤销")

            Button {
                session.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.subheadline.weight(.medium))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!session.canRedo)
            .accessibilityLabel("重做")

            if presentation.isExternalDisplayConnected {
                Button {
                    presentation.isFrozen.toggle()
                } label: {
                    Image(systemName: presentation.isFrozen ? "snowflake" : "pause.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(presentation.isFrozen ? Color.white : Color.primary)
                        .frame(width: 28, height: 28)
                        .background(presentation.isFrozen ? Color.orange : Color.secondary.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(presentation.isFrozen ? "恢复大屏同步" : "冻结大屏画面")
            }

            Divider().frame(height: 20)

            Button(action: onExitFocus) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                    Text("展开")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("退出专注模式，展开顶栏")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    }
}
