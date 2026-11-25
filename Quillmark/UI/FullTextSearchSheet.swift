import SwiftUI

/// Home-screen cross-document full-text search modal (searches across all PDFs and HTML/web docs).
struct FullTextSearchSheet: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var tabManager: TabManager
    @ObservedObject var engine: LibrarySearchEngine
    let onOpenDocument: (DocumentMeta, Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFieldFocused: Bool
    @State private var expandedDocumentIDs: Set<UUID> = []

    private var activeTokens: [String] {
        LibrarySearchMatcher.tokenize(engine.query)
    }

    private var hasActiveQuery: Bool {
        !activeTokens.isEmpty
    }

    private var hasActiveScopeFilter: Bool {
        engine.documentFilter != .all || engine.folderFilterID != nil
    }

    private var selectedFolderName: String {
        guard let folderID = engine.folderFilterID else { return "全部文件夹" }
        return library.folderName(for: folderID) ?? "全部文件夹"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchHeader
                Divider()
                if engine.isRunningOCR || engine.unindexedImagePDFCount > 0 {
                    ocrBanner
                    Divider()
                }
                resultsArea
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("跨文档全文检索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if let folderID = engine.folderFilterID,
               !library.folders.contains(where: { $0.id == folderID }) {
                engine.folderFilterID = nil
            }
            engine.prepareIndex(for: library)
            if hasActiveQuery {
                engine.scheduleSearch(in: library, debounceNanoseconds: 0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                isSearchFieldFocused = true
            }
        }
        .onDisappear {
            engine.cancelActiveTasks()
        }
        .onChange(of: engine.query) { _, _ in
            expandedDocumentIDs.removeAll()
            engine.scheduleSearch(in: library)
        }
        .onChange(of: engine.documentFilter) { _, _ in
            engine.scheduleSearch(in: library, debounceNanoseconds: 0)
        }
        .onChange(of: engine.folderFilterID) { _, _ in
            engine.scheduleSearch(in: library, debounceNanoseconds: 0)
        }
    }

    // MARK: Search Header & Scope Filters

    private var searchHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("输入关键词搜索所有 PDF 试卷、HTML 讲义正文…", text: $engine.query)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        engine.recordRecentQuery(engine.query)
                        engine.scheduleSearch(in: library, debounceNanoseconds: 0)
                    }

                if engine.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }

                if !engine.query.isEmpty {
                    Button {
                        engine.query = ""
                        isSearchFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索关键词")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            HStack(spacing: 8) {
                ForEach(SearchDocumentFilter.allCases) { filter in
                    scopeChip(
                        title: filter.displayName,
                        selected: engine.documentFilter == filter
                    ) {
                        engine.documentFilter = filter
                    }
                }

                if !library.folders.isEmpty {
                    folderFilterMenu
                }

                Spacer(minLength: 6)

                indexStatusLabel
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    private func scopeChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var folderFilterMenu: some View {
        Menu {
            Button {
                engine.folderFilterID = nil
            } label: {
                Label("全部文件夹", systemImage: engine.folderFilterID == nil ? "checkmark" : "folder")
            }
            Divider()
            ForEach(library.folders) { folder in
                Button {
                    engine.folderFilterID = folder.id
                } label: {
                    Label(folder.name, systemImage: engine.folderFilterID == folder.id ? "checkmark" : "folder")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.caption2)
                Text(selectedFolderName)
                    .font(.caption.weight(engine.folderFilterID != nil ? .semibold : .regular))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(engine.folderFilterID != nil ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                engine.folderFilterID != nil ? Color.accentColor.opacity(0.14) : Color(.tertiarySystemFill),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    private var indexStatusLabel: some View {
        HStack(spacing: 5) {
            if engine.isIndexing {
                ProgressView()
                    .controlSize(.mini)
                Text("正在索引 \(engine.indexedCount)/\(engine.totalDocumentCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text("已索引 \(engine.totalDocumentCount) 份文档")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Optional Scanned-PDF OCR Banner

    private var ocrBanner: some View {
        HStack(spacing: 10) {
            if engine.isRunningOCR {
                ProgressView()
                    .controlSize(.small)
                Text(engine.ocrProgressText ?? "正在识别扫描件文字…")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("停止") {
                    engine.cancelOCR()
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Image(systemName: "doc.viewfinder")
                    .foregroundStyle(.orange)
                Text("检测到 \(engine.unindexedImagePDFCount) 份图片/扫描件 PDF 无内嵌文字，识别后可纳入全文检索")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("识别扫描件") {
                    engine.runOCRForImagePDFs(in: library)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: Results & Empty States

    @ViewBuilder
    private var resultsArea: some View {
        if library.documents.isEmpty {
            ContentUnavailableView {
                Label("文档库为空", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("先导入 PDF 试卷或 HTML 互动课件，即可在这里跨文档全文检索题目与知识点。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasActiveQuery {
            landingGuidanceView
        } else if engine.isSearching && engine.results.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("正在跨文档全文检索…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if engine.results.isEmpty {
            noMatchesView
        } else {
            matchedResultsList
        }
    }

    private var landingGuidanceView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !engine.recentQueries.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("最近搜索", systemImage: "clock.arrow.circlepath")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("清空") {
                                engine.clearRecentQueries()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(engine.recentQueries, id: \.self) { recent in
                                    Button {
                                        engine.query = recent
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "magnifyingglass")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text(recent)
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color(.systemBackground), in: Capsule())
                                        .overlay(
                                            Capsule().stroke(Color(.separator).opacity(0.35), lineWidth: 0.8)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("全文检索说明", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    guideRow(
                        symbol: "doc.fill",
                        tint: .red,
                        title: "PDF 试卷与讲义",
                        detail: "自动检索每一页正文内容，点击匹配摘要可直接打开并跳转到对应页码。"
                    )
                    guideRow(
                        symbol: "doc.richtext",
                        tint: .accentColor,
                        title: "HTML 互动课件与离线网页",
                        detail: "自动忽略代码与样式噪音，按章节提取可见正文并高亮命中片段。"
                    )
                    guideRow(
                        symbol: "text.magnifyingglass",
                        tint: .green,
                        title: "多关键词组合搜索",
                        detail: "用空格分隔多个关键词（如「抛物线 面积」「中心投影 相似」），自动忽略大小写与全半角差异。"
                    )
                }
                .padding(16)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(16)
        }
    }

    private func guideRow(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 24, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var noMatchesView: some View {
        ContentUnavailableView {
            Label("未找到匹配内容", systemImage: "magnifyingglass")
        } description: {
            Text("没有文档同时包含「\(engine.query.trimmingCharacters(in: .whitespacesAndNewlines))」。可尝试简化关键词，或切换文档类型与文件夹筛选。")
        } actions: {
            if hasActiveScopeFilter {
                Button("重置筛选范围") {
                    engine.documentFilter = .all
                    engine.folderFilterID = nil
                }
                .buttonStyle(.borderedProminent)
            }
            Button("清空关键词") {
                engine.query = ""
                isSearchFieldFocused = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var matchedResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("找到 \(engine.results.count) 份文档 · 共 \(engine.totalMatchCount) 处匹配")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)

                ForEach(engine.results) { result in
                    FullTextResultCard(
                        result: result,
                        tokens: activeTokens,
                        isOpenInTab: tabManager.isOpen(result.id),
                        isExpanded: expandedDocumentIDs.contains(result.id),
                        onToggleExpand: {
                            if expandedDocumentIDs.contains(result.id) {
                                expandedDocumentIDs.remove(result.id)
                            } else {
                                expandedDocumentIDs.insert(result.id)
                            }
                        },
                        onSelect: { targetPage in
                            engine.recordRecentQuery(engine.query)
                            onOpenDocument(result.meta, targetPage)
                            dismiss()
                        }
                    )
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Single Document Result Card

private struct FullTextResultCard: View {
    let result: FullTextDocumentResult
    let tokens: [String]
    let isOpenInTab: Bool
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onSelect: (Int?) -> Void

    private static let collapsedLimit = 3

    private var visibleMatches: [FullTextSearchMatch] {
        if isExpanded || result.matches.count <= Self.collapsedLimit {
            return result.matches
        }
        return Array(result.matches.prefix(Self.collapsedLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerButton

            if result.matches.isEmpty {
                Divider().padding(.leading, 14)
                Button {
                    onSelect(nil)
                } label: {
                    HStack {
                        Text(result.folderMatched && !result.titleMatched
                             ? "匹配于所属文件夹名称 · 轻点打开文档"
                             : "匹配于文档标题 · 轻点打开文档")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ForEach(visibleMatches) { match in
                    Divider().padding(.leading, 14)
                    matchRow(match)
                }

                if result.matches.count > Self.collapsedLimit {
                    Divider().padding(.leading, 14)
                    Button(action: onToggleExpand) {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                            Text(isExpanded
                                 ? "收起部分匹配"
                                 : "展开其余 \(result.matches.count - Self.collapsedLimit) 处匹配")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color(.separator).opacity(0.25), lineWidth: 0.8)
        )
    }

    private var headerButton: some View {
        Button {
            onSelect(result.matches.first?.pageIndex)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: result.meta.layout == .live ? "doc.richtext" : "doc.fill")
                    .font(.title3)
                    .foregroundStyle(result.meta.layout == .live ? Color.accentColor : Color.red.opacity(0.85))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HighlightedSearchText(
                        text: result.meta.title,
                        ranges: LibrarySearchMatcher.findHighlightRanges(in: result.meta.title, tokens: tokens),
                        baseFont: .subheadline.weight(.semibold),
                        highlightFont: .subheadline.weight(.bold)
                    )
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        if let folder = result.folderName {
                            Text(folder)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                        Text(result.meta.layout.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(result.meta.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if isOpenInTab {
                            Text("已打开")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor, in: Capsule())
                        }
                    }
                }

                Spacer(minLength: 8)

                Text("\(result.totalMatchCount) 处")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.secondarySystemBackground), in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func matchRow(_ match: FullTextSearchMatch) -> some View {
        Button {
            onSelect(match.pageIndex)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(match.locationLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(match.pageIndex != nil ? Color.accentColor : Color.teal)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                (match.pageIndex != nil ? Color.accentColor : Color.teal).opacity(0.12),
                                in: Capsule()
                            )
                            .lineLimit(1)

                        if match.hitCount > 1 {
                            Text("本段 \(match.hitCount) 处命中")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HighlightedSearchText(
                        text: match.snippet,
                        ranges: match.highlightRanges,
                        baseFont: .callout,
                        highlightFont: .callout.weight(.semibold)
                    )
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Highlighted Snippet Text

private struct HighlightedSearchText: View {
    let text: String
    let ranges: [Range<String.Index>]
    let baseFont: Font
    let highlightFont: Font

    var body: some View {
        Text(attributedText)
            .font(baseFont)
    }

    private var attributedText: AttributedString {
        var attributed = AttributedString(text)
        for range in ranges {
            if let attrRange = Range(range, in: attributed) {
                attributed[attrRange].font = highlightFont
                attributed[attrRange].foregroundColor = Color.primary
                attributed[attrRange].backgroundColor = Color.yellow.opacity(0.38)
            }
        }
        return attributed
    }
}
