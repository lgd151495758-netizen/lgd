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

struct LibraryFolder: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

struct DocumentMeta: Codable, Identifiable, Hashable {
    enum SourceKind: String, Codable {
        case htmlFile
        case webURL
        case pdfFile
        case blankNotebook
        case imageSet
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
    /// Optional folder classification for prep/class organization (backward compatible with v1.3).
    var folderID: UUID?
    /// Optional pin flag so high-frequency teaching docs stay at the top.
    var isPinned: Bool?

    var pinned: Bool { isPinned == true }

    init(id: UUID,
         title: String,
         createdAt: Date,
         modifiedAt: Date,
         layout: PageLayoutMode,
         sourceKind: SourceKind,
         sourceURL: String?,
         sourceEntry: String? = nil,
         folderID: UUID? = nil,
         isPinned: Bool? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.layout = layout
        self.sourceKind = sourceKind
        self.sourceURL = sourceURL
        self.sourceEntry = sourceEntry
        self.folderID = folderID
        self.isPinned = isPinned
    }
}

/// Owns the on-disk library. Each document is a `<uuid>.qmark` folder:
/// `meta.json`, `render.pdf`, `annotations.json` and an optional `source/` copy of the HTML.
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var documents: [DocumentMeta] = []
    @Published private(set) var folders: [LibraryFolder] = []
    /// File URL opened from the Files app (forwarded by `MainSceneDelegate`).
    @Published var pendingImportURL: URL?
    let root: URL

    private let fileManager = FileManager.default
    /// Dedicated serial background queue for atomic annotation JSON encoding and disk writes,
    /// keeping 120Hz Apple Pencil input completely free of main-thread serialization stalls.
    private let ioQueue = DispatchQueue(label: "app.quillmark.library.io", qos: .utility)

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static let encoder: JSONEncoder = makeEncoder()
    static let decoder: JSONDecoder = makeDecoder()

    init(root: URL? = nil) {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = root ?? documentsDirectory.appendingPathComponent("Library", isDirectory: true)
        try? fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
        reload()
    }

