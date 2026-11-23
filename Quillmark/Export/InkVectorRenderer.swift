import CoreGraphics
import Foundation
import UIKit

enum ExportTapeMode: String, Codable, CaseIterable, Identifiable {
    /// Keep each cover tape in its current covered/revealed state.
    case asDisplayed
    /// Hide/peel all cover tapes so underlying answers remain crisp and readable ("解析版").
    case revealAll
    /// Force all cover tapes to be opaque/covered ("学生练习版").
    case coverAll

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .asDisplayed: return "按当前状态"
        case .revealAll: return "全部揭开（解析版）"
        case .coverAll: return "全部盖住（学生版）"
        }
    }

    var filenameSuffix: String? {
        switch self {
        case .asDisplayed: return nil
        case .revealAll: return "解析版"
        case .coverAll: return "学生版"
        }
    }
}

/// Pure vector Core Graphics renderer for exporting strokes, shaded shapes, cover tapes, and
/// scratchpad whiteboard pages into PDFs and high-DPI PNG images.
enum InkVectorRenderer {
    /// Transforms a stroke array according to `tapeMode` (used by both PDF export and live HTML DOM export).
    static func strokesApplyingTapeMode(_ strokes: [InkStroke], mode: ExportTapeMode) -> [InkStroke] {
        switch mode {
        case .asDisplayed:
            return strokes
        case .revealAll:
            return strokes.filter { !$0.isTape }
        case .coverAll:
            return strokes.map { stroke in
                guard stroke.isTape else { return stroke }
                var covered = stroke
                covered.revealed = false
                return covered
            }
        }
    }

    /// Draws `strokes` into `ctx` (UIKit top-left coordinates) with full vector sharpness.
    static func drawStrokes(_ strokes: [InkStroke],
                            in ctx: CGContext,
                            transform: CGAffineTransform = .identity,
                            tapeMode: ExportTapeMode = .asDisplayed) {
        let filtered = strokesApplyingTapeMode(strokes, mode: tapeMode)
        guard !filtered.isEmpty else { return }

        // 1. Translucent 18% geometric shading fills underneath outlines.
        for stroke in filtered {
            guard let fillColor = stroke.fillColor,
                  let fillPath = stroke.fillPath(transform: transform) else { continue }
            ctx.saveGState()
            ctx.setAlpha(0.18)
            ctx.setFillColor(fillColor.cgColor)
            ctx.addPath(fillPath)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // 2. Legacy highlighters (multiply blend).
        for stroke in filtered where stroke.isHighlighter {
            let path = stroke.outlinePath(transform: transform, finished: true)
            ctx.saveGState()
            ctx.setAlpha(CGFloat(PageInkView.highlighterOpacity))
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(stroke.color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // 3. Cover tapes.
        for stroke in filtered where stroke.isTape {
            let path = stroke.outlinePath(transform: transform, finished: true)
            ctx.saveGState()
            let revealed = (tapeMode == .coverAll) ? false : stroke.isRevealed
            ctx.setAlpha(revealed ? 0.16 : 0.98)
            ctx.setFillColor(stroke.color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.24).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 4. Pen & parametric geometric outlines.
        for stroke in filtered where !stroke.isHighlighter && !stroke.isTape {
            let path = stroke.outlinePath(transform: transform, finished: true)
            ctx.saveGState()
            ctx.setFillColor(stroke.color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    /// Renders one scratchpad page (paper background + subtle header label + fitted vector ink)
    /// into `bounds` (UIKit top-left coordinates).
    static func drawScratchpadPage(_ strokes: [InkStroke],
                                   paper: ScratchpadPaperStyle,
                                   pageIndex: Int,
                                   totalPages: Int,
                                   bounds: CGRect,
                                   tapeMode: ExportTapeMode,
                                   in ctx: CGContext) {
        BlankNotebookService.drawPaperBackground(paper, in: bounds, ctx: ctx)

        // Subtle top header bar identifying the scratchpad page.
        let headerHeight: CGFloat = 30
        let headerRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: headerHeight)
        ctx.saveGState()
        ctx.setFillColor(UIColor(red: 0.99, green: 0.96, blue: 0.87, alpha: 0.92).cgColor)
        ctx.fill(headerRect)
        ctx.setStrokeColor(UIColor(red: 0.84, green: 0.76, blue: 0.56, alpha: 0.7).cgColor)
        ctx.setLineWidth(0.75)
        ctx.move(to: CGPoint(x: bounds.minX, y: headerRect.maxY))
        ctx.addLine(to: CGPoint(x: bounds.maxX, y: headerRect.maxY))
        ctx.strokePath()
        ctx.restoreGState()

        let title = "演算便签 · 第 \(pageIndex + 1)/\(max(1, totalPages)) 页" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor(red: 0.36, green: 0.30, blue: 0.16, alpha: 1.0),
        ]
        title.draw(at: CGPoint(x: bounds.minX + 16, y: bounds.minY + 8), withAttributes: attrs)

        let visibleStrokes = strokesApplyingTapeMode(strokes, mode: tapeMode)
        guard !visibleStrokes.isEmpty else { return }

        // Compute content bounding box so strokes from any floating/full scratchpad size fit cleanly.
        let contentArea = CGRect(
            x: bounds.minX + 18,
            y: headerRect.maxY + 14,
            width: max(1, bounds.width - 36),
            height: max(1, bounds.height - headerHeight - 32)
        )
        var unionBox = CGRect.null
        for stroke in visibleStrokes {
            let b = stroke.outlinePath(finished: true).boundingBoxOfPath
            if !b.isNull, !b.isEmpty {
                unionBox = unionBox.union(b)
            }
            if let f = stroke.fillPath()?.boundingBoxOfPath, !f.isNull, !f.isEmpty {
                unionBox = unionBox.union(f)
            }
        }
        guard !unionBox.isNull else { return }

        // Preserve 1:1 scale when strokes already fit inside contentArea; shrink gracefully if larger.
        let originX = min(0, unionBox.minX)
        let originY = min(0, unionBox.minY)
        let extentW = max(1, unionBox.maxX - originX)
        let extentH = max(1, unionBox.maxY - originY)
        let scale = min(1.0, min(contentArea.width / extentW, contentArea.height / extentH))
        let transform = CGAffineTransform(translationX: contentArea.minX - originX * scale,
                                          y: contentArea.minY - originY * scale)
            .scaledBy(x: scale, y: scale)

        drawStrokes(visibleStrokes, in: ctx, transform: transform, tapeMode: tapeMode)
    }
}
