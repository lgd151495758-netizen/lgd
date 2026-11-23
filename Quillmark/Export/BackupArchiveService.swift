import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let quillmarkBackup: UTType = UTType(filenameExtension: BackupArchiveService.fileExtension)
        ?? UTType(exportedAs: "app.quillmark.backup", conformingTo: .data)
}

enum BackupError: LocalizedError {
    case documentNotFound
    case emptyLibrary
    case invalidArchive
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .documentNotFound: return "找不到要备份的文档"
        case .emptyLibrary: return "文档库为空，无需备份"
        case .invalidArchive: return "无法解析备份文件（文件可能已损坏或格式不支持）"
        case .unsupportedVersion(let v): return "此备份文件版本（v\(v)）高于当前羽签版本，请先更新应用"
        }
    }
}

/// Self-contained portable backup & restore engine (`.qmbackup`) using binary plist + native zlib.
/// Preserves folders, pins, multi-class layers, cover tapes, scratchpad pages, PDFs, and HTML folders
/// with zero third-party dependencies and zero paid iCloud entitlements (SideStore/AltStore friendly).
enum BackupArchiveService {
    static let fileExtension = "qmbackup"
    static let currentSchemaVersion = 1
    private static let magicHeader = Data("QMBK01".utf8)

    struct ArchivedDocument: Codable {
        var meta: DocumentMeta
        var annotations: DocumentAnnotations
        var pdfData: Data?
        var thumbnailData: Data?
        /// Recursive relative paths under `source/` mapped to raw file bytes.
        var sourceFiles: [String: Data]
    }

    struct ArchivePayload: Codable {
        var schemaVersion: Int = BackupArchiveService.currentSchemaVersion
        var exportedAt: Date = Date()
        var isFullLibrary: Bool
        var folders: [LibraryFolder]
        var documents: [ArchivedDocument]
    }

    enum DuplicatePolicy {
        /// Full-library backups skip existing IDs; single-document backups import as an independent copy.
        case automatic
        case skipExisting
        case importAsCopy
    }

    struct RestoreSummary: Equatable {
        var importedDocuments: Int
        var skippedExistingDocuments: Int
        var importedFolders: Int
        var firstImportedID: UUID?

        var userMessage: String {
            var parts: [String] = []
            parts.append("成功恢复 \(importedDocuments) 份文档")
            if importedFolders > 0 {
                parts.append("新建 \(importedFolders) 个文件夹")
            }
            if skippedExistingDocuments > 0 {
                parts.append("跳过 \(skippedExistingDocuments) 份已存在文档")
            }
            return parts.joined(separator: "，") + "。"
        }
    }

    static func isBackupFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    static func exportDocument(_ id: UUID, from library: LibraryStore) throws -> URL {
        guard let meta = library.documents.first(where: { $0.id == id }) else {
            throw BackupError.documentNotFound
        }
        let archived = try packDocument(meta, from: library)
        let folders: [LibraryFolder]
        if let fID = meta.folderID, let folder = library.folders.first(where: { $0.id == fID }) {
            folders = [folder]
        } else {
            folders = []
        }
        let payload = ArchivePayload(isFullLibrary: false, folders: folders, documents: [archived])
        let stem = DocumentExportService.sanitizedFileStem(meta.title)
        let filename = "\(stem.isEmpty ? "羽签文档" : stem).\(fileExtension)"
        return try writeArchive(payload, filename: filename)
    }

    static func exportFullLibrary(from library: LibraryStore) throws -> URL {
        guard !library.documents.isEmpty else {
            throw BackupError.emptyLibrary
        }
        let archivedDocs = try library.documents.map { try packDocument($0, from: library) }
        let payload = ArchivePayload(isFullLibrary: true, folders: library.folders, documents: archivedDocs)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let filename = "羽签全库备份_\(formatter.string(from: Date())).\(fileExtension)"
        return try writeArchive(payload, filename: filename)
    }

