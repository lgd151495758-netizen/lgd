import CoreGraphics
import Foundation
import PDFKit
import UIKit

/// Immutable snapshot of one visible PDF page's geometry and annotations inside a projection capture rect.
struct PDFProjectionPageSlice {
    let pageIndex: Int
    /// Visual bounding rect of this page in capture-point coordinates (top-left origin).
    let frameInCapture: CGRect
    /// Exact affine transform mapping top-left PDF page ink coordinates into capture-point coordinates.
    let inkToCaptureTransform: CGAffineTransform
    /// Visible committed (or live-erasing preview) strokes on this page.
    let strokes: [InkStroke]
}

/// Immutable snapshot of an optional floating sticky-note card overlaid above the PDF pages.
struct PDFProjectionFloatingCard {
    let rect: CGRect
    let image: CGImage
}

/// Pure value-type render request captured on the main thread in < 0.2ms and rendered asynchronously
/// on `PDFProjectionRenderer`'s private serial queue.
struct PDFProjectionFrameRequest {
    let pdfURL: URL
    let documentRevision: UInt64
    let displayBox: PDFDisplayBox
    let captureSize: CGSize
    let outputScale: CGFloat
    let backgroundColor: CGColor
    let pages: [PDFProjectionPageSlice]
    let floatingScratchpad: PDFProjectionFloatingCard?
    /// True while the user is actively dragging, flicking, decelerating, or zooming.
    let isFastMotion: Bool
}

/// Diagnostic snapshot of `PDFProjectionRenderer`'s internal LRU page cache (used by unit tests).
struct PDFProjectionCacheStats: Equatable {
    let cachedPageCount: Int
    let cachedByteCount: Int
    let pageRasterizeCount: Int
    let cacheHitCount: Int
}

/// Off-main-thread PDF external-display frame renderer with a memory-bounded LRU `CGImage` page cache.
///
/// Why this exists:
/// `PDFView.drawHierarchy(in:afterScreenUpdates:)` forces a synchronous GPU-to-CPU readback and
/// full-screen re-rasterization on the main thread at 24 fps, stalling scrolling on iPad Air 4.
/// Instead, `PDFProjectionRenderer` owns a dedicated read-only `PDFDocument` exclusively on a
/// private serial background queue (zero PDFKit thread contention with `PDFView`), caches rasterized
/// page bitmaps in a 48 MB / 4-page LRU cache, and composites visible pages + crisp vector ink
/// (`InkVectorRenderer`) + floating scratchpad cards completely off the main thread.
final class PDFProjectionRenderer {
    static let maxCachedPages = 4
    static let maxCacheBytes = 48 * 1024 * 1024
    static let maxSinglePageBytes = 24 * 1024 * 1024
    static let maxCachedPageDimension: CGFloat = 2200

    private struct CachedPageEntry {
        let image: CGImage
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int
        var lastUsedTick: UInt64
    }

    private let renderQueue = DispatchQueue(label: "app.quillmark.pdf-projection-renderer", qos: .userInitiated)
    private var memoryObserver: NSObjectProtocol?

    // All properties below are accessed exclusively on `renderQueue`.
    private var loadedURL: URL?
    private var loadedRevision: UInt64 = 0
    private var document: PDFDocument?
    private var cache: [Int: CachedPageEntry] = [:]
    private var totalCacheBytes: Int = 0
    private var accessTick: UInt64 = 0
    private var pageRasterizeCount: Int = 0
    private var cacheHitCount: Int = 0

