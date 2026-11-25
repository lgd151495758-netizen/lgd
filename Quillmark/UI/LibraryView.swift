import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var tabManager = TabManager()
    @StateObject private var searchEngine = LibrarySearchEngine()

    private struct PendingClear {
        let meta: DocumentMeta
        let keepTapes: Bool
    }

    private enum FolderFilter: Equatable, Hashable {
        case all
        case pinned
        case folder(UUID)
        case uncategorized
    }

    private enum SortOrder: String, CaseIterable, Identifiable {
        case modifiedDesc
        case createdDesc
        case titleAsc

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .modifiedDesc: return "按最近修改"
            case .createdDesc: return "按创建时间"
            case .titleAsc: return "按名称排序"
            }
        }
    }

    private enum FileImportKind {
        case pdf
        case html
        case backup

        var allowedTypes: [UTType] {
            switch self {
            case .pdf: return [.pdf, .image]
            case .html: return [.html, .folder]
            case .backup: return [.quillmarkBackup, .data]
            }
        }
    }

    @State private var searchText = ""
    @State private var showFullTextSearch = false
    @State private var folderFilter: FolderFilter = .all
    @State private var sortOrder: SortOrder = .modifiedDesc

    @State private var fileImportKind: FileImportKind = .pdf
    @State private var showFileImporter = false
    @State private var showNewNotebookSheet = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var isImporting = false
    @State private var importStatusText = "正在导入文档…"
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var pendingClear: PendingClear?
    @State private var pendingDeleteDocument: DocumentMeta?
    @State private var pendingRestoreURL: URL?
    @State private var backupReminderDismissed = false

    // Folder & document organization alerts
    @State private var showNewFolderPrompt = false
    @State private var folderNameDraft = ""
    @State private var renamingFolder: LibraryFolder?
    @State private var renamingDocument: DocumentMeta?
    @State private var renameDraft = ""
    @State private var exportTargetMeta: DocumentMeta?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 24)]

    private var activeFolderIDForCreation: UUID? {
        if case let .folder(id) = folderFilter {
            return id
        }
        return nil
    }

    private var filteredDocuments: [DocumentMeta] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = library.documents.filter { meta in
            let matchesFolder: Bool
            switch folderFilter {
            case .all:
                matchesFolder = true
            case .pinned:
                matchesFolder = meta.pinned
            case .folder(let id):
                matchesFolder = meta.folderID == id
            case .uncategorized:
                matchesFolder = meta.folderID == nil
            }
            guard matchesFolder else { return false }
            guard !query.isEmpty else { return true }
            if meta.title.localizedCaseInsensitiveContains(query) { return true }
            if let folderName = library.folderName(for: meta.folderID),
               folderName.localizedCaseInsensitiveContains(query) {
                return true
            }
            return false
        }

        return base.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned && !rhs.pinned
            }
            switch sortOrder {
            case .modifiedDesc:
                return lhs.modifiedAt > rhs.modifiedAt
            case .createdDesc:
                return lhs.createdAt > rhs.createdAt
            case .titleAsc:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private var deleteDocumentBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteDocument != nil },
            set: { if !$0 { pendingDeleteDocument = nil } }
        )
    }

    private var restoreBackupBinding: Binding<Bool> {
        Binding(
            get: { pendingRestoreURL != nil },
            set: { if !$0 { pendingRestoreURL = nil } }
        )
    }

    private var dataWarningBinding: Binding<Bool> {
        Binding(
            get: { library.lastDataWarning != nil },
            set: { if !$0 { library.lastDataWarning = nil } }
        )
    }

    var body: some View {
        withSafetyDialogs(
            withImportAndRenameModals(
                mainStack
            )
        )
        .overlay {
            if isImporting { ImportProgressView(text: importStatusText) }
        }
        .onOpenURL { url in
            if url.isFileURL { handleIncomingFileURL(url) }
        }
        .onAppear {
            if let url = library.pendingImportURL {
                library.pendingImportURL = nil
                handleIncomingFileURL(url)
            }
        }
        .onChange(of: library.pendingImportURL) { _, url in
            guard let url else { return }
            library.pendingImportURL = nil
            handleIncomingFileURL(url)
        }
        .onChange(of: library.documents) { _, docs in
            tabManager.syncMetadata(from: docs)
        }
    }

    private var mainStack: some View {
        ZStack {
            // Unmount the Library grid while the document workspace covers the screen so 1-second
            // autosaves never trigger hidden list re-sorts or background PDF thumbnail rasterization.
            if !tabManager.isWorkspaceVisible {
                libraryNavigationStack
            }

            if !tabManager.tabs.isEmpty {
                WorkspaceView(
                    tabManager: tabManager,
                    library: library,
                    onCreateNotebook: { showNewNotebookSheet = true },
                    onImportPDF: { triggerFileImport(.pdf) },
                    onImportHTML: { triggerFileImport(.html) },
                    onImportURL: {
                        urlText = ""
                        showURLPrompt = true
                    }
                )
                .opacity(tabManager.isWorkspaceVisible ? 1 : 0)
                .allowsHitTesting(tabManager.isWorkspaceVisible)
            }
        }
    }

    private var libraryNavigationStack: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !library.documents.isEmpty || !library.folders.isEmpty {
                    folderFilterBar
                    Divider()
                }
                if library.needsBackupReminder && !backupReminderDismissed {
                    backupReminderBanner
                    Divider()
                }
                content
            }
            .navigationTitle("羽签")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "搜索试卷、讲义或文件夹")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 10) {
                        if !tabManager.tabs.isEmpty {
                            Button {
                                tabManager.showWorkspace()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "rectangle.stack")
                                    Text("返回文档 (\(tabManager.tabs.count))")
                                        .font(.subheadline.weight(.medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.16), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("返回已打开的文档标签页")
                        }
                        fullTextSearchButton
                        moreMenu
                        importMenu
                    }
                }
            }
        }
    }

    private var fullTextSearchButton: some View {
        Button {
            showFullTextSearch = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "doc.text.magnifyingglass")
                Text("全文检索")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("跨文档全文检索")
    }

    private func withImportAndRenameModals<V: View>(_ view: V) -> some View {
        view
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: fileImportKind.allowedTypes) { result in
                switch result {
                case .success(let url):
                    handleIncomingFileURL(url)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: 20,
                selectionBehavior: .ordered,
                matching: .images
            )
            .onChange(of: selectedPhotoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                let items = newItems
                selectedPhotoItems = []
                importSelectedPhotos(items)
            }
            .sheet(isPresented: $showFullTextSearch) {
                FullTextSearchSheet(
                    library: library,
                    tabManager: tabManager,
                    engine: searchEngine
                ) { meta, targetPDFPage in
                    tabManager.open(meta, library: library, targetPDFPage: targetPDFPage)
                }
            }
            .sheet(isPresented: $showNewNotebookSheet) {
                NewBlankNotebookSheet(
                    folders: library.folders,
                    defaultFolderID: activeFolderIDForCreation
                ) { title, paper, orientation, pageCount, folderID in
                    createBlankNotebook(title: title, paper: paper, orientation: orientation,
                                        pageCount: pageCount, folderID: folderID)
                }
            }
            .sheet(item: $exportTargetMeta) { meta in
                ExportDocumentSheet(
                    meta: meta,
                    library: library,
                    activeSession: tabManager.session(for: meta.id),
                    liveBridge: tabManager.liveWebBridge(for: meta.id)
                )
            }
            .alert("打开网址", isPresented: $showURLPrompt) {
                TextField("https://example.com", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("取消", role: .cancel) {}
                Button("导入") {
                    if let url = HTMLImportService.normalizedWebURL(urlText) {
                        startImport(.web(url))
                    } else {
                        errorMessage = "网址无效"
                    }
                }
            } message: {
                Text("网页会保存到本地，可离线批注。")
            }
            .alert("新建文件夹", isPresented: $showNewFolderPrompt) {
                TextField("如：九年级几何、期中复习", text: $folderNameDraft)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    createFolder(named: folderNameDraft)
                }
            }
            .alert("重命名文件夹", isPresented: renamingFolderBinding) {
                TextField("文件夹名称", text: $renameDraft)
                Button("取消", role: .cancel) { renamingFolder = nil }
                Button("保存") {
                    if let folder = renamingFolder {
                        do {
                            try library.renameFolder(folder.id, to: renameDraft)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        renamingFolder = nil
                    }
                }
            }
            .alert("重命名文档", isPresented: renamingDocumentBinding) {
                TextField("文档标题", text: $renameDraft)
                Button("取消", role: .cancel) { renamingDocument = nil }
                Button("保存") {
                    if let doc = renamingDocument {
                        do {
                            try library.renameDocument(doc.id, to: renameDraft)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        renamingDocument = nil
                    }
                }
            }
    }

    private func withSafetyDialogs<V: View>(_ view: V) -> some View {
        view
            .alert("操作失败", isPresented: errorBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("完成", isPresented: infoBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(infoMessage ?? "")
            }
            .alert(clearAlertTitle, isPresented: clearBinding) {
                Button("取消", role: .cancel) { pendingClear = nil }
                Button("清空", role: .destructive) {
                    if let target = pendingClear {
                        library.clearInk(for: target.meta.id, keepTapes: target.keepTapes)
                        tabManager.reloadFromDisk(id: target.meta.id)
                        pendingClear = nil
                    }
                }
            } message: {
                Text(clearAlertMessage)
            }
            .confirmationDialog(
                pendingDeleteDocument.map { "永久删除《\($0.title)》？" } ?? "删除文档？",
                isPresented: deleteDocumentBinding,
                titleVisibility: .visible
            ) {
                Button("永久删除", role: .destructive) {
                    if let target = pendingDeleteDocument {
                        tabManager.closeTab(id: target.id)
                        library.delete(target.id)
                        pendingDeleteDocument = nil
                    }
                }
                Button("取消", role: .cancel) {
                    pendingDeleteDocument = nil
                }
            } message: {
                Text("该文档及其全部手写批注、班级图层与便签将被永久删除，无法撤销。")
            }
            .confirmationDialog(
                "选择备份恢复方式",
                isPresented: restoreBackupBinding,
                titleVisibility: .visible
            ) {
                Button("跳过已存在文档（默认）") {
                    if let url = pendingRestoreURL {
                        pendingRestoreURL = nil
                        restoreBackup(from: url, policy: .automatic)
                    }
                }
                Button("覆盖同名原文档（修复或回滚）", role: .destructive) {
                    if let url = pendingRestoreURL {
                        pendingRestoreURL = nil
                        restoreBackup(from: url, policy: .replaceExisting)
                    }
                }
                Button("保留为独立副本") {
                    if let url = pendingRestoreURL {
                        pendingRestoreURL = nil
                        restoreBackup(from: url, policy: .importAsCopy)
                    }
                }
                Button("取消", role: .cancel) {
                    pendingRestoreURL = nil
                }
            } message: {
                Text("若书库中已有同 ID 文档，可选择跳过、用备份覆盖修复，或作为新副本导入。")
            }
            .alert("数据安全提示", isPresented: dataWarningBinding) {
                Button("知道了", role: .cancel) { library.lastDataWarning = nil }
            } message: {
                Text(library.lastDataWarning ?? "")
            }
    }

    // MARK: Folder Filter Strip

    private var folderFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                folderChip(title: "全部", count: library.documents.count, symbol: "square.grid.2x2",
                           selected: folderFilter == .all) {
                    folderFilter = .all
                }

                let pinnedCount = library.documents.filter(\.pinned).count
                if pinnedCount > 0 || folderFilter == .pinned {
                    folderChip(title: "已置顶", count: pinnedCount, symbol: "pin.fill",
                               selected: folderFilter == .pinned) {
                        folderFilter = .pinned
                    }
                }

                ForEach(library.folders) { folder in
                    let count = library.documents.filter { $0.folderID == folder.id }.count
                    folderChip(title: folder.name, count: count, symbol: "folder",
                               selected: folderFilter == .folder(folder.id)) {
                        folderFilter = .folder(folder.id)
                    }
                    .contextMenu {
                        Button {
                            renameDraft = folder.name
                            renamingFolder = folder
                        } label: {
                            Label("重命名文件夹", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            if folderFilter == .folder(folder.id) {
                                folderFilter = .all
                            }
                            library.deleteFolder(folder.id)
                        } label: {
                            Label("删除文件夹（保留文档）", systemImage: "trash")
                        }
                    }
                }

                if !library.folders.isEmpty {
                    let uncategorizedCount = library.documents.filter { $0.folderID == nil }.count
                    folderChip(title: "未分类", count: uncategorizedCount, symbol: "tray",
                               selected: folderFilter == .uncategorized) {
                        folderFilter = .uncategorized
                    }
                }

                Button {
                    folderNameDraft = ""
                    showNewFolderPrompt = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.plus")
                        Text("新建文件夹")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    private func folderChip(title: String, count: Int, symbol: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.caption)
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Content Grid

    @ViewBuilder
    private var content: some View {
        if library.documents.isEmpty {
            ContentUnavailableView {
                Label("还没有文档", systemImage: "doc.richtext")
            } description: {
                Text("导入 PDF 试卷、HTML 网页、作业图片或新建空白数学笔记本，用 Apple Pencil 批注与投屏讲题。")
            } actions: {
                Button("导入 PDF 文件") { triggerFileImport(.pdf) }
                    .buttonStyle(.borderedProminent)
                Button("新建空白笔记本") { showNewNotebookSheet = true }
                    .buttonStyle(.bordered)
                Button("导入 HTML 文件") { triggerFileImport(.html) }
                    .buttonStyle(.bordered)
                Button("从相册导入图片") { showPhotoPicker = true }
                    .buttonStyle(.bordered)
            }
        } else if filteredDocuments.isEmpty {
            ContentUnavailableView {
                Label("没有匹配的文档", systemImage: "magnifyingglass")
            } description: {
                Text("可以切换文件夹、清空搜索词，或直接点击右上角「+」新建/导入文档。")
            } actions: {
                if folderFilter != .all || !searchText.isEmpty {
                    Button("查看全部文档") {
                        folderFilter = .all
                        searchText = ""
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(filteredDocuments) { meta in
                        Button {
                            tabManager.open(meta, library: library)
                        } label: {
                            DocumentCard(meta: meta,
                                         folderName: folderFilter == .all ? library.folderName(for: meta.folderID) : nil,
                                         isOpenInTab: tabManager.isOpen(meta.id),
                                         pdfURL: library.pdfURL(for: meta.id),
                                         thumbnailURL: library.thumbnailURL(for: meta.id))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                tabManager.open(meta, library: library)
                            } label: {
                                Label(tabManager.isOpen(meta.id) ? "切换到此标签页" : "在新标签页打开",
                                      systemImage: "rectangle.badge.plus")
                            }
                            Button {
                                tabManager.saveAllTabs()
                                exportTargetMeta = meta
                            } label: {
                                Label("导出 PDF / 图片…", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                exportSingleBackup(meta)
                            } label: {
                                Label("导出备份包 (.qmbackup)", systemImage: "archivebox")
                            }
                            Divider()
                            Button {
                                renameDraft = meta.title
                                renamingDocument = meta
                            } label: {
                                Label("重命名…", systemImage: "pencil")
                            }
                            Button {
                                togglePin(meta)
                            } label: {
                                Label(meta.pinned ? "取消置顶" : "置顶文档",
                                      systemImage: meta.pinned ? "pin.slash" : "pin")
                            }
                            Menu {
                                Button {
                                    moveDocument(meta, toFolder: nil)
                                } label: {
                                    Label("未分类", systemImage: meta.folderID == nil ? "checkmark" : "tray")
                                }
                                ForEach(library.folders) { folder in
                                    Button {
                                        moveDocument(meta, toFolder: folder.id)
                                    } label: {
                                        Label(folder.name,
                                              systemImage: meta.folderID == folder.id ? "checkmark" : "folder")
                                    }
                                }
                                Divider()
                                Button {
                                    folderNameDraft = ""
                                    showNewFolderPrompt = true
                                } label: {
                                    Label("新建文件夹…", systemImage: "folder.badge.plus")
                                }
                            } label: {
                                Label("移动到文件夹", systemImage: "folder")
                            }
                            Divider()
                            Button {
                                pendingClear = PendingClear(meta: meta, keepTapes: true)
                            } label: {
                                Label("清空手写（保留胶带）", systemImage: "eraser.line.dashed")
                            }
                            Button {
                                pendingClear = PendingClear(meta: meta, keepTapes: false)
                            } label: {
                                Label("清空全部批注", systemImage: "trash.slash")
                            }
                            Button {
                                duplicateDocument(meta)
                            } label: {
                                Label("复制副本", systemImage: "doc.on.doc")
                            }
                            Divider()
                            Button(role: .destructive) {
                                pendingDeleteDocument = meta
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    // MARK: Backup Safety Reminder Banner

    private var backupReminderBanner: some View {
        let statusText: String
        if let days = library.daysSinceLastBackup {
            statusText = "已 \(days) 天未备份（免费签名每 7 天需续签，建议定期保存备份防丢笔记）"
        } else {
            statusText = "尚未备份文档库（免费签名重装易丢本地数据，建议一键备份到「文件」App 或网盘）"
        }
        return HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.timemachine")
                .foregroundStyle(.orange)
            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("本地备份") {
                saveLocalRotatingBackup()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)

            Button("分享导出") {
                exportFullLibraryBackup()
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                backupReminderDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("暂时关闭备份提醒")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: Toolbar Menus

    private var moreMenu: some View {
        Menu {
            Section("排序方式") {
                ForEach(SortOrder.allCases) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        Label(order.displayName, systemImage: sortOrder == order ? "checkmark" : "arrow.up.arrow.down")
                    }
                }
            }
            Section("备份与迁移") {
                Button {
                    saveLocalRotatingBackup()
                } label: {
                    Label("保存到「文件」App 本地备份", systemImage: "externaldrive.badge.checkmark")
                }
                .disabled(library.documents.isEmpty)

                Button {
                    exportFullLibraryBackup()
                } label: {
                    Label("全库打包导出分享 (.qmbackup)", systemImage: "externaldrive.badge.plus")
                }
                .disabled(library.documents.isEmpty)

                Button {
                    triggerFileImport(.backup)
                } label: {
                    Label("导入备份包恢复…", systemImage: "arrow.down.doc")
                }
            }
            Section("分类管理") {
                Button {
                    folderNameDraft = ""
                    showNewFolderPrompt = true
                } label: {
                    Label("新建文件夹…", systemImage: "folder.badge.plus")
                }
            }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
    }

    private var importMenu: some View {
        Menu {
            Button {
                showNewNotebookSheet = true
            } label: {
                Label("新建空白数学笔记本…", systemImage: "note.text.badge.plus")
            }
            Divider()
            Button {
                triggerFileImport(.pdf)
            } label: {
                Label("导入 PDF / 图片文件…", systemImage: "doc.fill")
            }
            Button {
                showPhotoPicker = true
            } label: {
                Label("从相册导入作业图片…", systemImage: "photo.on.rectangle.angled")
            }
            Button {
                triggerFileImport(.html)
            } label: {
                Label("导入 HTML 文件…", systemImage: "doc.badge.plus")
            }
            Button {
                urlText = ""
                showURLPrompt = true
            } label: {
                Label("打开网址…", systemImage: "globe")
            }
            Divider()
            Button {
                triggerFileImport(.backup)
            } label: {
                Label("恢复备份包 (.qmbackup)…", systemImage: "archivebox")
            }
        } label: {
            Label("导入", systemImage: "plus")
        }
    }

    // MARK: Bindings & Actions

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var infoBinding: Binding<Bool> {
        Binding(get: { infoMessage != nil }, set: { if !$0 { infoMessage = nil } })
    }

    private var clearBinding: Binding<Bool> {
        Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } })
    }

    private var renamingFolderBinding: Binding<Bool> {
        Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })
    }

    private var renamingDocumentBinding: Binding<Bool> {
        Binding(get: { renamingDocument != nil }, set: { if !$0 { renamingDocument = nil } })
    }

    private var clearAlertTitle: String {
        guard let target = pendingClear else { return "清空手写" }
        return target.keepTapes ? "清空手写（保留胶带）" : "清空全部批注"
    }

    private var clearAlertMessage: String {
        guard let target = pendingClear else { return "" }
        if target.keepTapes {
            return "将清空《\(target.meta.title)》的所有手写与图形，已放置的遮挡胶带会保留并恢复为遮盖状态。"
        } else {
            return "将清空《\(target.meta.title)》的所有手写、图形与遮挡胶带，此操作无法撤销。"
        }
    }

    private func triggerFileImport(_ kind: FileImportKind) {
        fileImportKind = kind
        showFileImporter = true
    }

    private func createFolder(named name: String) {
        do {
            let created = try library.createFolder(name: name)
            folderFilter = .folder(created.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func togglePin(_ meta: DocumentMeta) {
        do {
            try library.togglePin(meta.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveDocument(_ meta: DocumentMeta, toFolder folderID: UUID?) {
        do {
            try library.moveDocument(meta.id, toFolder: folderID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicateDocument(_ meta: DocumentMeta) {
        tabManager.saveAllTabs()
        do {
            _ = try library.duplicate(meta.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createBlankNotebook(title: String,
                                     paper: ScratchpadPaperStyle,
                                     orientation: NotebookOrientation,
                                     pageCount: Int,
                                     folderID: UUID?) {
        do {
            let meta = try BlankNotebookService.createNotebook(
                title: title,
                paper: paper,
                orientation: orientation,
                pageCount: pageCount,
                folderID: folderID,
                into: library
            )
            tabManager.open(meta, library: library)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importSelectedPhotos(_ items: [PhotosPickerItem]) {
        guard !isImporting else { return }
        importStatusText = "正在合成图片 PDF…"
        isImporting = true
        let targetFolder = activeFolderIDForCreation
        Task { @MainActor in
            defer { isImporting = false }
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }
            guard !images.isEmpty else {
                errorMessage = "未能读取所选图片"
                return
            }
            do {
                let meta = try ImageImportService.importImages(images, folderID: targetFolder, into: library)
                tabManager.open(meta, library: library)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleIncomingFileURL(_ url: URL) {
        if BackupArchiveService.isBackupFile(url) {
            if library.documents.isEmpty {
                restoreBackup(from: url, policy: .automatic)
            } else {
                pendingRestoreURL = url
            }
        } else {
            startImport(.file(url))
        }
    }

    private func restoreBackup(from url: URL, policy: BackupArchiveService.DuplicatePolicy = .automatic) {
        guard !isImporting else { return }
        importStatusText = "正在流式恢复备份包…"
        isImporting = true
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let summary = try await BackupArchiveService.importBackupAsync(
                    from: url,
                    into: library,
                    duplicatePolicy: policy
                )
                if summary.replacedExistingDocuments > 0 {
                    tabManager.reloadAllFromDisk()
                }
                if summary.importedDocuments == 1,
                   summary.replacedExistingDocuments == 0,
                   let id = summary.firstImportedID,
                   let restored = library.documents.first(where: { $0.id == id }) {
                    tabManager.open(restored, library: library)
                } else {
                    infoMessage = summary.userMessage
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func exportSingleBackup(_ meta: DocumentMeta) {
        guard !isImporting else { return }
        tabManager.saveAllTabs()
        importStatusText = "正在打包文档备份…"
        isImporting = true
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let url = try await BackupArchiveService.exportDocumentAsync(meta.id, from: library)
                ShareSheetPresenter.present(fileURL: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func exportFullLibraryBackup() {
        guard !isImporting else { return }
        tabManager.saveAllTabs()
        importStatusText = "正在流式打包全库备份…"
        isImporting = true
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let url = try await BackupArchiveService.exportFullLibraryAsync(from: library, saveToLocalBackups: false)
                ShareSheetPresenter.present(fileURL: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveLocalRotatingBackup() {
        guard !isImporting else { return }
        tabManager.saveAllTabs()
        importStatusText = "正在保存到本地备份目录…"
        isImporting = true
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let url = try await BackupArchiveService.exportFullLibraryAsync(from: library, saveToLocalBackups: true)
                infoMessage = "已保存本地备份：\(url.lastPathComponent)\n可在 iPad「文件」App → 我的 iPad → Quillmark → Backups 中查看或拷贝到网盘（自动保留最近 3 份）。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startImport(_ source: ImportSource) {
        guard !isImporting else { return }
        importStatusText = "正在导入文档…"
        isImporting = true
        let targetFolder = activeFolderIDForCreation
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let meta = try await HTMLImportService.importDocument(from: source, into: library,
                                                                      folderID: targetFolder)
                if case let .file(url) = source {
                    library.cleanupInboxFileIfNeeded(url)
                }
                tabManager.open(meta, library: library)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct DocumentCard: View {
    let meta: DocumentMeta
    let folderName: String?
    let isOpenInTab: Bool
    let pdfURL: URL
    let thumbnailURL: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemBackground))
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(8)
                    } else {
                        Image(systemName: meta.layout == .pdf ? "doc.fill" : "doc.richtext")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    if meta.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Color.orange, in: Circle())
                    }
                    if isOpenInTab {
                        Text("已打开")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
                .padding(8)
            }
            .aspectRatio(0.75, contentMode: .fit)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

            Text(meta.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            HStack(spacing: 5) {
                if let folderName {
                    Text(folderName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .lineLimit(1)
                }
                Text("\(meta.layout.displayName) · \(meta.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .task(id: meta.modifiedAt) {
            let thumbURL = thumbnailURL
            let sourcePDFURL = pdfURL
            let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
                if let cached = UIImage(contentsOfFile: thumbURL.path) {
                    return cached
                }
                guard let page = PDFDocument(url: sourcePDFURL)?.page(at: 0) else { return nil }
                let rendered = page.thumbnail(of: CGSize(width: 400, height: 540), for: .cropBox)
                if let png = rendered.pngData() {
                    try? png.write(to: thumbURL, options: .atomic)
                }
                return rendered
            }.value
            if !Task.isCancelled, let loaded {
                thumbnail = loaded
            }
        }
    }
}

private struct ImportProgressView: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(text)
                    .font(.callout)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
