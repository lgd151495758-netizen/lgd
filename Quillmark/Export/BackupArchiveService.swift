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

/// Self-contained portable backup & restore engine (`.qmbackup`) with zero third-party dependencies
/// and zero paid iCloud entitlements (SideStore/AltStore friendly).
///
/// Format `QMBK02` (streaming v2):
///   - 6 bytes: ASCII `"QMBK02"`
///   - 4 bytes: big-endian `UInt32` schema version (checked BEFORE decoding any payload!)
///   - 4 bytes + payload: big-endian length + zlib-compressed JSON `ArchiveManifest`
///   - N sequential entries: 4 bytes big-endian length + zlib-compressed binary-plist `ArchivedDocument`
///
/// Peak RAM is bounded to a single document at a time (protecting 4GB iPads against jetsam OOM kills
/// when backing up or restoring large multi-hundred-MB PDF libraries), while preserving full read
/// backward compatibility with legacy `QMBK01` archives.
enum BackupArchiveService {
    static let fileExtension = "qmbackup"
    static let currentSchemaVersion = 2
    private static let legacyMagicHeaderV1 = Data("QMBK01".utf8)
    private static let streamingMagicHeaderV2 = Data("QMBK02".utf8)

    struct ArchivedDocument: Codable {
        var meta: DocumentMeta
        var annotations: DocumentAnnotations
        var pdfData: Data?
        var thumbnailData: Data?
        /// Recursive relative paths under `source/` mapped to raw file bytes.
        var sourceFiles: [String: Data]
    }

    struct ArchiveManifest: Codable {
        var schemaVersion: Int = BackupArchiveService.currentSchemaVersion
        var exportedAt: Date = Date()
        var isFullLibrary: Bool
        var folders: [LibraryFolder]
        var documentCount: Int
    }

    /// Legacy v1 monolithic payload (retained for backward-compatible reading & tests).
    struct ArchivePayload: Codable {
        var schemaVersion: Int = 1
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
        /// Overwrites existing documents with matching IDs (enables restoring a good backup over a corrupted/empty copy).
        case replaceExisting
    }

    struct RestoreSummary: Equatable {
        var importedDocuments: Int
        var replacedExistingDocuments: Int = 0
        var skippedExistingDocuments: Int
        var importedFolders: Int
        var firstImportedID: UUID?

        var userMessage: String {
            var parts: [String] = []
            if importedDocuments > 0 {
                parts.append("成功恢复 \(importedDocuments) 份文档")
            }
            if replacedExistingDocuments > 0 {
                parts.append("覆盖更新 \(replacedExistingDocuments) 份原文档")
            }
            if importedFolders > 0 {
                parts.append("新建 \(importedFolders) 个文件夹")
            }
            if skippedExistingDocuments > 0 {
                parts.append("跳过 \(skippedExistingDocuments) 份已存在文档")
            }
            if parts.isEmpty {
                return "备份中的所有文档均已存在，未做改动。"
            }
            return parts.joined(separator: "，") + "。"
        }
    }

    static func isBackupFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// Prunes older temporary backup archives inside `tmp/QuillmarkBackups` so storage never grows unbounded.
    static func pruneTemporaryBackups(keepingMostRecent limit: Int = 2) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("QuillmarkBackups", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), items.count > limit else { return }

