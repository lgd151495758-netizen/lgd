import CoreGraphics
import Foundation
import PDFKit
import UIKit
import WebKit

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case annotatedPDF
    case currentPagePNG
    case stitchedPNG

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .annotatedPDF: return "高清 PDF（带批注）"
        case .currentPagePNG: return "当前页图片（PNG）"
        case .stitchedPNG: return "整份长图（PNG）"
        }
    }

    var fileExtension: String {
        switch self {
        case .annotatedPDF: return "pdf"
        case .currentPagePNG, .stitchedPNG: return "png"
        }
    }
}

struct ExportOptions: Equatable {
    var format: ExportFormat = .annotatedPDF
    var tapeMode: ExportTapeMode = .asDisplayed
    var includeScratchpad: Bool = true
    var currentPageIndex: Int = 0
}

struct ExportResult: Identifiable, Equatable {
    let id = UUID()
    let fileURL: URL
    let filename: String
    let pageCount: Int
    let fileSizeBytes: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}

enum ExportError: LocalizedError {
    case missingSourceDocument
    case renderFailed
    case livePageLoadTimeout

    var errorDescription: String? {
        switch self {
        case .missingSourceDocument: return "找不到文档源文件，无法导出"
        case .renderFailed: return "导出渲染失败，请重试"
        case .livePageLoadTimeout: return "网页加载超时，无法完成导出"
        }
    }
}

/// Exports annotated PDF documents and live HTML web documents into vector PDFs or crisp PNG images
/// ready for sharing to class WeChat groups, AirDrop, or the Files app.
@MainActor
enum DocumentExportService {
    /// Generates an exported file on disk in a temporary export folder and returns its metadata.
    static func export(meta: DocumentMeta,
                       annotations: DocumentAnnotations,
                       library: LibraryStore,
                       options: ExportOptions,
                       liveBridge: WebInkBridge? = nil) async throws -> ExportResult {
        var normalized = annotations
        normalized.syncActiveLayerFromTopLevel()

        let outputData: Data
        let totalPages: Int

        if meta.layout == .live {
            let (data, pages) = try await exportLiveDocument(
                meta: meta,
                annotations: normalized,
                library: library,
                options: options,
                liveBridge: liveBridge
            )
            outputData = data
            totalPages = pages
        } else {
            let (data, pages) = try exportPDFBackedDocument(
                meta: meta,
                annotations: normalized,
                library: library,
                options: options
            )
            outputData = data
            totalPages = pages
        }

        let filename = suggestedFilename(meta: meta, annotations: normalized, options: options)
        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuillmarkExports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let destination = exportDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        try outputData.write(to: destination, options: .atomic)

        return ExportResult(
            fileURL: destination,
            filename: filename,
            pageCount: totalPages,
            fileSizeBytes: Int64(outputData.count)
        )
    }

    nonisolated static func suggestedFilename(meta: DocumentMeta,
                                              annotations: DocumentAnnotations,
                                              options: ExportOptions) -> String {
        var components: [String] = [sanitizedFileStem(meta.title)]
        if annotations.hasMultipleLayers {
            let layerStem = sanitizedFileStem(annotations.activeLayerName)
            if !layerStem.isEmpty {
                components.append(layerStem)
            }
        }
        if let tapeSuffix = options.tapeMode.filenameSuffix {
            components.append(tapeSuffix)
        }
        if options.format == .currentPagePNG, meta.layout != .live {
            components.append("第\(options.currentPageIndex + 1)页")
        }
        let stem = components.filter { !$0.isEmpty }.joined(separator: "_")
        return "\(stem.isEmpty ? "羽签导出" : stem).\(options.format.fileExtension)"
    }

