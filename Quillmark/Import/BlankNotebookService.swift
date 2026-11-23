import CoreGraphics
import Foundation
import PDFKit
import UIKit

enum NotebookOrientation: String, Codable, CaseIterable, Identifiable {
    case portraitA4
    case landscape16x9

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .portraitA4: return "竖版 A4"
        case .landscape16x9: return "横版 16:9 板书"
        }
    }

    var pageSize: CGSize {
        switch self {
        case .portraitA4: return CGSize(width: 595.28, height: 841.89)
        case .landscape16x9: return CGSize(width: 960, height: 540)
        }
    }
}

/// Creates pure-vector blank math notebooks and inserts crisp blank pages into existing PDFs.
enum BlankNotebookService {
    /// Renders a math paper background (blank / grid / dot / graph) in UIKit top-left coordinates.
    static func drawPaperBackground(_ style: ScratchpadPaperStyle, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        UIColor.white.setFill()
        ctx.fill(rect)

        switch style {
        case .blank:
            break

        case .grid:
            let step: CGFloat = 24
            ctx.setStrokeColor(UIColor(red: 0.42, green: 0.56, blue: 0.74, alpha: 0.22).cgColor)
            ctx.setLineWidth(0.6)
            var x = rect.minX + step
            while x < rect.maxX {
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += step
            }
            var y = rect.minY + step
            while y < rect.maxY {
                ctx.move(to: CGPoint(x: rect.minX, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += step
            }
            ctx.strokePath()

        case .dot:
            let step: CGFloat = 24
            let r: CGFloat = 1.35
            ctx.setFillColor(UIColor(red: 0.40, green: 0.50, blue: 0.65, alpha: 0.36).cgColor)
            var y = rect.minY + step
            while y < rect.maxY {
                var x = rect.minX + step
                while x < rect.maxX {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += step
                }
                y += step
            }

        case .graph:
            let minor: CGFloat = 16
            let major: CGFloat = 80
            ctx.setStrokeColor(UIColor(red: 0.38, green: 0.54, blue: 0.72, alpha: 0.14).cgColor)
            ctx.setLineWidth(0.5)
            var x = rect.minX + minor
            while x < rect.maxX {
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += minor
            }
            var y = rect.minY + minor
            while y < rect.maxY {
                ctx.move(to: CGPoint(x: rect.minX, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += minor
            }
            ctx.strokePath()

            ctx.setStrokeColor(UIColor(red: 0.32, green: 0.48, blue: 0.68, alpha: 0.28).cgColor)
            ctx.setLineWidth(0.95)
            x = rect.minX + major
            while x < rect.maxX {
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += major
            }
            y = rect.minY + major
            while y < rect.maxY {
                ctx.move(to: CGPoint(x: rect.minX, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += major
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    static func makePDFData(paper: ScratchpadPaperStyle,
                            orientation: NotebookOrientation,
                            pageCount: Int) -> Data {
        let count = min(max(1, pageCount), 50)
        let bounds = CGRect(origin: .zero, size: orientation.pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            for _ in 0..<count {
                context.beginPage(withBounds: bounds, pageInfo: [:])
                drawPaperBackground(paper, in: bounds, ctx: context.cgContext)
            }
        }
    }

    static func makeSingleBlankPage(size: CGSize, paper: ScratchpadPaperStyle) -> PDFPage? {
        let safeSize = CGSize(
            width: max(200, size.width.isFinite ? size.width : NotebookOrientation.portraitA4.pageSize.width),
            height: max(200, size.height.isFinite ? size.height : NotebookOrientation.portraitA4.pageSize.height)
        )
        let bounds = CGRect(origin: .zero, size: safeSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            context.beginPage(withBounds: bounds, pageInfo: [:])
            drawPaperBackground(paper, in: bounds, ctx: context.cgContext)
        }
        return PDFDocument(data: data)?.page(at: 0)
    }

    @discardableResult
    static func createNotebook(title: String,
                               paper: ScratchpadPaperStyle,
                               orientation: NotebookOrientation,
                               pageCount: Int,
                               folderID: UUID? = nil,
                               into library: LibraryStore) throws -> DocumentMeta {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmed.isEmpty ? defaultNotebookTitle() : trimmed
        let pdfData = makePDFData(paper: paper, orientation: orientation, pageCount: pageCount)
        return try library.createDocument(
            title: resolvedTitle,
            pdfData: pdfData,
            layout: .pdf,
            sourceKind: .blankNotebook,
            sourceURL: nil,
            stagedSource: nil,
            folderID: folderID
        )
    }

    static func defaultNotebookTitle(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "数学板书 \(formatter.string(from: date))"
    }
}
