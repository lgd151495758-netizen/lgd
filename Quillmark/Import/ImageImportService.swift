import CoreGraphics
import Foundation
import PDFKit
import UIKit

/// Converts one or more images (photos of homework, scanned exam pages, screenshots) into a crisp
/// multi-page A4 PDF document in `LibraryStore`.
enum ImageImportService {
    static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "bmp", "tif", "tiff"]

    static func isImageFile(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Renders `images` onto portrait or landscape A4 pages (matching each image's aspect ratio)
    /// while respecting EXIF orientation via `UIImage.draw(in:)`.
    static func makePDFData(from images: [UIImage]) throws -> Data {
        guard !images.isEmpty else { throw ImportError.unreadable }
        let portrait = NotebookOrientation.portraitA4.pageSize
        let landscape = CGSize(width: portrait.height, height: portrait.width)
        let margin: CGFloat = 18

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: portrait))
        return renderer.pdfData { context in
            for image in images {
                let imgSize = image.size
                guard imgSize.width > 0, imgSize.height > 0 else { continue }
                let pageSize = (imgSize.width > imgSize.height * 1.12) ? landscape : portrait
                let pageBounds = CGRect(origin: .zero, size: pageSize)
                context.beginPage(withBounds: pageBounds, pageInfo: [:])

                UIColor.white.setFill()
                context.cgContext.fill(pageBounds)

                let contentRect = pageBounds.insetBy(dx: margin, dy: margin)
                let scale = min(contentRect.width / imgSize.width, contentRect.height / imgSize.height)
                let fittedSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
                let drawRect = CGRect(
                    x: contentRect.midX - fittedSize.width / 2,
                    y: contentRect.midY - fittedSize.height / 2,
                    width: fittedSize.width,
                    height: fittedSize.height
                )
                image.draw(in: drawRect)
            }
        }
    }

    @discardableResult
    static func importImages(_ images: [UIImage],
                             title: String? = nil,
                             folderID: UUID? = nil,
                             into library: LibraryStore) throws -> DocumentMeta {
        let pdfData = try makePDFData(from: images)
        guard let doc = PDFDocument(data: pdfData), doc.pageCount > 0 else {
            throw ImportError.invalidPDF
        }
        let resolvedTitle: String
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            resolvedTitle = title
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            resolvedTitle = "图片讲评 \(formatter.string(from: Date()))"
        }
        return try library.createDocument(
            title: resolvedTitle,
            pdfData: pdfData,
            layout: .pdf,
            sourceKind: .imageSet,
            sourceURL: nil,
            stagedSource: nil,
            folderID: folderID
        )
    }

    @discardableResult
    static func importImageFile(_ url: URL, folderID: UUID? = nil, into library: LibraryStore) throws -> DocumentMeta {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            throw ImportError.unreadable
        }
        let filenameTitle = url.deletingPathExtension().lastPathComponent
        return try importImages([image], title: filenameTitle, folderID: folderID, into: library)
    }
}
