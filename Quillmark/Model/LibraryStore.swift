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

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = PageLayoutMode(rawValue: raw) ?? .pdf
    }

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

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = (try? container.decode(String.self)) ?? ""
            self = SourceKind(rawValue: raw) ?? .pdfFile
        }
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

/// Result of reading a document's `annotations.json` so decode failures or newer-version files are
/// NEVER confused with genuinely empty documents or silently overwritten.
enum AnnotationsLoadResult {
    case loaded(DocumentAnnotations)
    case missing
    case unsupportedVersion(version: Int, quarantinedURL: URL?)
    case corrupted(message: String, quarantinedURL: URL?)
}

private struct AnnotationsVersionProbe: Decodable {
    let version: Int?
}

private struct BackupStateRecord: Codable {
    var lastBackupAt: Date?
}

/// Owns the on-disk library. Each document is a `<uuid>.qmark` folder:
/// `meta.json`, `render.pdf`, `annotations.json` and an optional `source/` copy of the HTML.
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var documents: [DocumentMeta] = []
    @Published private(set) var folders: [LibraryFolder] = []
    /// Last successful backup timestamp persisted inside `Library/backup-state.json`.
    @Published private(set) var lastBackupDate: Date?
    /// Non-nil when a corrupted `folders.json` or `meta.json` was quarantined on reload.
    @Published var lastDataWarning: String?
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
    var backupStateURL: URL { root.appendingPathComponent("backup-state.json") }
    /// Local backup folder sitting alongside `Library/` (visible inside the iPadOS Files app).
    var localBackupsDirectory: URL {
        root.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    var daysSinceLastBackup: Int? {
        guard let lastBackupDate else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: lastBackupDate, to: Date()).day ?? 0)
    }

    /// True when the library has documents and has never been backed up or hasn't been backed up in `>= 5` days.
    var needsBackupReminder: Bool {
        guard !documents.isEmpty else { return false }
        guard let days = daysSinceLastBackup else { return true }
        return days >= 5
    }

    func recordBackupCompleted(at date: Date = Date()) {
        lastBackupDate = date
        let record = BackupStateRecord(lastBackupAt: date)
        if let data = try? Self.encoder.encode(record) {
            try? data.write(to: backupStateURL, options: .atomic)
        }
    }

    /// Removes temporary copies iOS placed in `Documents/Inbox/` after importing so PDFs aren't stored twice.
    func cleanupInboxFileIfNeeded(_ url: URL) {
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        let inboxDir = docsDir.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL
        let candidate = url.standardizedFileURL
        let inboxPrefix = inboxDir.path.hasSuffix("/") ? inboxDir.path : inboxDir.path + "/"
        if candidate.path.hasPrefix(inboxPrefix) {
            try? fileManager.removeItem(at: candidate)
        }
    }

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
        var warnings: [String] = []

        if let backupData = try? Data(contentsOf: backupStateURL),
           let state = try? Self.decoder.decode(BackupStateRecord.self, from: backupData) {
            lastBackupDate = state.lastBackupAt
        } else {
            lastBackupDate = nil
        }

        if fileManager.fileExists(atPath: foldersURL.path) {
            if let folderData = try? Data(contentsOf: foldersURL),
               let loadedFolders = try? Self.decoder.decode([LibraryFolder].self, from: folderData) {
                folders = loadedFolders.sorted { $0.createdAt < $1.createdAt }
            } else {
                _ = Self.quarantineFileIfNeeded(at: foldersURL, prefix: "folders")
                warnings.append("文件夹索引文件损坏，已自动备份副本")
                folders = []
            }
        } else {
            folders = []
        }

        let items = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var loadedDocs: [DocumentMeta] = []
        var seenIDs: Set<UUID> = []

        for folder in items where folder.pathExtension == "qmark" {
            let metaFile = folder.appendingPathComponent("meta.json")
            guard fileManager.fileExists(atPath: metaFile.path) else { continue }
            guard let data = try? Data(contentsOf: metaFile),
                  var meta = try? Self.decoder.decode(DocumentMeta.self, from: data) else {
                _ = Self.quarantineFileIfNeeded(at: metaFile, prefix: "meta")
                warnings.append("有文档元数据损坏，已保留原文件副本")
                continue
            }
            // Repair folder-name vs meta.id mismatch (e.g. Finder folder copy or interrupted duplicate).
            let folderStem = folder.deletingPathExtension().lastPathComponent
            if let folderUUID = UUID(uuidString: folderStem), meta.id != folderUUID {
                meta.id = folderUUID
                try? Self.encoder.encode(meta).write(to: metaFile, options: .atomic)
            }
            guard !seenIDs.contains(meta.id) else { continue }
            seenIDs.insert(meta.id)
            loadedDocs.append(meta)
        }

        documents = loadedDocs.sorted { $0.modifiedAt > $1.modifiedAt }
        if !warnings.isEmpty {
            lastDataWarning = warnings.joined(separator: "；")
        }
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
        do {
            if let pdfData {
                try pdfData.write(to: pdfURL(for: meta.id), options: .atomic)
            }
            if let stagedSource, fileManager.fileExists(atPath: stagedSource.path) {
                try fileManager.moveItem(at: stagedSource, to: sourceFolder(for: meta.id))
            }
            try writeMeta(meta)
            try Self.encoder.encode(DocumentAnnotations()).write(to: annotationsURL(for: meta.id), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
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
        var annotations: DocumentAnnotations
        switch loadAnnotationsResult(for: id) {
        case .loaded(let loaded):
            annotations = loaded
        case .missing:
            annotations = DocumentAnnotations()
        case .corrupted, .unsupportedVersion:
            // Corrupt/newer file has already been safely quarantined on disk before replacing.
            annotations = DocumentAnnotations()
        }
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
        flushPendingWrites()
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
        // Stage copy outside `root`, rewrite `meta.json` with the new UUID first, then move into `root`
        // so an interrupted copy can never leave two folders sharing the same document UUID.
        let stagingDir = fileManager.temporaryDirectory
            .appendingPathComponent("dup-\(UUID().uuidString)", isDirectory: true)
        let stagedDoc = stagingDir.appendingPathComponent("\(copyMeta.id.uuidString).qmark", isDirectory: true)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDir) }

        try fileManager.copyItem(at: srcFolder, to: stagedDoc)
        let metaData = try Self.encoder.encode(copyMeta)
        try metaData.write(to: stagedDoc.appendingPathComponent("meta.json"), options: .atomic)
        try fileManager.moveItem(at: stagedDoc, to: dstFolder)
        reload()
        return copyMeta
    }

    /// Loads `annotations.json` while strictly separating missing files, newer schema versions,
    /// and decode errors (automatically quarantining unreadable files so they are never overwritten).
    func loadAnnotationsResult(for id: UUID) -> AnnotationsLoadResult {
        let url = annotationsURL(for: id)
        return ioQueue.sync {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .missing
            }
            guard let data = try? Data(contentsOf: url) else {
                let q = Self.quarantineFileIfNeeded(at: url, prefix: "annotations")
                return .corrupted(message: "无法读取批注文件", quarantinedURL: q)
            }
            if let probe = try? Self.makeDecoder().decode(AnnotationsVersionProbe.self, from: data),
               let v = probe.version, v > DocumentAnnotations.currentVersion {
                let q = Self.quarantineFileIfNeeded(at: url, prefix: "annotations-v\(v)")
                return .unsupportedVersion(version: v, quarantinedURL: q)
            }
            do {
                let value = try Self.makeDecoder().decode(DocumentAnnotations.self, from: data)
                if value.version > DocumentAnnotations.currentVersion {
                    let q = Self.quarantineFileIfNeeded(at: url, prefix: "annotations-v\(value.version)")
                    return .unsupportedVersion(version: value.version, quarantinedURL: q)
                }
                return .loaded(value)
            } catch {
                let q = Self.quarantineFileIfNeeded(at: url, prefix: "annotations")
                return .corrupted(message: error.localizedDescription, quarantinedURL: q)
            }
        }
    }

    func loadAnnotations(for id: UUID) -> DocumentAnnotations {
        switch loadAnnotationsResult(for: id) {
        case .loaded(let value):
            return value
        case .missing, .corrupted, .unsupportedVersion:
            return DocumentAnnotations()
        }
    }

    func saveAnnotations(_ annotations: DocumentAnnotations, for id: UUID, markModified: Bool = true) throws {
        var toSave = annotations.sanitizedForEncoding()
        toSave.syncActiveLayerFromTopLevel()
        let url = annotationsURL(for: id)
        try ioQueue.sync {
            try Self.makeEncoder().encode(toSave).write(to: url, options: .atomic)
        }
        if markModified {
            touchModifiedDate(for: id)
        }
    }

    /// Encodes and writes `annotations` atomically on the background serial queue, then updates
    /// metadata timestamps on the main thread only when `markModified` is `true` (real ink edits).
    func saveAnnotationsAsync(_ annotations: DocumentAnnotations,
                              for id: UUID,
                              markModified: Bool = true,
                              completion: ((Error?) -> Void)? = nil) {
        var snapshot = annotations.sanitizedForEncoding()
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
                    if markModified {
                        self?.touchModifiedDate(for: id)
                    }
                    completion?(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completion?(error)
                }
            }
        }
    }

    /// Copies a corrupted or future-version JSON file to `<prefix>.corrupt-<timestamp>.json` alongside
    /// the original (reusing an existing identical quarantine copy to avoid duplicate files).
    @discardableResult
    static func quarantineFileIfNeeded(at url: URL, prefix: String) -> URL? {
        let fm = FileManager.default
        guard let raw = try? Data(contentsOf: url), !raw.isEmpty else { return nil }
        let dir = url.deletingLastPathComponent()
        if let existing = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for candidate in existing where candidate.lastPathComponent.hasPrefix("\(prefix).corrupt-") {
                if let existingBytes = try? Data(contentsOf: candidate), existingBytes == raw {
                    return candidate
                }
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dest = dir.appendingPathComponent("\(prefix).corrupt-\(formatter.string(from: Date())).json")
        do {
            try raw.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
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
