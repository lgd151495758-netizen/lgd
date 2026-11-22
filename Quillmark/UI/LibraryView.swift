import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var tabManager = TabManager()

    private struct PendingClear {
        let meta: DocumentMeta
        let keepTapes: Bool
    }

    @State private var showPDFImporter = false
    @State private var showHTMLImporter = false
    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var pendingClear: PendingClear?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 24)]

    var body: some View {
        ZStack {
            NavigationStack {
                content
                    .navigationTitle("羽签")
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
                                importMenu
                            }
                        }
                    }
                    .fileImporter(isPresented: $showHTMLImporter, allowedContentTypes: [.html, .folder]) { result in
                        switch result {
                        case .success(let url): startImport(.file(url))
                        case .failure(let error): errorMessage = error.localizedDescription
                        }
                    }
            }
            .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url): startImport(.file(url))
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }

            if !tabManager.tabs.isEmpty {
                WorkspaceView(
                    tabManager: tabManager,
                    library: library,
                    onImportPDF: { showPDFImporter = true },
                    onImportHTML: { showHTMLImporter = true },
                    onImportURL: {
                        urlText = ""
                        showURLPrompt = true
                    }
                )
                .opacity(tabManager.isWorkspaceVisible ? 1 : 0)
                .allowsHitTesting(tabManager.isWorkspaceVisible)
            }
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
        .alert("操作失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
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
        .overlay {
            if isImporting { ImportProgressView() }
        }
        .onOpenURL { url in
            if url.isFileURL { startImport(.file(url)) }
        }
        .onAppear {
            if let url = library.pendingImportURL {
                library.pendingImportURL = nil
                startImport(.file(url))
            }
        }
        .onChange(of: library.pendingImportURL) { _, url in
            guard let url else { return }
            library.pendingImportURL = nil
            startImport(.file(url))
        }
        .onChange(of: library.documents) { _, docs in
            tabManager.syncMetadata(from: docs)
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.documents.isEmpty {
            ContentUnavailableView {
                Label("还没有文档", systemImage: "doc.richtext")
            } description: {
                Text("导入 PDF 试卷、HTML 网页或打开网址，用 Apple Pencil 直接批注、画几何图形和投屏讲题。")
            } actions: {
                Button("导入 PDF 文件") { showPDFImporter = true }
                    .buttonStyle(.borderedProminent)
                Button("导入 HTML 文件") { showHTMLImporter = true }
                    .buttonStyle(.bordered)
                Button("打开网址") {
                    urlText = ""
                    showURLPrompt = true
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(library.documents) { meta in
                        Button {
                            tabManager.open(meta, library: library)
                        } label: {
                            DocumentCard(meta: meta,
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
                                tabManager.closeTab(id: meta.id)
                                library.delete(meta.id)
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

    private var importMenu: some View {
        Menu {
            Button {
                showPDFImporter = true
            } label: {
                Label("导入 PDF 文件…", systemImage: "doc.fill")
            }
            Button {
                showHTMLImporter = true
            } label: {
                Label("导入 HTML 文件…", systemImage: "doc.badge.plus")
            }
            Button {
                urlText = ""
                showURLPrompt = true
            } label: {
                Label("打开网址…", systemImage: "globe")
            }
        } label: {
            Label("导入", systemImage: "plus")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var clearBinding: Binding<Bool> {
        Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } })
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

    private func duplicateDocument(_ meta: DocumentMeta) {
        do {
            _ = try library.duplicate(meta.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startImport(_ source: ImportSource) {
        guard !isImporting else { return }
        isImporting = true
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let meta = try await HTMLImportService.importDocument(from: source, into: library)
                tabManager.open(meta, library: library)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct DocumentCard: View {
    let meta: DocumentMeta
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
                if isOpenInTab {
                    Text("已打开")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .padding(8)
                }
            }
            .aspectRatio(0.75, contentMode: .fit)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

            Text(meta.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            Text("\(meta.layout.displayName) · \(meta.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: meta.modifiedAt) {
            // Give the editor a moment to write the snapshot taken when it closes.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let image = UIImage(contentsOfFile: thumbnailURL.path) {
                thumbnail = image
            } else {
                thumbnail = PDFDocument(url: pdfURL)?.page(at: 0)?.thumbnail(of: CGSize(width: 400, height: 540), for: .cropBox)
            }
        }
    }
}

private struct ImportProgressView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("正在导入文档…")
                    .font(.callout)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
