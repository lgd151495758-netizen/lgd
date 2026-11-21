import Foundation
import PDFKit

enum PageLayoutMode: String, Codable, CaseIterable, Identifiable {
    /// Live web page annotated in place.
    case live
    /// Imported PDF document annotated with full Quillmark tools.
    case pdf
    /// Legacy PDF conversions from version 0.1.
    case pagedA4
    case longPage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .live: return "网页"
        case .pdf: return "PDF"
        case .pagedA4: return "A4 分页"
        case .longPage: return "整张长页"
        }
    }
}

struct DocumentMeta: Codable, Identifiable, Hashable {
    enum SourceKind: String, Codable {
        case htmlFile
        case webURL
        case pdfFile
    }

    var id: UUID
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var layout: PageLayoutMode
    var sourceKind: SourceKind
    var sourceURL: String?
    /// Entry file inside `source/` for live documents (`index.html`, `page.webarchive`…).
    var sourceEntry: String?
}

/// Owns the on-disk library. Each document is a `<uuid>.qmark` folder:
/// `meta.json`, `render.pdf`, `annotations.json` and an optional `source/` copy of the HTML.
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var documents: [DocumentMeta] = []
    /// File URL opened from the Files app (forwarded by `MainSceneDelegate`).
    @Published var pendingImportURL: URL?
    let root: URL

    private let fileManager = FileManager.default

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(root: URL? = nil) {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = root ?? documentsDirectory.appendingPathComponent("Library", isDirectory: true)
        try? fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
        reload()
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).qmark", isDirectory: true)
    }

    func pdfURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("render.pdf") }
    func annotationsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("annotations.json") }
    func metaURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("meta.json") }
    func sourceFolder(for id: UUID) -> URL { folder(for: id).appendingPathComponent("source", isDirectory: true) }
    func thumbnailURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("thumbnail.png") }

    func reload() {
        let items = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        documents = items
            .filter { $0.pathExtension == "qmark" }
            .compactMap { folder -> DocumentMeta? in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
                return try? Self.decoder.decode(DocumentMeta.self, from: data)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    @discardableResult
    func createDocument(title: String,
                        pdfData: Data?,
                        layout: PageLayoutMode,
                        sourceKind: DocumentMeta.SourceKind,
                        sourceURL: String?,
                        stagedSource: URL?,
                        sourceEntry: String? = nil) throws -> DocumentMeta {
        let now = Date()
        let meta = DocumentMeta(id: UUID(), title: title, createdAt: now, modifiedAt: now,
                                layout: layout, sourceKind: sourceKind, sourceURL: sourceURL,
                                sourceEntry: sourceEntry)
        let folder = folder(for: meta.id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        if let pdfData {
            try pdfData.write(to: pdfURL(for: meta.id), options: .atomic)
        }
        if let stagedSource, fileManager.fileExists(atPath: stagedSource.path) {
            try? fileManager.moveItem(at: stagedSource, to: sourceFolder(for: meta.id))
        }
        try writeMeta(meta)
        try Self.encoder.encode(DocumentAnnotations()).write(to: annotationsURL(for: meta.id), options: .atomic)
        reload()
        return meta
    }

    func delete(_ id: UUID) {
        try? fileManager.removeItem(at: folder(for: id))
        reload()
    }

    /// Clears handwriting across all main pages of a document on disk. When `keepTapes` is `true`,
    /// Cover Tapes are preserved and reset to covered (`revealed = false`) for teaching another class.
    func clearInk(for id: UUID, keepTapes: Bool) {
        var annotations = loadAnnotations(for: id)
        var updatedPages: [String: PageAnnotations] = [:]
        if keepTapes {
            for (key, page) in annotations.pages {
                let kept: [InkStroke] = page.strokes.compactMap { stroke in
                    guard stroke.isTape else { return nil }
                    var covered = stroke
                    covered.revealed = false
                    return covered
                }
                if !kept.isEmpty {
                    updatedPages[key] = PageAnnotations(strokes: kept)
                }
            }
        }
        annotations.pages = updatedPages
        try? fileManager.removeItem(at: thumbnailURL(for: id))
        try? saveAnnotations(annotations, for: id)
    }

    /// Creates an independent copy of a document (including source/PDF and annotations) for multi-class reuse.
    @discardableResult
    func duplicate(_ id: UUID) throws -> DocumentMeta {
        guard let original = documents.first(where: { $0.id == id }) else {
            throw ImportError.unreadable
        }
        let now = Date()
        let copyMeta = DocumentMeta(
            id: UUID(),
            title: "\(original.title) 副本",
            createdAt: now,
            modifiedAt: now,
            layout: original.layout,
            sourceKind: original.sourceKind,
            sourceURL: original.sourceURL,
            sourceEntry: original.sourceEntry
        )
        let srcFolder = folder(for: original.id)
        let dstFolder = folder(for: copyMeta.id)
        try fileManager.copyItem(at: srcFolder, to: dstFolder)
        try writeMeta(copyMeta)
        reload()
        return copyMeta
    }

    func loadAnnotations(for id: UUID) -> DocumentAnnotations {
        guard let data = try? Data(contentsOf: annotationsURL(for: id)),
              let value = try? Self.decoder.decode(DocumentAnnotations.self, from: data) else {
            return DocumentAnnotations()
        }
        return value
    }

    func saveAnnotations(_ annotations: DocumentAnnotations, for id: UUID) throws {
        try Self.encoder.encode(annotations).write(to: annotationsURL(for: id), options: .atomic)
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        var meta = documents[index]
        meta.modifiedAt = Date()
        try writeMeta(meta)
        documents[index] = meta
        documents.sort { $0.modifiedAt > $1.modifiedAt }
    }

    private func writeMeta(_ meta: DocumentMeta) throws {
        try Self.encoder.encode(meta).write(to: metaURL(for: meta.id), options: .atomic)
    }
}
