import PDFKit
import SwiftUI
import UIKit

/// Safely presents UIKit's native share sheet (`UIActivityViewController`) on iPad with explicit
/// popover anchoring on the topmost presented view controller so it never crashes on iPadOS.
@MainActor
enum ShareSheetPresenter {
    static func present(fileURL: URL) {
        guard let host = topViewController() else { return }
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        host.present(activityVC, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? scenes.flatMap { $0.windows }.first
        var current = keyWindow?.rootViewController
        while let presented = current?.presentedViewController {
            current = presented
        }
        return current
    }
}

/// Export & backup sheet for any PDF or HTML document (triggered from editor top bar or Library).
struct ExportDocumentSheet: View {
    let meta: DocumentMeta
    let library: LibraryStore
    let activeSession: DocumentSession?
    let liveBridge: WebInkBridge?

    @Environment(\.dismiss) private var dismiss

    @State private var options: ExportOptions
    @State private var isExporting = false
    @State private var exportResult: ExportResult?
    @State private var backupURL: URL?
    @State private var errorMessage: String?

    init(meta: DocumentMeta,
         library: LibraryStore,
         activeSession: DocumentSession? = nil,
         liveBridge: WebInkBridge? = nil) {
        self.meta = meta
        self.library = library
        self.activeSession = activeSession
        self.liveBridge = liveBridge
        var initial = ExportOptions()
        initial.currentPageIndex = activeSession?.activeDocumentPageIndex ?? 0
        _options = State(initialValue: initial)
    }

    private var currentAnnotations: DocumentAnnotations {
        if let activeSession {
            activeSession.saveNow()
            var copy = activeSession.annotations
            copy.syncActiveLayerFromTopLevel()
            return copy
        }
        return library.loadAnnotations(for: meta.id)
    }

