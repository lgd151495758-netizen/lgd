import Foundation

enum ImportSource {
    case file(URL)
    case web(URL)
}

enum ImportError: LocalizedError {
    case unreadable
    case noHTMLInFolder

    var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取所选文件"
        case .noHTMLInFolder: return "文件夹里没有找到 .html 文件"
        }
    }
}

/// Copies the HTML (plus its resources) into a staging folder, converts it to PDF and
/// creates a library document.
@MainActor
enum HTMLImportService {
    static func importDocument(from source: ImportSource, layout: PageLayoutMode,
                               into library: LibraryStore) async throws -> DocumentMeta {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = staging.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        switch source {
        case .file(let url):
            let entry = try stageLocalHTML(url, into: sourceFolder)
            let output = try await HTMLPDFConverter.convert(.file(entry, readAccess: sourceFolder), layout: layout)
            let title = nonEmpty(output.title) ?? url.deletingPathExtension().lastPathComponent
            return try library.createDocument(title: title, pdfData: output.pdfData, layout: layout,
                                              sourceKind: .htmlFile, sourceURL: url.lastPathComponent,
                                              stagedSource: sourceFolder)
        case .web(let url):
            let output = try await HTMLPDFConverter.convert(.web(url), layout: layout)
            if let html = output.html {
                try? html.write(to: sourceFolder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            }
            let title = nonEmpty(output.title) ?? url.host ?? "网页"
            return try library.createDocument(title: title, pdfData: output.pdfData, layout: layout,
                                              sourceKind: .webURL, sourceURL: url.absoluteString,
                                              stagedSource: sourceFolder)
        }
    }

    /// Accepts "example.com" as well as full URLs.
    nonisolated static func normalizedWebURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Copies a picked `.html` file (and a browser-saved `name_files` folder next to it) or a whole
    /// folder into `folder`. Returns the HTML entry point inside the copy.
    nonisolated static func stageLocalHTML(_ url: URL, into folder: URL) throws -> URL {
        let fileManager = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw ImportError.unreadable }

        if isDirectory.boolValue {
            let items = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            for item in items {
                try fileManager.copyItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
            }
            let htmlNames = items
                .filter { ["html", "htm", "xhtml"].contains($0.pathExtension.lowercased()) }
                .map(\.lastPathComponent)
                .sorted()
            guard let entry = htmlNames.first(where: { $0.lowercased().hasPrefix("index.") }) ?? htmlNames.first else {
                throw ImportError.noHTMLInFolder
            }
            return folder.appendingPathComponent(entry)
        }

        let destination = folder.appendingPathComponent(url.lastPathComponent)
        try fileManager.copyItem(at: url, to: destination)
        let baseName = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        for suffix in ["_files", ".files"] {
            let sibling = parent.appendingPathComponent(baseName + suffix, isDirectory: true)
            if fileManager.fileExists(atPath: sibling.path) {
                try? fileManager.copyItem(at: sibling, to: folder.appendingPathComponent(sibling.lastPathComponent))
            }
        }
        return destination
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