    nonisolated static func sanitizedFileStem(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(64))
    }

    // MARK: PDF-Backed Export (Vector)

    nonisolated static func buildAnnotatedPDFData(sourcePDF: PDFDocument,
                                                  annotations: DocumentAnnotations,
                                                  options: ExportOptions) throws -> (data: Data, pageCount: Int) {
        let docPageCount = sourcePDF.pageCount
        guard docPageCount > 0 else { throw ExportError.missingSourceDocument }

        let scratchPages = options.includeScratchpad ? annotations.nonEmptyScratchpadPages : []
        let paper = annotations.scratchpadPaper ?? .grid
        let defaultBounds = CGRect(origin: .zero, size: NotebookOrientation.portraitA4.pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: defaultBounds)

        let data = renderer.pdfData { context in
            for i in 0..<docPageCount {
                guard let page = sourcePDF.page(at: i) else { continue }
                let cropBox = page.bounds(for: .cropBox)
                let rot = ((page.rotation % 360) + 360) % 360
                let displaySize = (rot == 90 || rot == 270)
                    ? CGSize(width: cropBox.height, height: cropBox.width)
                    : cropBox.size
                let pageBounds = CGRect(origin: .zero, size: displaySize)
                context.beginPage(withBounds: pageBounds, pageInfo: [:])

                let ctx = context.cgContext
                UIColor.white.setFill()
                ctx.fill(pageBounds)

                // Draw underlying vector PDF page right-side-up in PDF bottom-left coordinates.
                ctx.saveGState()
                ctx.translateBy(x: 0, y: displaySize.height)
                ctx.scaleBy(x: 1, y: -1)
                page.draw(with: .cropBox, to: ctx)
                ctx.restoreGState()

                // Draw vector annotations in UIKit top-left coordinates matching PageInkView.
                let scale = displaySize.width / max(1, cropBox.width)
                let transform = CGAffineTransform(scaleX: scale, y: scale)
                InkVectorRenderer.drawStrokes(
                    annotations.page(i).strokes,
                    in: ctx,
                    transform: transform,
                    tapeMode: options.tapeMode
                )
            }

            if !scratchPages.isEmpty {
                let totalScratch = annotations.resolvedScratchpadPageCount
                for entry in scratchPages {
                    context.beginPage(withBounds: defaultBounds, pageInfo: [:])
                    InkVectorRenderer.drawScratchpadPage(
                        entry.strokes,
                        paper: paper,
                        pageIndex: entry.index,
                        totalPages: totalScratch,
                        bounds: defaultBounds,
                        tapeMode: options.tapeMode,
                        in: context.cgContext
                    )
                }
            }
        }

        return (data, docPageCount + scratchPages.count)
    }

    private static func exportPDFBackedDocument(meta: DocumentMeta,
                                                annotations: DocumentAnnotations,
                                                library: LibraryStore,
                                                options: ExportOptions) throws -> (Data, Int) {
        guard let sourcePDF = PDFDocument(url: library.pdfURL(for: meta.id)),
              sourcePDF.pageCount > 0 else {
            throw ExportError.missingSourceDocument
        }

        let (pdfData, totalPages) = try buildAnnotatedPDFData(
            sourcePDF: sourcePDF,
            annotations: annotations,
            options: options
        )

        switch options.format {
        case .annotatedPDF:
            return (pdfData, totalPages)

        case .currentPagePNG:
            guard let annotatedDoc = PDFDocument(data: pdfData) else { throw ExportError.renderFailed }
            let targetIndex = min(max(0, options.currentPageIndex), annotatedDoc.pageCount - 1)
            let png = try renderSinglePDFPagePNG(annotatedDoc, pageIndex: targetIndex)
            return (png, 1)

        case .stitchedPNG:
            guard let annotatedDoc = PDFDocument(data: pdfData) else { throw ExportError.renderFailed }
            let png = try renderStitchedPDFPNG(annotatedDoc)
            return (png, annotatedDoc.pageCount)
        }
    }

    // MARK: Live HTML Export

    private static func exportLiveDocument(meta: DocumentMeta,
                                           annotations: DocumentAnnotations,
                                           library: LibraryStore,
                                           options: ExportOptions,
                                           liveBridge: WebInkBridge?) async throws -> (Data, Int) {
        let baseStrokes = annotations.page(0).strokes
        let exportStrokes = InkVectorRenderer.strokesApplyingTapeMode(baseStrokes, mode: options.tapeMode)

        if let liveBridge, liveBridge.isReady {
            let needsTemporarySync = (options.tapeMode != .asDisplayed)
            if needsTemporarySync {
                await syncBridge(liveBridge, strokes: exportStrokes)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            defer {
                if needsTemporarySync {
                    liveBridge.sync(baseStrokes)
                }
            }

            if options.format == .currentPagePNG {
                let image = try await snapshotVisibleWebView(liveBridge.webView)
                guard let png = image.pngData() else { throw ExportError.renderFailed }
                return (png, 1)
            }

            let rawWebPDF = try await createWebPDF(liveBridge.webView)
            return try finalizeHTMLPDF(rawWebPDF: rawWebPDF, annotations: annotations, options: options)
        }

        // Closed HTML tab (triggered from Library): render offscreen via WebInkBridge.
        let rawWebPDF = try await renderClosedHTMLToPDF(
            meta: meta,
            strokes: exportStrokes,
            library: library
        )
        return try finalizeHTMLPDF(rawWebPDF: rawWebPDF, annotations: annotations, options: options)
    }

    private static func finalizeHTMLPDF(rawWebPDF: Data,
                                        annotations: DocumentAnnotations,
                                        options: ExportOptions) throws -> (Data, Int) {
        let combinedPDFData: Data
        let pageCount: Int
        let scratchPages = options.includeScratchpad ? annotations.nonEmptyScratchpadPages : []

        if !scratchPages.isEmpty,
           let mainDoc = PDFDocument(data: rawWebPDF),
           let scratchDoc = PDFDocument(data: renderScratchpadOnlyPDF(annotations: annotations, tapeMode: options.tapeMode)) {
            for i in 0..<scratchDoc.pageCount {
                if let page = scratchDoc.page(at: i) {
                    mainDoc.insert(page, at: mainDoc.pageCount)
                }
            }
            combinedPDFData = mainDoc.dataRepresentation() ?? rawWebPDF
            pageCount = mainDoc.pageCount
        } else {
            combinedPDFData = rawWebPDF
            pageCount = PDFDocument(data: rawWebPDF)?.pageCount ?? 1
        }

        switch options.format {
        case .annotatedPDF:
            return (combinedPDFData, pageCount)
        case .currentPagePNG:
            guard let doc = PDFDocument(data: combinedPDFData) else { throw ExportError.renderFailed }
            let png = try renderSinglePDFPagePNG(doc, pageIndex: 0)
            return (png, 1)
        case .stitchedPNG:
            guard let doc = PDFDocument(data: combinedPDFData) else { throw ExportError.renderFailed }
            let png = try renderStitchedPDFPNG(doc)
            return (png, doc.pageCount)
        }
    }

    private static func renderScratchpadOnlyPDF(annotations: DocumentAnnotations,
                                                tapeMode: ExportTapeMode) -> Data {
        let entries = annotations.nonEmptyScratchpadPages
        let paper = annotations.scratchpadPaper ?? .grid
        let total = annotations.resolvedScratchpadPageCount
        let bounds = CGRect(origin: .zero, size: NotebookOrientation.portraitA4.pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            for entry in entries {
                context.beginPage(withBounds: bounds, pageInfo: [:])
                InkVectorRenderer.drawScratchpadPage(
                    entry.strokes,
                    paper: paper,
                    pageIndex: entry.index,
                    totalPages: total,
                    bounds: bounds,
                    tapeMode: tapeMode,
                    in: context.cgContext
                )
            }
        }
    }

    private static func syncBridge(_ bridge: WebInkBridge, strokes: [InkStroke]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            bridge.sync(strokes) {
                continuation.resume()
            }
        }
    }

    private static func snapshotVisibleWebView(_ webView: WKWebView) async throws -> UIImage {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = true
        return try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? ExportError.renderFailed)
                }
            }
        }
    }

    private static func renderClosedHTMLToPDF(meta: DocumentMeta,
                                              strokes: [InkStroke],
                                              library: LibraryStore) async throws -> Data {
        guard let entry = meta.sourceEntry else { throw ExportError.missingSourceDocument }
        let folder = library.sourceFolder(for: meta.id)
        let entryURL = folder.appendingPathComponent(entry)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            throw ExportError.missingSourceDocument
        }

        let bridge = WebInkBridge(frame: CGRect(x: 0, y: 0, width: 820, height: 1180))
        let webView = bridge.webView
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        hostWindow()?.insertSubview(webView, at: 0)
        defer {
            bridge.onReady = nil
            webView.removeFromSuperview()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            func finish(_ result: Result<Void, Error>) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            bridge.onReady = {
                finish(.success(()))
            }

            if entryURL.pathExtension.lowercased() == "webarchive" {
                guard let data = try? Data(contentsOf: entryURL) else {
                    finish(.failure(ExportError.missingSourceDocument))
                    return
                }
                let base = meta.sourceURL.flatMap { URL(string: $0) } ?? URL(string: "about:blank")!
                webView.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: base)
            } else {
                webView.loadFileURL(entryURL, allowingReadAccessTo: folder)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                finish(.failure(ExportError.livePageLoadTimeout))
            }
        }

        if !strokes.isEmpty {
            await syncBridge(bridge, strokes: strokes)
            try? await Task.sleep(nanoseconds: 200_000_000)
        } else {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        return try await createWebPDF(webView)
    }

    private static func createWebPDF(_ webView: WKWebView) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: PDF -> PNG Rasterization (Memory-Safe for 4GB iPad Air 4)

    nonisolated static func renderSinglePDFPagePNG(_ document: PDFDocument,
                                                   pageIndex: Int,
                                                   targetWidthPixels: CGFloat = 1440) throws -> Data {
        guard let page = document.page(at: pageIndex) else { throw ExportError.renderFailed }
        let displaySize = visualPageSize(of: page)
        let scale = min(2.5, max(1.0, targetWidthPixels / max(1, displaySize.width)))
        let pixelSize = CGSize(width: round(displaySize.width * scale), height: round(displaySize.height * scale))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let image = renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: pixelSize))
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pixelSize.height)
            ctx.scaleBy(x: scale, y: -scale)
            page.draw(with: .cropBox, to: ctx)
            ctx.restoreGState()
        }
        guard let png = image.pngData() else { throw ExportError.renderFailed }
        return png
    }

    nonisolated static func renderStitchedPDFPNG(_ document: PDFDocument,
                                                 targetWidthPixels: CGFloat = 1240,
                                                 maxTotalHeightPixels: CGFloat = 14_000) throws -> Data {
        let count = document.pageCount
        guard count > 0 else { throw ExportError.renderFailed }

        let pageSizes: [CGSize] = (0..<count).compactMap { idx in
            document.page(at: idx).map(visualPageSize(of:))
        }
        guard !pageSizes.isEmpty else { throw ExportError.renderFailed }

        let gap: CGFloat = 14
        let rawTotalHeightAtTargetWidth: CGFloat = pageSizes.reduce(0) { acc, sz in
            acc + (sz.height * (targetWidthPixels / max(1, sz.width)))
        } + gap * CGFloat(max(0, pageSizes.count - 1))

        let widthFactor = rawTotalHeightAtTargetWidth > maxTotalHeightPixels
            ? max(0.35, maxTotalHeightPixels / rawTotalHeightAtTargetWidth)
            : 1.0
        let finalWidth = max(480, floor(targetWidthPixels * widthFactor))

        var rects: [CGRect] = []
        var cursorY: CGFloat = 0
        for sz in pageSizes {
            let h = ceil(sz.height * (finalWidth / max(1, sz.width)))
            rects.append(CGRect(x: 0, y: cursorY, width: finalWidth, height: h))
            cursorY += h + gap
        }
        let totalHeight = max(1, cursorY - gap)
        let canvasSize = CGSize(width: finalWidth, height: totalHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let image = renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            UIColor(white: 0.92, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: canvasSize))

            for (idx, rect) in rects.enumerated() {
                guard let page = document.page(at: idx) else { continue }
                let displaySize = visualPageSize(of: page)
                let scale = rect.width / max(1, displaySize.width)

                UIColor.white.setFill()
                ctx.fill(rect)

                ctx.saveGState()
                ctx.clip(to: rect)
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: scale, y: -scale)
                page.draw(with: .cropBox, to: ctx)
                ctx.restoreGState()
            }
        }
        guard let png = image.pngData() else { throw ExportError.renderFailed }
        return png
    }

    nonisolated static func visualPageSize(of page: PDFPage) -> CGSize {
        let cropBox = page.bounds(for: .cropBox)
        let rot = ((page.rotation % 360) + 360) % 360
        return (rot == 90 || rot == 270)
            ? CGSize(width: cropBox.height, height: cropBox.width)
            : cropBox.size
    }

    private static func hostWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }
}