    init() {
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clearCache()
        }
    }

    deinit {
        if let memoryObserver {
            NotificationCenter.default.removeObserver(memoryObserver)
        }
    }

    /// Asynchronously renders a projection frame off the main thread and delivers the result on `.main`.
    func render(_ request: PDFProjectionFrameRequest, completion: @escaping (UIImage?) -> Void) {
        renderQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let image: UIImage? = autoreleasepool {
                self.renderOnQueue(request)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    /// Drops cached page bitmaps and the private `PDFDocument` handle (safe to call from any thread).
    func clearCache() {
        renderQueue.async { [weak self] in
            self?.resetStateOnQueue()
        }
    }

    /// Invalidates the cached document and bitmaps after the PDF on disk changes (e.g. blank page insert).
    func invalidateDocument() {
        clearCache()
    }

    /// Thread-safe snapshot of cache metrics for verification and tests.
    func cacheStats() -> PDFProjectionCacheStats {
        renderQueue.sync {
            PDFProjectionCacheStats(
                cachedPageCount: cache.count,
                cachedByteCount: totalCacheBytes,
                pageRasterizeCount: pageRasterizeCount,
                cacheHitCount: cacheHitCount
            )
        }
    }

    // MARK: Serial Queue Implementation

    private func resetStateOnQueue() {
        cache.removeAll(keepingCapacity: false)
        totalCacheBytes = 0
        document = nil
        loadedURL = nil
    }

    private func ensureDocumentOnQueue(url: URL, revision: UInt64) -> PDFDocument? {
        if let existing = document, loadedURL == url, loadedRevision == revision {
            return existing
        }
        resetStateOnQueue()
        guard let opened = PDFDocument(url: url) else {
            return nil
        }
        document = opened
        loadedURL = url
        loadedRevision = revision
        return opened
    }

    private func renderOnQueue(_ request: PDFProjectionFrameRequest) -> UIImage? {
        guard request.captureSize.width > 0, request.captureSize.height > 0,
              request.outputScale.isFinite, request.outputScale > 0 else {
            return nil
        }
        guard let doc = ensureDocumentOnQueue(url: request.pdfURL, revision: request.documentRevision) else {
            return nil
        }

        let outPixelW = max(1, Int((request.captureSize.width * request.outputScale).rounded()))
        let outPixelH = max(1, Int((request.captureSize.height * request.outputScale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: outPixelW,
            height: outPixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // Flip into UIKit top-left capture-point coordinates: (0,0) top-left -> (captureW, captureH) bottom-right.
        ctx.translateBy(x: 0, y: CGFloat(outPixelH))
        ctx.scaleBy(
            x: CGFloat(outPixelW) / max(1, request.captureSize.width),
            y: -CGFloat(outPixelH) / max(1, request.captureSize.height)
        )

        ctx.setFillColor(request.backgroundColor)
        ctx.fill(CGRect(origin: .zero, size: request.captureSize))

        for slice in request.pages {
            guard slice.pageIndex >= 0, slice.pageIndex < doc.pageCount,
                  let page = doc.page(at: slice.pageIndex) else { continue }
            let rect = slice.frameInCapture
            guard rect.width > 0.5, rect.height > 0.5 else { continue }

            // Lightweight page edge shadow (avoids expensive software Gaussian blur on multi-megapixel rects).
            if !request.isFastMotion {
                ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08))
                ctx.fill(rect.offsetBy(dx: 0, dy: 2))
            }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)

            let displaySize = Self.displaySize(of: page, box: request.displayBox)
            let desiredPixelW = rect.width * request.outputScale
            let desiredPixelH = rect.height * request.outputScale

            // When settled at deep zoom beyond the single-page bitmap cap, draw the visible PDF vector
            // region directly into the output context for 100% sharp text without large bitmap allocations.
            let needsDirectVector = !request.isFastMotion && (
                desiredPixelW > Self.maxCachedPageDimension * 1.15
                    || desiredPixelH > Self.maxCachedPageDimension * 1.15
            )

            if needsDirectVector {
                ctx.saveGState()
                ctx.clip(to: rect)
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(
                    x: rect.width / max(1, displaySize.width),
                    y: -rect.height / max(1, displaySize.height)
                )
                page.draw(with: request.displayBox, to: ctx)
                ctx.restoreGState()
            } else if let pageImage = cachedPageImageOnQueue(
                page: page,
                pageIndex: slice.pageIndex,
                displayBox: request.displayBox,
                displaySize: displaySize,
                desiredPixelWidth: desiredPixelW,
                desiredPixelHeight: desiredPixelH,
                isFastMotion: request.isFastMotion
            ) {
                ctx.saveGState()
                ctx.interpolationQuality = request.isFastMotion ? .low : .high
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(pageImage, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()
            }

            // Crisp hairline page border separating adjacent pages cleanly on bright projectors.
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12))
            ctx.setLineWidth(0.75)
            ctx.stroke(rect)

            if !slice.strokes.isEmpty {
                InkVectorRenderer.drawStrokes(
                    slice.strokes,
                    in: ctx,
                    transform: slice.inkToCaptureTransform,
                    tapeMode: .asDisplayed
                )
            }
        }

        if let card = request.floatingScratchpad, card.rect.width > 1, card.rect.height > 1 {
            Self.drawFloatingCard(card, in: ctx, isFastMotion: request.isFastMotion)
        }

        guard let cgOut = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cgOut, scale: request.outputScale, orientation: .up)
    }

    private func cachedPageImageOnQueue(
        page: PDFPage,
        pageIndex: Int,
        displayBox: PDFDisplayBox,
        displaySize: CGSize,
        desiredPixelWidth: CGFloat,
        desiredPixelHeight: CGFloat,
        isFastMotion: Bool
    ) -> CGImage? {
        let target = Self.quantizedTargetSize(
            displaySize: displaySize,
            desiredWidth: desiredPixelWidth,
            desiredHeight: desiredPixelHeight
        )

        if var existing = cache[pageIndex] {
            let acceptable: Bool
            if isFastMotion {
                // During rapid scrolling, reuse any reasonably sized (or higher-res!) cached bitmap immediately.
                acceptable = existing.pixelWidth >= Int(CGFloat(target.width) * 0.65)
            } else {
                // When settled, upgrade fast-scroll bitmaps to full crisp resolution while avoiding jitter thrash.
                acceptable = existing.pixelWidth >= Int(CGFloat(target.width) * 0.92)
                    && existing.pixelWidth <= Int(CGFloat(target.width) * 1.45)
            }
            if acceptable {
                accessTick &+= 1
                existing.lastUsedTick = accessTick
                cache[pageIndex] = existing
                cacheHitCount += 1
                return existing.image
            }
        }

        guard let rendered = Self.rasterizePage(
            page,
            displayBox: displayBox,
            displaySize: displaySize,
            pixelWidth: target.width,
            pixelHeight: target.height
        ) else {
            return cache[pageIndex]?.image
        }

        pageRasterizeCount += 1
        let byteCount = target.width * target.height * 4
        if let old = cache.removeValue(forKey: pageIndex) {
            totalCacheBytes = max(0, totalCacheBytes - old.byteCount)
        }
        accessTick &+= 1
        cache[pageIndex] = CachedPageEntry(
            image: rendered,
            pixelWidth: target.width,
            pixelHeight: target.height,
            byteCount: byteCount,
            lastUsedTick: accessTick
        )
        totalCacheBytes += byteCount
        evictIfNeededOnQueue(protecting: pageIndex)
        return rendered
    }

    private func evictIfNeededOnQueue(protecting protectedPageIndex: Int) {
        while (cache.count > Self.maxCachedPages || totalCacheBytes > Self.maxCacheBytes), cache.count > 1 {
            guard let victim = cache
                .filter({ $0.key != protectedPageIndex })
                .min(by: { $0.value.lastUsedTick < $1.value.lastUsedTick }) else {
                break
            }
            cache.removeValue(forKey: victim.key)
            totalCacheBytes = max(0, totalCacheBytes - victim.value.byteCount)
        }
    }

    // MARK: Pure CoreGraphics Helpers

    private static func displaySize(of page: PDFPage, box: PDFDisplayBox) -> CGSize {
        let bounds = page.bounds(for: box)
        let rot = ((page.rotation % 360) + 360) % 360
        if rot == 90 || rot == 270 {
            return CGSize(width: max(1, bounds.height), height: max(1, bounds.width))
        }
        return CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
    }

    private static func quantizedTargetSize(
        displaySize: CGSize,
        desiredWidth: CGFloat,
        desiredHeight: CGFloat
    ) -> (width: Int, height: Int) {
        let aspect = displaySize.height / max(1, displaySize.width)
        var w = max(64, desiredWidth)
        var h = max(64, desiredHeight)

        // Cap max side dimension.
        let maxSide = max(w, h)
        if maxSide > maxCachedPageDimension {
            let factor = maxCachedPageDimension / maxSide
            w *= factor
            h *= factor
        }

        // Cap per-page uncompressed RGBA memory budget.
        let maxPixels = CGFloat(maxSinglePageBytes / 4)
        let pixels = w * h
        if pixels > maxPixels {
            let factor = sqrt(maxPixels / pixels)
            w *= factor
            h *= factor
        }

        // Quantize width to 64px buckets so sub-pixel scroll/layout jitter hits the cache.
        let bucketW = max(64, Int(((w + 31) / 64).rounded(.down)) * 64)
        let bucketH = max(64, Int((CGFloat(bucketW) * aspect).rounded()))
        return (bucketW, bucketH)
    }

    private static func rasterizePage(
        _ page: PDFPage,
        displayBox: PDFDisplayBox,
        displaySize: CGSize,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // Raw CGContext already uses bottom-left PDF coordinates, so `page.draw` renders right-side-up.
        ctx.scaleBy(
            x: CGFloat(pixelWidth) / max(1, displaySize.width),
            y: CGFloat(pixelHeight) / max(1, displaySize.height)
        )
        page.draw(with: displayBox, to: ctx)
        return ctx.makeImage()
    }

    private static func drawFloatingCard(
        _ card: PDFProjectionFloatingCard,
        in ctx: CGContext,
        isFastMotion: Bool
    ) {
        let radius = min(10, min(card.rect.width, card.rect.height) * 0.5)
        let roundedPath = CGPath(roundedRect: card.rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        if !isFastMotion {
            ctx.setShadow(
                offset: CGSize(width: 0, height: -4),
                blur: 12,
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18)
            )
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(roundedPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(roundedPath)
        ctx.clip()
        ctx.interpolationQuality = isFastMotion ? .low : .high
        ctx.translateBy(x: card.rect.minX, y: card.rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(card.image, in: CGRect(origin: .zero, size: card.rect.size))
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 0.78, green: 0.70, blue: 0.52, alpha: 0.75))
        ctx.setLineWidth(1.0)
        ctx.addPath(roundedPath)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
