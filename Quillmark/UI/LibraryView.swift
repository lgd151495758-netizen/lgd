import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var path: [DocumentMeta] = []
    @State private var showFileImporter = false
    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var isImporting = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 24)]

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("羽签")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { importMenu }
                }
                .navigationDestination(for: DocumentMeta.self) { meta in
                    EditorView(meta: meta, library: library)
                }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.html, .folder]) { result in
            switch result {
            case .success(let url): startImport(.file(url))
            case .failure(let error): errorMessage = error.localizedDescription
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
        .alert("导入失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay {
            if isImporting { ImportProgressView() }
        }
        .onOpenURL { url in
            if url.isFileURL { startImport(.file(url)) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.documents.isEmpty {
            ContentUnavailableView {
                Label("还没有文档", systemImage: "doc.richtext")
            } description: {
                Text("导入 HTML 文件或打开网址，网页里的按钮照常可用，用 Apple Pencil 直接在上面书写。")
            } actions: {
                Button("导入 HTML 文件") { showFileImporter = true }
                    .buttonStyle(.borderedProminent)
                Button("打开网址") { urlText = ""; showURLPrompt = true }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(library.documents) { meta in
                        NavigationLink(value: meta) {
                            DocumentCard(meta: meta, pdfURL: library.pdfURL(for: meta.id),
                                         thumbnailURL: library.thumbnailURL(for: meta.id))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
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
                showFileImporter = true
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

    private func startImport(_ source: ImportSource) {
        guard !isImporting else { return }
        isImporting = true
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let meta = try await HTMLImportService.importDocument(from: source, into: library)
                path.append(meta)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct DocumentCard: View {
    let meta: DocumentMeta
    let pdfURL: URL
    let thumbnailURL: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    Image(systemName: "doc.richtext")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
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
                Text("正在保存网页…")
                    .font(.callout)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