    var body: some View {
        let annotations = currentAnnotations
        let nonEmptyScratchCount = annotations.nonEmptyScratchpadPages.count

        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: meta.layout == .live ? "doc.richtext" : "doc.fill")
                            .font(.title2)
                            .foregroundStyle(meta.layout == .live ? Color.accentColor : Color.red.opacity(0.85))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(meta.title)
                                .font(.headline)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text(meta.layout.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if annotations.hasMultipleLayers {
                                    Text("当前图层：\(annotations.activeLayerName)")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section("导出格式与内容") {
                    Picker("导出格式", selection: $options.format) {
                        ForEach(ExportFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }

                    Picker("遮盖胶带处理", selection: $options.tapeMode) {
                        ForEach(ExportTapeMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    if nonEmptyScratchCount > 0 && options.format != .currentPagePNG {
                        Toggle("附带 \(nonEmptyScratchCount) 页非空演算便签", isOn: $options.includeScratchpad)
                    }
                }

                Section {
                    Button {
                        runExport()
                    } label: {
                        HStack {
                            Spacer()
                            if isExporting {
                                ProgressView()
                                    .padding(.trailing, 6)
                                Text("正在生成导出文件…")
                            } else {
                                Label("生成并分享", systemImage: "square.and.arrow.up")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(isExporting)

                    if let exportResult {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("已生成：\(exportResult.filename)")
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                            }
                            Text("\(exportResult.pageCount) 页 · \(exportResult.formattedSize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ShareLink(item: exportResult.fileURL) {
                                Label("再次打开系统分享菜单", systemImage: "arrow.up.doc")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Button {
                        runSingleBackupExport()
                    } label: {
                        Label("导出便携备份包 (.\(BackupArchiveService.fileExtension))", systemImage: "archivebox")
                    }
                    .disabled(isExporting)

                    if let backupURL {
                        ShareLink(item: backupURL) {
                            Label("分享备份包：\(backupURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                                .font(.subheadline)
                        }
                    }
                } header: {
                    Text("课后归档与换机备份")
                } footer: {
                    Text("便携备份包完整保留原试卷/网页、全部班级图层、遮盖胶带与便签，可在另一台 iPad 或重签安装后无损恢复。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("导出与分享")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func runExport() {
        guard !isExporting else { return }
        errorMessage = nil
        isExporting = true
        let annotations = currentAnnotations
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let result = try await DocumentExportService.export(
                    meta: meta,
                    annotations: annotations,
                    library: library,
                    options: options,
                    liveBridge: liveBridge
                )
                exportResult = result
                ShareSheetPresenter.present(fileURL: result.fileURL)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runSingleBackupExport() {
        guard !isExporting else { return }
        errorMessage = nil
        activeSession?.saveNow()
        do {
            let url = try BackupArchiveService.exportDocument(meta.id, from: library)
            backupURL = url
            ShareSheetPresenter.present(fileURL: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Sheet for creating a crisp pure-vector blank math notebook (grid / dot / graph / blank).
struct NewBlankNotebookSheet: View {
    let folders: [LibraryFolder]
    let defaultFolderID: UUID?
    let onCreate: (String, ScratchpadPaperStyle, NotebookOrientation, Int, UUID?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = BlankNotebookService.defaultNotebookTitle()
    @State private var paper: ScratchpadPaperStyle = .grid
    @State private var orientation: NotebookOrientation = .portraitA4
    @State private var pageCount: Int = 3
    @State private var selectedFolderID: UUID?

    init(folders: [LibraryFolder],
         defaultFolderID: UUID?,
         onCreate: @escaping (String, ScratchpadPaperStyle, NotebookOrientation, Int, UUID?) -> Void) {
        self.folders = folders
        self.defaultFolderID = defaultFolderID
        self.onCreate = onCreate
        _selectedFolderID = State(initialValue: defaultFolderID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("笔记本名称") {
                    TextField("输入名称，如：九上二次函数板书", text: $title)
                }

                Section("纸张样式") {
                    Picker("纸张底纹", selection: $paper) {
                        ForEach(ScratchpadPaperStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("页面比例", selection: $orientation) {
                        ForEach(NotebookOrientation.allCases) { orient in
                            Text(orient.displayName).tag(orient)
                        }
                    }
                    .pickerStyle(.segmented)

                    Stepper("初始页数：\(pageCount) 页", value: $pageCount, in: 1...20)
                }

                if !folders.isEmpty {
                    Section("所属文件夹") {
                        Picker("文件夹", selection: $selectedFolderID) {
                            Text("未分类").tag(UUID?.none)
                            ForEach(folders) { folder in
                                Text(folder.name).tag(UUID?.some(folder.id))
                            }
                        }
                    }
                }
            }
            .navigationTitle("新建空白数学笔记本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        onCreate(title, paper, orientation, pageCount, selectedFolderID)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

/// Compact popover in the editor top bar for switching & managing multi-class annotation layers.
struct ClassLayersPopover: View {
    @ObservedObject var session: DocumentSession
    let dismiss: () -> Void

    @State private var creatingTemplate: DocumentAnnotations.NewLayerTemplate?
    @State private var newLayerName = ""
    @State private var renamingLayerID: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("班级板书图层", systemImage: "square.3.layers.3d")
                    .font(.headline)
                Spacer()
                Text("\(session.layers.count) 层")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("同一份试卷可按班级切换独立板书，无需复制占用空间；新建班级时可自动继承遮盖胶带。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(session.layers) { layer in
                        let isActive = layer.id == session.activeLayerID
                        if renamingLayerID == layer.id {
                            HStack(spacing: 6) {
                                TextField("图层名称", text: $renameText)
                                    .textFieldStyle(.roundedBorder)
                                Button("保存") {
                                    session.renameLayer(id: layer.id, to: renameText)
                                    renamingLayerID = nil
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                Button("取消") {
                                    renamingLayerID = nil
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        } else {
                            HStack(spacing: 8) {
                                Button {
                                    session.switchLayer(to: layer.id)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(layer.name)
                                                .font(.subheadline.weight(isActive ? .semibold : .regular))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text("\(layer.mainStrokeCount) 笔批注")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    renameText = layer.name
                                    renamingLayerID = layer.id
                                    creatingTemplate = nil
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 26, height: 26)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("重命名图层 \(layer.name)")

                                if session.layers.count > 1 {
                                    Button(role: .destructive) {
                                        session.deleteLayer(id: layer.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundStyle(.red.opacity(0.85))
                                            .frame(width: 26, height: 26)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("删除图层 \(layer.name)")
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(isActive ? Color.accentColor.opacity(0.10) : Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .frame(maxHeight: 220)

            Divider()

            if let template = creatingTemplate {
                VStack(alignment: .leading, spacing: 8) {
                    Text(templateTitle(template))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    HStack(spacing: 6) {
                        TextField("输入班级名称，如：九(2)班", text: $newLayerName)
                            .textFieldStyle(.roundedBorder)
                        Button("创建") {
                            session.createLayer(name: newLayerName, template: template)
                            creatingTemplate = nil
                            newLayerName = ""
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("取消") {
                            creatingTemplate = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Button {
                        newLayerName = "班级 \(session.layers.count + 1)"
                        creatingTemplate = .keepTapesFromCurrent
                        renamingLayerID = nil
                    } label: {
                        Label("新建班级图层（继承遮盖胶带）", systemImage: "plus.rectangle.on.rectangle")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)

                    HStack(spacing: 8) {
                        Button {
                            newLayerName = "班级 \(session.layers.count + 1)"
                            creatingTemplate = .blank
                            renamingLayerID = nil
                        } label: {
                            Label("空白图层", systemImage: "doc.badge.plus")
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            newLayerName = "\(session.activeLayerName) 副本"
                            creatingTemplate = .duplicateCurrent
                            renamingLayerID = nil
                        } label: {
                            Label("复制当前层", systemImage: "doc.on.doc")
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            session.refreshLayerSummaries()
        }
    }

    private func templateTitle(_ template: DocumentAnnotations.NewLayerTemplate) -> String {
        switch template {
        case .keepTapesFromCurrent: return "新建班级图层（自动保留胶带并恢复遮盖）"
        case .blank: return "新建空白图层"
        case .duplicateCurrent: return "复制当前图层全部笔迹"
        }
    }
}

/// Thumbnail grid popover opened by tapping the PDF page indicator (`2/8`) for instant page jumping
/// and inserting vector blank calculation pages directly after the current page.
struct PDFPageNavigatorPopover: View {
    @ObservedObject var session: DocumentSession
    let dismiss: () -> Void

    @State private var insertError: String?

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 112), spacing: 10)]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("页面导航（共 \(session.pdfPageCount) 页）", systemImage: "rectangle.grid.2x2")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(ScratchpadPaperStyle.allCases) { style in
                        Button {
                            insertBlankPage(style: style)
                        } label: {
                            Label("插入\(style.displayName)页", systemImage: "doc.badge.plus")
                        }
                    }
                } label: {
                    Label("插空白页", systemImage: "plus.rectangle")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
            }

            if let insertError {
                Text(insertError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(0..<session.pdfPageCount, id: \.self) { idx in
                            let isCurrent = idx == session.activeDocumentPageIndex
                            let hasInk = !session.strokes(onPage: idx).isEmpty
                            Button {
                                session.jumpToPDFPage(idx)
                                dismiss()
                            } label: {
                                PDFPageThumbCell(
                                    pdfDocument: session.pdfDocument,
                                    pageIndex: idx,
                                    isCurrent: isCurrent,
                                    hasInk: hasInk
                                )
                            }
                            .buttonStyle(.plain)
                            .id(idx)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 380)
                .onAppear {
                    proxy.scrollTo(session.activeDocumentPageIndex, anchor: .center)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func insertBlankPage(style: ScratchpadPaperStyle) {
        insertError = nil
        do {
            _ = try session.insertBlankPDFPage(after: session.activeDocumentPageIndex, paper: style)
            dismiss()
        } catch {
            insertError = error.localizedDescription
        }
    }
}

private struct PDFPageThumbCell: View {
    let pdfDocument: PDFDocument?
    let pageIndex: Int
    let isCurrent: Bool
    let hasInk: Bool
    @State private var thumb: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.secondarySystemBackground))
                    .overlay {
                        if let thumb {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(3)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isCurrent ? Color.accentColor : Color.secondary.opacity(0.25),
                                    lineWidth: isCurrent ? 2.2 : 0.8)
                    )
                    .aspectRatio(0.75, contentMode: .fit)

                if hasInk {
                    Image(systemName: "pencil.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .background(Circle().fill(Color(.systemBackground)))
                        .padding(4)
                }
            }

            Text("第 \(pageIndex + 1) 页")
                .font(.caption2.monospacedDigit().weight(isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
        .task(id: "\(pdfDocument?.pageCount ?? 0)-\(pageIndex)") {
            guard let page = pdfDocument?.page(at: pageIndex) else { return }
            thumb = page.thumbnail(of: CGSize(width: 180, height: 240), for: .cropBox)
        }
    }
}
