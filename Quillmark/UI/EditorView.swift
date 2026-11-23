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

    let onCreateNotebook: () -> Void
    let onImportPDF: () -> Void
    let onImportHTML: () -> Void
    let onImportURL: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let activeTab = tabManager.activeTab {
                ToolbarView(session: activeTab.session)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
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
        .background(Color(.systemBackground))
        .ignoresSafeArea(edges: .bottom)
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
                    session.clearAllDocumentHandwriting(keepTapes: true)
                } label: {
                    Label("清空手写（保留胶带）", systemImage: "eraser.line.dashed")
                }
                Button(role: .destructive) {
                    session.clearAllDocumentHandwriting(keepTapes: false)
                } label: {
                    Label("清空全部批注（含胶带）", systemImage: "trash")
                }
            } else {
                if session.pdfPageCount > 1 {
                    Button {
                        session.clearHandwriting(onPage: session.activeDocumentPageIndex, keepTapes: true)
                    } label: {
                        Label("清空第 \(session.activeDocumentPageIndex + 1) 页手写（保留胶带）",
                              systemImage: "eraser.line.dashed")
                    }
                    Button {
                        session.clearAllDocumentHandwriting(keepTapes: true)
                    } label: {
                        Label("清空整份 PDF 手写（保留胶带）", systemImage: "doc.on.doc")
                    }
                } else {
                    Button {
                        session.clearAllDocumentHandwriting(keepTapes: true)
                    } label: {
                        Label("清空手写（保留胶带）", systemImage: "eraser.line.dashed")
                    }
                }
                Button(role: .destructive) {
                    session.clearAllDocumentHandwriting(keepTapes: false)
                } label: {
                    Label("清空全部批注（含胶带）", systemImage: "trash")
                }
            }
            if session.isScratchpadOpen {
                Divider()
                Button {
                    session.clearCurrentScratchpadPage()
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

            Toggle("投屏仅显示内容", isOn: $presentation.contentOnly)

            Text("开启后，外接屏幕（如 OfflineMirror / AirPlay）只显示工具栏下方的文档与批注内容，标签栏与工具栏仅在 iPad 上显示。")
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
            }

            if presentation.isExternalDisplayConnected {
                Toggle("冻结大屏画面", isOn: $presentation.isFrozen)
                Text("冻结后学生端大屏保持当前题目不变，你可以在 iPad 上自由切换标签页或翻页看答案，关闭后立即恢复同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