        let sorted = items.sorted { lhs, rhs in
            let d1 = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d2 = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d1 > d2
        }
        for stale in sorted.dropFirst(max(0, limit)) {
            try? fm.removeItem(at: stale)
        }
    }

    // MARK: Export (Streaming V2 — 1 Document in Memory at a Time)

    static func exportDocument(_ id: UUID, from library: LibraryStore) throws -> URL {
        library.flushPendingWrites()
        guard let meta = library.documents.first(where: { $0.id == id }) else {
            throw BackupError.documentNotFound
        }
        let folders: [LibraryFolder]
        if let fID = meta.folderID, let folder = library.folders.first(where: { $0.id == fID }) {
            folders = [folder]
        } else {
            folders = []
        }
        let stem = DocumentExportService.sanitizedFileStem(meta.title)
        let filename = "\(stem.isEmpty ? "羽签文档" : stem).\(fileExtension)"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuillmarkBackups", isDirectory: true)
        pruneTemporaryBackups(keepingMostRecent: 2)
        return try writeStreamingArchiveV2(
            documents: [meta],
            folders: folders,
            isFullLibrary: false,
            libraryRoot: library.root,
            destinationDirectory: dir,
            filename: filename
        )
    }

    static func exportFullLibrary(from library: LibraryStore) throws -> URL {
        library.flushPendingWrites()
        guard !library.documents.isEmpty else {
            throw BackupError.emptyLibrary
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let filename = "羽签全库备份_\(formatter.string(from: Date())).\(fileExtension)"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuillmarkBackups", isDirectory: true)
        pruneTemporaryBackups(keepingMostRecent: 2)
        let url = try writeStreamingArchiveV2(
            documents: library.documents,
            folders: library.folders,
            isFullLibrary: true,
            libraryRoot: library.root,
            destinationDirectory: dir,
            filename: filename
        )
        library.recordBackupCompleted()
        return url
    }

    /// Saves a rotating full-library backup directly into `Documents/Backups/` (visible in the iPadOS Files app),
    /// keeping the newest `maxKeep` archives so free-ID 7-day sideload renewals always have a local safety net.
    @discardableResult
    static func createRotatingLocalBackup(from library: LibraryStore, maxKeep: Int = 3) throws -> URL {
        library.flushPendingWrites()
        guard !library.documents.isEmpty else {
            throw BackupError.emptyLibrary
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let filename = "羽签本地备份_\(formatter.string(from: Date())).\(fileExtension)"
        let backupsDir = library.localBackupsDirectory
        let url = try writeStreamingArchiveV2(
            documents: library.documents,
            folders: library.folders,
            isFullLibrary: true,
            libraryRoot: library.root,
            destinationDirectory: backupsDir,
            filename: filename
        )
        pruneDirectory(backupsDir, extensionFilter: fileExtension, keepingMostRecent: maxKeep)
        library.recordBackupCompleted()
        return url
    }

    /// Off-main-thread full-library streaming backup for responsive UI on 4GB iPads.
    static func exportFullLibraryAsync(from library: LibraryStore, saveToLocalBackups: Bool = false) async throws -> URL {
        let docs = await MainActor.run { () -> [DocumentMeta] in
            library.flushPendingWrites()
            return library.documents
        }
        let folders = await MainActor.run { library.folders }
        let root = library.root
        let backupsDir = library.localBackupsDirectory
        guard !docs.isEmpty else { throw BackupError.emptyLibrary }

        let url = try await Task.detached(priority: .userInitiated) { () throws -> URL in
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HHmm"
            let prefix = saveToLocalBackups ? "羽签本地备份" : "羽签全库备份"
            let filename = "\(prefix)_\(formatter.string(from: Date())).\(fileExtension)"
            let destDir = saveToLocalBackups
                ? backupsDir
                : FileManager.default.temporaryDirectory.appendingPathComponent("QuillmarkBackups", isDirectory: true)
            if !saveToLocalBackups {
                pruneTemporaryBackups(keepingMostRecent: 2)
            }
            let written = try writeStreamingArchiveV2(
                documents: docs,
                folders: folders,
                isFullLibrary: true,
                libraryRoot: root,
                destinationDirectory: destDir,
                filename: filename
            )
            if saveToLocalBackups {
                pruneDirectory(backupsDir, extensionFilter: fileExtension, keepingMostRecent: 3)
            }
            return written
        }.value

        await MainActor.run {
            library.recordBackupCompleted()
        }
        return url
    }

    /// Off-main-thread single-document streaming backup.
    static func exportDocumentAsync(_ id: UUID, from library: LibraryStore) async throws -> URL {
        let snapshot = await MainActor.run { () -> (DocumentMeta, [LibraryFolder])? in
            library.flushPendingWrites()
            guard let meta = library.documents.first(where: { $0.id == id }) else { return nil }
            let folders: [LibraryFolder]
            if let fID = meta.folderID, let folder = library.folders.first(where: { $0.id == fID }) {
                folders = [folder]
            } else {
                folders = []
            }
            return (meta, folders)
        }
        guard let (meta, folders) = snapshot else { throw BackupError.documentNotFound }
        let root = library.root

        return try await Task.detached(priority: .userInitiated) { () throws -> URL in
            let stem = DocumentExportService.sanitizedFileStem(meta.title)
            let filename = "\(stem.isEmpty ? "羽签文档" : stem).\(fileExtension)"
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("QuillmarkBackups", isDirectory: true)
            pruneTemporaryBackups(keepingMostRecent: 2)
            return try writeStreamingArchiveV2(
                documents: [meta],
                folders: folders,
                isFullLibrary: false,
                libraryRoot: root,
                destinationDirectory: dir,
                filename: filename
            )
        }.value
    }

    // MARK: Import / Restore (Supports Both Streaming V2 & Legacy V1)

    static func importBackup(from url: URL,
                             into library: LibraryStore,
                             duplicatePolicy: DuplicatePolicy = .automatic) throws -> RestoreSummary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 6), magic.count == 6 else {
            throw BackupError.invalidArchive
        }

        if magic == streamingMagicHeaderV2 {
            return try importStreamingV2(handle: handle, into: library, duplicatePolicy: duplicatePolicy)
        } else if magic == legacyMagicHeaderV1 {
            try handle.close()
            guard let raw = try? Data(contentsOf: url), !raw.isEmpty else {
                throw BackupError.invalidArchive
            }
            let payload = try decodeArchive(raw)
            guard payload.schemaVersion <= currentSchemaVersion else {
                throw BackupError.unsupportedVersion(payload.schemaVersion)
            }
            return try applyRestoredDocuments(
                folders: payload.folders,
                isFullLibrary: payload.isFullLibrary,
                documentCount: payload.documents.count,
                nextDocument: { idx in payload.documents[idx] },
                into: library,
                duplicatePolicy: duplicatePolicy
            )
        } else {
            throw BackupError.invalidArchive
        }
    }

    /// Off-main-thread streaming restore: reads and decompresses one document at a time off the main thread
    /// and installs each into `library`, keeping peak RAM flat even for large PDF libraries.
    static func importBackupAsync(from url: URL,
                                  into library: LibraryStore,
                                  duplicatePolicy: DuplicatePolicy = .automatic) async throws -> RestoreSummary {
        let summary = try await Task.detached(priority: .userInitiated) { () throws -> RestoreSummary in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            guard let magic = try? handle.read(upToCount: 6), magic.count == 6 else {
                throw BackupError.invalidArchive
            }

            if magic == streamingMagicHeaderV2 {
                let version = try readUInt32(from: handle)
                guard version <= currentSchemaVersion else {
                    throw BackupError.unsupportedVersion(version)
                }
                let manifestLen = try readUInt32(from: handle)
                guard let compressedManifest = try? handle.read(upToCount: manifestLen),
                      compressedManifest.count == manifestLen,
                      let manifestData = try? (compressedManifest as NSData).decompressed(using: .zlib) as Data,
                      let manifest = try? LibraryStore.makeDecoder().decode(ArchiveManifest.self, from: manifestData) else {
                    throw BackupError.invalidArchive
                }
                guard manifest.schemaVersion <= currentSchemaVersion else {
                    throw BackupError.unsupportedVersion(manifest.schemaVersion)
                }

                let importedFolders = try await MainActor.run {
                    try library.mergeFolders(manifest.folders)
                }
                var existingIDs = await MainActor.run { Set(library.documents.map(\.id)) }
                let resolvedPolicy = resolvePolicy(duplicatePolicy, isFullLibrary: manifest.isFullLibrary)

                var importedCount = 0
                var replacedCount = 0
                var skippedCount = 0
                var firstID: UUID?

                for _ in 0..<manifest.documentCount {
                    let entry: ArchivedDocument = try autoreleasepool {
                        let chunkLen = try readUInt32(from: handle)
                        guard chunkLen > 0,
                              let compressedChunk = try? handle.read(upToCount: chunkLen),
                              compressedChunk.count == chunkLen,
                              let plistData = try? (compressedChunk as NSData).decompressed(using: .zlib) as Data,
                              let decoded = try? PropertyListDecoder().decode(ArchivedDocument.self, from: plistData) else {
                            throw BackupError.invalidArchive
                        }
                        return decoded
                    }

                    var meta = entry.meta
                    var isReplacement = false
                    if existingIDs.contains(meta.id) {
                        switch resolvedPolicy {
                        case .skipExisting:
                            skippedCount += 1
                            continue
                        case .replaceExisting:
                            isReplacement = true
                        case .importAsCopy, .automatic:
                            meta.id = UUID()
                            meta.title = "\(meta.title) (导入)"
                            meta.modifiedAt = Date()
                        }
                    }

                    let installed = try await MainActor.run {
                        try library.installRestoredDocument(
                            meta: meta,
                            annotations: entry.annotations,
                            pdfData: entry.pdfData,
                            sourceFiles: entry.sourceFiles,
                            thumbnailData: entry.thumbnailData
                        )
                    }
                    existingIDs.insert(installed.id)
                    if isReplacement {
                        replacedCount += 1
                    } else {
                        importedCount += 1
                    }
                    if firstID == nil {
                        firstID = installed.id
                    }
                }

                return RestoreSummary(
                    importedDocuments: importedCount,
                    replacedExistingDocuments: replacedCount,
                    skippedExistingDocuments: skippedCount,
                    importedFolders: importedFolders,
                    firstImportedID: firstID
                )
            } else if magic == legacyMagicHeaderV1 {
                try handle.close()
                guard let raw = try? Data(contentsOf: url), !raw.isEmpty else {
                    throw BackupError.invalidArchive
                }
                let payload = try decodeArchive(raw)
                guard payload.schemaVersion <= currentSchemaVersion else {
                    throw BackupError.unsupportedVersion(payload.schemaVersion)
                }
                return try await MainActor.run {
                    try applyRestoredDocuments(
                        folders: payload.folders,
                        isFullLibrary: payload.isFullLibrary,
                        documentCount: payload.documents.count,
                        nextDocument: { idx in payload.documents[idx] },
                        into: library,
                        duplicatePolicy: duplicatePolicy
                    )
                }
            } else {
                throw BackupError.invalidArchive
            }
        }.value

        await MainActor.run {
            library.cleanupInboxFileIfNeeded(url)
        }
        return summary
    }

    // MARK: Legacy V1 Serialization (Kept for Backward-Compatibility Tests)

    static func encodeArchive(_ payload: ArchivePayload) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plistData = try encoder.encode(payload)
        let compressed = try (plistData as NSData).compressed(using: .zlib) as Data
        var out = Data()
        out.reserveCapacity(legacyMagicHeaderV1.count + compressed.count)
        out.append(legacyMagicHeaderV1)
        out.append(compressed)
        return out
    }

    static func decodeArchive(_ data: Data) throws -> ArchivePayload {
        guard data.count > legacyMagicHeaderV1.count,
              data.prefix(legacyMagicHeaderV1.count) == legacyMagicHeaderV1 else {
            throw BackupError.invalidArchive
        }
        let compressed = data.dropFirst(legacyMagicHeaderV1.count)
        guard let plistData = try? (Data(compressed) as NSData).decompressed(using: .zlib) as Data,
              let payload = try? PropertyListDecoder().decode(ArchivePayload.self, from: plistData) else {
            throw BackupError.invalidArchive
        }
        return payload
    }

    // MARK: Streaming V2 Engine

    private static func writeStreamingArchiveV2(documents: [DocumentMeta],
                                                folders: [LibraryFolder],
                                                isFullLibrary: Bool,
                                                libraryRoot: URL,
                                                destinationDirectory: URL,
                                                filename: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        // Write into a staging file first, then atomically replace `dest` so an interrupted export
        // never leaves a half-written `.qmbackup` file.
        let stagingURL = destinationDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let destURL = destinationDirectory.appendingPathComponent(filename)
        fm.createFile(atPath: stagingURL.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: stagingURL)
            defer { try? handle.close() }

            try handle.write(contentsOf: streamingMagicHeaderV2)
            try writeUInt32(currentSchemaVersion, to: handle)

            let manifest = ArchiveManifest(
                schemaVersion: currentSchemaVersion,
                exportedAt: Date(),
                isFullLibrary: isFullLibrary,
                folders: folders,
                documentCount: documents.count
            )
            let manifestJSON = try LibraryStore.makeEncoder().encode(manifest)
            let compressedManifest = try (manifestJSON as NSData).compressed(using: .zlib) as Data
            try writeUInt32(compressedManifest.count, to: handle)
            try handle.write(contentsOf: compressedManifest)

            let plistEncoder = PropertyListEncoder()
            plistEncoder.outputFormat = .binary

            for meta in documents {
                try autoreleasepool {
                    let archived = packDocument(meta, libraryRoot: libraryRoot)
                    let plistData = try plistEncoder.encode(archived)
                    let compressedChunk = try (plistData as NSData).compressed(using: .zlib) as Data
                    try writeUInt32(compressedChunk.count, to: handle)
                    try handle.write(contentsOf: compressedChunk)
                }
            }
            try handle.synchronize()
            try handle.close()

            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: stagingURL, to: destURL)
            return destURL
        } catch {
            try? fm.removeItem(at: stagingURL)
            throw error
        }
    }

    private static func importStreamingV2(handle: FileHandle,
                                          into library: LibraryStore,
                                          duplicatePolicy: DuplicatePolicy) throws -> RestoreSummary {
        let version = try readUInt32(from: handle)
        guard version <= currentSchemaVersion else {
            throw BackupError.unsupportedVersion(version)
        }
        let manifestLen = try readUInt32(from: handle)
        guard let compressedManifest = try? handle.read(upToCount: manifestLen),
              compressedManifest.count == manifestLen,
              let manifestData = try? (compressedManifest as NSData).decompressed(using: .zlib) as Data,
              let manifest = try? LibraryStore.makeDecoder().decode(ArchiveManifest.self, from: manifestData) else {
            throw BackupError.invalidArchive
        }
        guard manifest.schemaVersion <= currentSchemaVersion else {
            throw BackupError.unsupportedVersion(manifest.schemaVersion)
        }

        return try applyRestoredDocuments(
            folders: manifest.folders,
            isFullLibrary: manifest.isFullLibrary,
            documentCount: manifest.documentCount,
            nextDocument: { _ in
                try autoreleasepool {
                    let chunkLen = try readUInt32(from: handle)
                    guard chunkLen > 0,
                          let compressedChunk = try? handle.read(upToCount: chunkLen),
                          compressedChunk.count == chunkLen,
                          let plistData = try? (compressedChunk as NSData).decompressed(using: .zlib) as Data,
                          let decoded = try? PropertyListDecoder().decode(ArchivedDocument.self, from: plistData) else {
                        throw BackupError.invalidArchive
                    }
                    return decoded
                }
            },
            into: library,
            duplicatePolicy: duplicatePolicy
        )
    }

    private static func resolvePolicy(_ policy: DuplicatePolicy, isFullLibrary: Bool) -> DuplicatePolicy {
        switch policy {
        case .automatic:
            return isFullLibrary ? .skipExisting : .importAsCopy
        case .skipExisting, .importAsCopy, .replaceExisting:
            return policy
        }
    }

    private static func applyRestoredDocuments(folders: [LibraryFolder],
                                               isFullLibrary: Bool,
                                               documentCount: Int,
                                               nextDocument: (Int) throws -> ArchivedDocument,
                                               into library: LibraryStore,
                                               duplicatePolicy: DuplicatePolicy) throws -> RestoreSummary {
        let importedFolders = try library.mergeFolders(folders)
        var existingIDs = Set(library.documents.map(\.id))
        var importedCount = 0
        var replacedCount = 0
        var skippedCount = 0
        var firstID: UUID?

        let resolvedPolicy = resolvePolicy(duplicatePolicy, isFullLibrary: isFullLibrary)

        for idx in 0..<documentCount {
            let entry = try nextDocument(idx)
            var meta = entry.meta
            var isReplacement = false
            if existingIDs.contains(meta.id) {
                switch resolvedPolicy {
                case .skipExisting:
                    skippedCount += 1
                    continue
                case .replaceExisting:
                    isReplacement = true
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
            if isReplacement {
                replacedCount += 1
            } else {
                importedCount += 1
            }
            if firstID == nil {
                firstID = installed.id
            }
        }

        return RestoreSummary(
            importedDocuments: importedCount,
            replacedExistingDocuments: replacedCount,
            skippedExistingDocuments: skippedCount,
            importedFolders: importedFolders,
            firstImportedID: firstID
        )
    }

    private static func writeUInt32(_ value: Int, to handle: FileHandle) throws {
        var bigEndian = UInt32(max(0, value)).bigEndian
        let data = withUnsafeBytes(of: &bigEndian) { Data($0) }
        try handle.write(contentsOf: data)
    }

    private static func readUInt32(from handle: FileHandle) throws -> Int {
        guard let bytes = try? handle.read(upToCount: 4), bytes.count == 4 else {
            throw BackupError.invalidArchive
        }
        let val = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        return Int(val)
    }

    private static func pruneDirectory(_ dir: URL, extensionFilter: String, keepingMostRecent limit: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let matching = items.filter { $0.pathExtension.lowercased() == extensionFilter.lowercased() }
        guard matching.count > limit else { return }
        let sorted = matching.sorted { lhs, rhs in
            let d1 = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d2 = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d1 > d2
        }
        for stale in sorted.dropFirst(max(0, limit)) {
            try? fm.removeItem(at: stale)
        }
    }

    private static func packDocument(_ meta: DocumentMeta, libraryRoot: URL) -> ArchivedDocument {
        let docFolder = libraryRoot.appendingPathComponent("\(meta.id.uuidString).qmark", isDirectory: true)
        let annURL = docFolder.appendingPathComponent("annotations.json")
        var annotations: DocumentAnnotations
        if let data = try? Data(contentsOf: annURL),
           let decoded = try? LibraryStore.makeDecoder().decode(DocumentAnnotations.self, from: data) {
            annotations = decoded
        } else {
            annotations = DocumentAnnotations()
        }
        annotations.syncActiveLayerFromTopLevel()
        let pdfData = try? Data(contentsOf: docFolder.appendingPathComponent("render.pdf"))
        let thumbnailData = try? Data(contentsOf: docFolder.appendingPathComponent("thumbnail.png"))
        let sourceFiles = readDirectoryRecursively(docFolder.appendingPathComponent("source", isDirectory: true))
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
