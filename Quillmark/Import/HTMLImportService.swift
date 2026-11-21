import Foundation
import PDFKit

enum ImportSource {
    case file(URL)
    case web(URL)
}

enum ImportError: LocalizedError {
    case unreadable
    case noHTMLInFolder
    case invalidPDF

    var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取所选文件"
        case .noHTMLInFolder: return "文件夹里没有找到 .html 文件"
        case .invalidPDF: return "无法解析所选 PDF 文件"
        }
    }
}

/// Imports local HTML files/folders, web URLs (as `.webarchive`), and PDF documents into `LibraryStore`.
@MainActor
enum HTMLImportService {
    static let archiveName = "page.webarchive"

    static func importDocument(from source: ImportSource, into library: LibraryStore) async throws -> DocumentMeta {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = staging.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        switch source {
        case .file(let url):
            if url.pathExtension.lowercased() == "pdf" {
                let (pdfData, title) = try loadLocalPDF(url)
                return try library.createDocument(title: title, pdfData: pdfData, layout: .pdf,
                                                  sourceKind: .pdfFile, sourceURL: url.lastPathComponent,
                                                  stagedSource: nil)
            }
            let entry = try stageLocalHTML(url, into: sourceFolder)
            let title = htmlTitle(of: entry) ?? url.deletingPathExtension().lastPathComponent
            return try library.createDocument(title: title, pdfData: nil, layout: .live, sourceKind: .htmlFile,
                                              sourceURL: url.lastPathComponent, stagedSource: sourceFolder,
                                              sourceEntry: entry.lastPathComponent)
        case .web(let url):
            let output = try await WebArchiver.archive(url)
            try output.archive.write(to: sourceFolder.appendingPathComponent(archiveName), options: .atomic)
            let title = nonEmpty(output.title) ?? url.host ?? "网页"
            return try library.createDocument(title: title, pdfData: nil, layout: .live, sourceKind: .webURL,
                                              sourceURL: url.absoluteString, stagedSource: sourceFolder,
                                              sourceEntry: archiveName)
        }
    }

    nonisolated static func loadLocalPDF(_ url: URL) throws -> (data: Data, title: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw ImportError.unreadable
        }
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
            throw ImportError.invalidPDF
        }
        let filenameTitle = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let attrTitle = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = !filenameTitle.isEmpty ? filenameTitle : (attrTitle?.isEmpty == false ? attrTitle! : "PDF 文档")
        return (data, title)
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

    /// Reads `<title>` from an HTML file without loading it.
    nonisolated static func htmlTitle(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        guard let open = text.range(of: "<title", options: .caseInsensitive),
              let close = text.range(of: ">", range: open.upperBound..<text.endIndex),
              let end = text.range(of: "</title>", options: .caseInsensitive, range: close.upperBound..<text.endIndex) else {
            return nil
        }
        let raw = String(text[close.upperBound..<end.lowerBound])
        let decoded = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return decoded.isEmpty ? nil : decoded
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