    var foldersURL: URL { root.appendingPathComponent("folders.json") }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).qmark", isDirectory: true)
    }

    func pdfURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("render.pdf") }
    func annotationsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("annotations.json") }
    func metaURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("meta.json") }
    func sourceFolder(for id: UUID) -> URL { folder(for: id).appendingPathComponent("source", isDirectory: true) }
    func thumbnailURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("thumbnail.png") }

    func folderName(for folderID: UUID?) -> String? {
        guard let folderID else { return nil }
        return folders.first(where: { $0.id == folderID })?.name
    }

    func reload() {
        if let folderData = try? Data(contentsOf: foldersURL),
           let loadedFolders = try? Self.decoder.decode([LibraryFolder].self, from: folderData) {
            folders = loadedFolders.sorted { $0.createdAt < $1.createdAt }
        } else {
            folders = []
        }

        let items = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        documents = items
            .filter { $0.pathExtension == "qmark" }
            .compactMap { folder -> DocumentMeta? in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
                return try? Self.decoder.decode(DocumentMeta.self, from: data)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: Folders & Metadata Management

    @discardableResult
    func createFolder(name: String) throws -> LibraryFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? "新建文件夹" : trimmed
        let folder = LibraryFolder(id: UUID(), name: resolvedName, createdAt: Date())
        folders.append(folder)
        try writeFolders()
        return folder
    }

    func renameFolder(_ id: UUID, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[idx].name = trimmed
        try writeFolders()
    }

    /// Removes a folder while safely keeping all its documents (moving them back to uncategorized).
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        try? writeFolders()
        var changed = false
        for i in documents.indices where documents[i].folderID == id {
            var meta = documents[i]
            meta.folderID = nil
            try? writeMeta(meta)
            documents[i] = meta
            changed = true
        }
        if changed {
            reload()
        }
    }

    /// Merges restored folders from a backup archive without overwriting existing folders.
    func mergeFolders(_ incoming: [LibraryFolder]) throws -> Int {
        var added = 0
        let existingIDs = Set(folders.map(\.id))
        for folder in incoming where !existingIDs.contains(folder.id) {
            folders.append(folder)
            added += 1
        }
        if added > 0 {
            folders.sort { $0.createdAt < $1.createdAt }
            try writeFolders()
        }
        return added
    }

    func renameDocument(_ id: UUID, to newTitle: String) throws {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        var meta = documents[idx]
        meta.title = trimmed
        meta.modifiedAt = Date()
        try writeMeta(meta)
        documents[idx] = meta
        documents.sort { $0.modifiedAt > $1.modifiedAt }
    }

    func togglePin(_ id: UUID) throws {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        var meta = documents[idx]
        meta.isPinned = !meta.pinned
        try writeMeta(meta)
        documents[idx] = meta
    }

    func moveDocument(_ id: UUID, toFolder folderID: UUID?) throws {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        var meta = documents[idx]
        if let folderID, !folders.contains(where: { $0.id == folderID }) {
            meta.folderID = nil
        } else {
            meta.folderID = folderID
        }
        try writeMeta(meta)
        documents[idx] = meta
    }

    @discardableResult
    func createDocument(title: String,
                        pdfData: Data?,
                        layout: PageLayoutMode,
                        sourceKind: DocumentMeta.SourceKind,
                        sourceURL: String?,
                        stagedSource: URL?,
                        sourceEntry: String? = nil,
                        folderID: UUID? = nil) throws -> DocumentMeta {
        let now = Date()
        let resolvedFolderID: UUID? = (folderID != nil && folders.contains(where: { $0.id == folderID })) ? folderID : nil
        let meta = DocumentMeta(id: UUID(), title: title, createdAt: now, modifiedAt: now,
                                layout: layout, sourceKind: sourceKind, sourceURL: sourceURL,
                                sourceEntry: sourceEntry, folderID: resolvedFolderID, isPinned: nil)
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

    /// Writes a fully reconstructed document (meta, annotations, optional PDF/source files/thumbnail) from backup.
    @discardableResult
    func installRestoredDocument(meta: DocumentMeta,
                                 annotations: DocumentAnnotations,
                                 pdfData: Data?,
                                 sourceFiles: [String: Data],
                                 thumbnailData: Data?) throws -> DocumentMeta {
        var resolvedMeta = meta
        if let fID = resolvedMeta.folderID, !folders.contains(where: { $0.id == fID }) {
            resolvedMeta.folderID = nil
        }
        let docFolder = folder(for: resolvedMeta.id)
        if fileManager.fileExists(atPath: docFolder.path) {
            try fileManager.removeItem(at: docFolder)
        }
        try fileManager.createDirectory(at: docFolder, withIntermediateDirectories: true)
        if let pdfData {
            try pdfData.write(to: pdfURL(for: resolvedMeta.id), options: .atomic)
        }
        if !sourceFiles.isEmpty {
            let srcRoot = sourceFolder(for: resolvedMeta.id).standardizedFileURL
            try fileManager.createDirectory(at: srcRoot, withIntermediateDirectories: true)
            for (relativePath, data) in sourceFiles {
                guard Self.isSafeRelativePath(relativePath) else { continue }
                let dest = srcRoot.appendingPathComponent(relativePath).standardizedFileURL
                guard dest.path.hasPrefix(srcRoot.path + "/") else { continue }
                try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest, options: .atomic)
            }
        }
        if let thumbnailData {
            try thumbnailData.write(to: thumbnailURL(for: resolvedMeta.id), options: .atomic)
        }
        try writeMeta(resolvedMeta)
        try Self.encoder.encode(annotations).write(to: annotationsURL(for: resolvedMeta.id), options: .atomic)
        reload()
        return resolvedMeta
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else { return false }
        let parts = path.split(separator: "/")
        return !parts.contains("..") && !parts.contains(".")
    }

    func delete(_ id: UUID) {
        try? fileManager.removeItem(at: folder(for: id))
        reload()
    }

    /// Clears handwriting across all main pages of the active layer on disk. When `keepTapes` is `true`,
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
        annotations.syncActiveLayerFromTopLevel()
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
            sourceEntry: original.sourceEntry,
            folderID: original.folderID,
            isPinned: false
        )
        let srcFolder = folder(for: original.id)
        let dstFolder = folder(for: copyMeta.id)
        try fileManager.copyItem(at: srcFolder, to: dstFolder)
        try writeMeta(copyMeta)
        reload()
        return copyMeta
    }

    func loadAnnotations(for id: UUID) -> DocumentAnnotations {
        let url = annotationsURL(for: id)
        return ioQueue.sync {
            guard let data = try? Data(contentsOf: url),
                  let value = try? Self.makeDecoder().decode(DocumentAnnotations.self, from: data) else {
                return DocumentAnnotations()
            }
            return value
        }
    }

    func saveAnnotations(_ annotations: DocumentAnnotations, for id: UUID) throws {
        var toSave = annotations
        toSave.syncActiveLayerFromTopLevel()
        let url = annotationsURL(for: id)
        try ioQueue.sync {
            try Self.makeEncoder().encode(toSave).write(to: url, options: .atomic)
        }
        touchModifiedDate(for: id)
    }

    /// Encodes and writes `annotations` atomically on the background serial queue, then updates
    /// metadata timestamps on the main thread without blocking handwriting frames.
    func saveAnnotationsAsync(_ annotations: DocumentAnnotations,
                              for id: UUID,
                              completion: ((Error?) -> Void)? = nil) {
        var snapshot = annotations
        snapshot.syncActiveLayerFromTopLevel()
        let docFolder = folder(for: id)
        let url = annotationsURL(for: id)
        ioQueue.async { [weak self] in
            do {
                guard FileManager.default.fileExists(atPath: docFolder.path) else {
                    DispatchQueue.main.async { completion?(nil) }
                    return
                }
                let data = try Self.makeEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async {
                    self?.touchModifiedDate(for: id)
                    completion?(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion?(error)
                }
            }
        }
    }

    /// Waits for all queued background annotation writes to finish (used in tests and teardown).
    func flushPendingWrites() {
        ioQueue.sync {}
    }

    private func touchModifiedDate(for id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        var meta = documents[index]
        meta.modifiedAt = Date()
        try? writeMeta(meta)
        documents[index] = meta
        documents.sort { $0.modifiedAt > $1.modifiedAt }
    }

    private func writeMeta(_ meta: DocumentMeta) throws {
        try Self.encoder.encode(meta).write(to: metaURL(for: meta.id), options: .atomic)
    }

    private func writeFolders() throws {
        try Self.encoder.encode(folders).write(to: foldersURL, options: .atomic)
    }
}