    static func importBackup(from url: URL,
                             into library: LibraryStore,
                             duplicatePolicy: DuplicatePolicy = .automatic) throws -> RestoreSummary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let raw = try? Data(contentsOf: url), !raw.isEmpty else {
            throw BackupError.invalidArchive
        }
        let payload = try decodeArchive(raw)
        guard payload.schemaVersion <= currentSchemaVersion else {
            throw BackupError.unsupportedVersion(payload.schemaVersion)
        }

        let importedFolders = try library.mergeFolders(payload.folders)
        var existingIDs = Set(library.documents.map(\.id))
        var importedCount = 0
        var skippedCount = 0
        var firstID: UUID?

        let resolvedPolicy: DuplicatePolicy
        switch duplicatePolicy {
        case .automatic:
            resolvedPolicy = payload.isFullLibrary ? .skipExisting : .importAsCopy
        case .skipExisting, .importAsCopy:
            resolvedPolicy = duplicatePolicy
        }

        for entry in payload.documents {
            var meta = entry.meta
            if existingIDs.contains(meta.id) {
                switch resolvedPolicy {
                case .skipExisting:
                    skippedCount += 1
                    continue
                case .importAsCopy, .automatic:
                    meta.id = UUID()
                    meta.title = "\(meta.title) (导入)"
                    meta.modifiedAt = Date()
                }
            }
            let installed = try library.installRestoredDocument(
                meta: meta,
                annotations: entry.annotations,
                pdfData: entry.pdfData,
                sourceFiles: entry.sourceFiles,
                thumbnailData: entry.thumbnailData
            )
            existingIDs.insert(installed.id)
            importedCount += 1
            if firstID == nil {
                firstID = installed.id
            }
        }

        return RestoreSummary(
            importedDocuments: importedCount,
            skippedExistingDocuments: skippedCount,
            importedFolders: importedFolders,
            firstImportedID: firstID
        )
    }

    // MARK: Serialization & Compression

    static func encodeArchive(_ payload: ArchivePayload) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plistData = try encoder.encode(payload)
        let compressed = try (plistData as NSData).compressed(using: .zlib) as Data
        var out = Data()
        out.reserveCapacity(magicHeader.count + compressed.count)
        out.append(magicHeader)
        out.append(compressed)
        return out
    }

    static func decodeArchive(_ data: Data) throws -> ArchivePayload {
        guard data.count > magicHeader.count,
              data.prefix(magicHeader.count) == magicHeader else {
            throw BackupError.invalidArchive
        }
        let compressed = data.dropFirst(magicHeader.count)
        guard let plistData = try? (Data(compressed) as NSData).decompressed(using: .zlib) as Data,
              let payload = try? PropertyListDecoder().decode(ArchivePayload.self, from: plistData) else {
            throw BackupError.invalidArchive
        }
        return payload
    }

    private static func writeArchive(_ payload: ArchivePayload, filename: String) throws -> URL {
        let data = try encodeArchive(payload)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuillmarkBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest, options: .atomic)
        return dest
    }

    private static func packDocument(_ meta: DocumentMeta, from library: LibraryStore) throws -> ArchivedDocument {
        var annotations = library.loadAnnotations(for: meta.id)
        annotations.syncActiveLayerFromTopLevel()
        let pdfData = try? Data(contentsOf: library.pdfURL(for: meta.id))
        let thumbnailData = try? Data(contentsOf: library.thumbnailURL(for: meta.id))
        let sourceFiles = readDirectoryRecursively(library.sourceFolder(for: meta.id))
        return ArchivedDocument(
            meta: meta,
            annotations: annotations,
            pdfData: pdfData,
            thumbnailData: thumbnailData,
            sourceFiles: sourceFiles
        )
    }

    private static func readDirectoryRecursively(_ directory: URL) -> [String: Data] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return [:]
        }
        let baseURL = directory.standardizedFileURL
        let basePrefix = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        guard let enumerator = fm.enumerator(at: baseURL,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else {
            return [:]
        }
        var files: [String: Data] = [:]
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let standardized = fileURL.standardizedFileURL.path
            guard standardized.hasPrefix(basePrefix) else { continue }
            let relative = String(standardized.dropFirst(basePrefix.count))
            if let bytes = try? Data(contentsOf: fileURL) {
                files[relative] = bytes
            }
        }
        return files
    }
}
