import SwiftUI

/// Floating editor toolbar: tool selector, options of the current tool, undo/redo, finger drawing.
struct ToolbarView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject private var presentation = PresentationCenter.shared

    private var tool: ToolSettings { session.tool }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                toolButton(title: "画笔", symbol: "pencil", selected: tool.kind == .pen) {
                    session.tool.select(.pen)
                    session.tool.pen = .ballpoint
                }
                toolButton(title: "套索", symbol: "lasso", selected: tool.kind == .lasso) {
                    session.tool.select(.lasso)
                }
                toolButton(title: "胶带", symbol: "bandage", selected: tool.kind == .tape) {
                    session.tool.select(.tape)
                }
                toolButton(title: "图形", symbol: "square.on.circle", selected: tool.kind == .shape) {
                    session.tool.select(.shape)
                }
                toolButton(title: "激光笔", symbol: "laser.burst", selected: tool.kind == .laser) {
                    session.tool.select(.laser)
                }
                toolButton(title: "橡皮", symbol: "eraser", selected: tool.kind == .eraser) {
                    session.tool.select(.eraser)
                }
                divider
                toolButton(title: "圆规", symbol: "compass.drawing", selected: session.geometryAid == .compass) {
                    session.toggleGeometryAid(.compass)
                }
                if session.meta.layout == .live {
                    toolButton(title: "草稿", symbol: "note.text", selected: session.isScratchpadOpen) {
                        session.toggleScratchpad()
                    }
                }
                divider
                options
                divider
                Button {
                    session.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!session.canUndo)
                .accessibilityLabel("撤销")
                Button {
                    session.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!session.canRedo)
                .accessibilityLabel("重做")
                divider
                Toggle(isOn: $session.tool.fingerDrawing) {
                    Image(systemName: "hand.draw")
                }
                .toggleStyle(.button)
                .accessibilityLabel("手指书写")
                if presentation.isExternalDisplayConnected {
                    divider
                    Toggle(isOn: $presentation.contentOnly) {
                        Label("投屏仅内容", systemImage: "rectangle.on.rectangle")
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                    }
                    .toggleStyle(.button)
                    .accessibilityHint("打开：投屏画面只显示文档内容，工具栏只在 iPad 上显示")
                }
            }
            .font(.title3)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var options: some View {
        switch tool.kind {
        case .pen:
            ForEach(ToolSettings.palette, id: \.self) { color in
                colorButton(color, selected: tool.color == color) { session.tool.color = color }
            }
            divider
            ForEach(ToolSettings.widthPresets, id: \.self) { width in
                sizeButton(diameter: CGFloat(width) * 3 + 2, selected: tool.width == width) {
                    session.tool.width = width
                }
            }
            divider
            Picker("线型", selection: $session.tool.lineStyle) {
                ForEach(StrokeLineStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 132)
            Toggle(isOn: $session.tool.drawAndHold) {
                Label("成形", systemImage: "square.on.circle")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            }
            .toggleStyle(.button)
            .accessibilityLabel("画完按住自动成形")

        case .lasso:
            Label("圈选或轻点笔迹：拖动移动 · 拖角缩放 · 浮条改色/复制/删除", systemImage: "lasso")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

        case .tape:
            ForEach(ToolSettings.tapePalette, id: \.self) { color in
                colorButton(color, selected: tool.tapeColor == color) { session.tool.tapeColor = color }
            }
            divider
            ForEach(ToolSettings.tapeWidthPresets, id: \.self) { width in
                sizeButton(diameter: CGFloat(width) * 0.45 + 6, selected: tool.tapeWidth == width,
                           shape: AnyShape(RoundedRectangle(cornerRadius: 3))) {
                    session.tool.tapeWidth = width
                }
            }
            Toggle(isOn: $session.tool.tapeStraight) {
                Label("直线", systemImage: "line.diagonal")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            }
            .toggleStyle(.button)
            divider
            Button {
                session.setAllTapesRevealed(false)
            } label: {
                Label("全盖", systemImage: "eye.slash")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            Button {
                session.setAllTapesRevealed(true)
            } label: {
                Label("全揭", systemImage: "eye")
                    .font(.callout)
            }
            .buttonStyle(.bordered)

        case .shape:
            ForEach(ShapePreset.allCases) { preset in
                shapePresetButton(preset, selected: tool.shapePreset == preset) {
                    session.tool.shapePreset = preset
                }
            }
            divider
            ForEach(ToolSettings.palette, id: \.self) { color in
                colorButton(color, selected: tool.color == color) { session.tool.color = color }
            }
            divider
            ForEach(ToolSettings.widthPresets, id: \.self) { width in
                sizeButton(diameter: CGFloat(width) * 3 + 2, selected: tool.width == width) {
                    session.tool.width = width
                }
            }
            divider
            Picker("线型", selection: $session.tool.lineStyle) {
                ForEach(StrokeLineStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 132)
            if tool.shapePreset.supportsFill {
                Toggle(isOn: $session.tool.shapeFilled) {
                    Label("阴影", systemImage: "square.fill.on.square")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                }
                .toggleStyle(.button)
                .accessibilityLabel("半透明阴影填充")
            }

        case .laser:
            ForEach(ToolSettings.laserPalette, id: \.self) { color in
                colorButton(color, selected: tool.laserColor == color) { session.tool.laserColor = color }
            }

        case .eraser:
            Picker("橡皮模式", selection: $session.tool.eraserMode) {
                ForEach(EraserMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            ForEach(ToolSettings.eraserRadiusPresets, id: \.self) { radius in
                sizeButton(diameter: CGFloat(radius) + 6, selected: tool.eraserRadius == radius, filled: false) {
                    session.tool.eraserRadius = radius
                }
            }
        }
    }

    private var divider: some View {
        Divider().frame(height: 26)
    }

    private func shapePresetButton(_ preset: ShapePreset, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ShapePresetIcon(preset: preset)
                    .frame(width: 20, height: 16)
                Text(preset.displayName).font(.caption2)
            }
            .frame(minWidth: 42)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toolButton(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                Text(title).font(.caption2)
            }
            .frame(minWidth: 42)
            .padding(.vertical, 2)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func colorButton(_ color: RGBAColor, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 2 : 0.8).padding(selected ? -4 : 0))
        }
        .buttonStyle(.plain)
    }

    private func sizeButton(diameter: CGFloat, selected: Bool, filled: Bool = true,
                            shape: AnyShape = AnyShape(Circle()), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if filled {
                    shape.fill(Color.primary).frame(width: min(diameter, 22), height: min(diameter, 22))
                } else {
                    Circle().stroke(Color.primary, lineWidth: 1.5).frame(width: min(diameter, 24), height: min(diameter, 24))
                }
            }
            .frame(width: 30, height: 30)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Crisp mini vector icon for each standard mathematical shape preset.
private struct ShapePresetIcon: View {
    let preset: ShapePreset

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let pad: CGFloat = 2
            let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

            var path = Path()
            switch preset {
            case .segment:
                path.move(to: CGPoint(x: pad, y: h - pad))
                path.addLine(to: CGPoint(x: w - pad, y: pad))
            case .arrow:
                path.move(to: CGPoint(x: pad, y: h - pad))
                path.addLine(to: CGPoint(x: w - pad, y: pad))
                path.move(to: CGPoint(x: w - pad - 5, y: pad + 0.5))
                path.addLine(to: CGPoint(x: w - pad, y: pad))
                path.addLine(to: CGPoint(x: w - pad - 1, y: pad + 5))
            case .rightTriangle:
                path.move(to: CGPoint(x: pad + 1, y: pad))
                path.addLine(to: CGPoint(x: pad + 1, y: h - pad))
                path.addLine(to: CGPoint(x: w - pad, y: h - pad))
                path.closeSubpath()
                path.move(to: CGPoint(x: pad + 1, y: h - pad - 4))
                path.addLine(to: CGPoint(x: pad + 5, y: h - pad - 4))
                path.addLine(to: CGPoint(x: pad + 5, y: h - pad))
            case .isoscelesTriangle:
                path.move(to: CGPoint(x: w / 2, y: pad))
                path.addLine(to: CGPoint(x: w - pad - 2, y: h - pad))
                path.addLine(to: CGPoint(x: pad + 2, y: h - pad))
                path.closeSubpath()
            case .equilateralTriangle:
                path.move(to: CGPoint(x: w / 2, y: pad + 0.5))
                path.addLine(to: CGPoint(x: w - pad, y: h - pad))
                path.addLine(to: CGPoint(x: pad, y: h - pad))
                path.closeSubpath()
            case .rectangle:
                path.addRect(CGRect(x: pad, y: pad + 1, width: w - 2 * pad, height: h - 2 * pad - 2))
            case .parallelogram:
                path.move(to: CGPoint(x: pad + 4, y: pad + 1))
                path.addLine(to: CGPoint(x: w - pad, y: pad + 1))
                path.addLine(to: CGPoint(x: w - pad - 4, y: h - pad - 1))
                path.addLine(to: CGPoint(x: pad, y: h - pad - 1))
                path.closeSubpath()
            case .rhombus:
                path.move(to: CGPoint(x: w / 2, y: pad))
                path.addLine(to: CGPoint(x: w - pad, y: h / 2))
                path.addLine(to: CGPoint(x: w / 2, y: h - pad))
                path.addLine(to: CGPoint(x: pad, y: h / 2))
                path.closeSubpath()
            case .trapezoid:
                path.move(to: CGPoint(x: pad + 3.5, y: pad + 1))
                path.addLine(to: CGPoint(x: w - pad - 3.5, y: pad + 1))
                path.addLine(to: CGPoint(x: w - pad, y: h - pad - 1))
                path.addLine(to: CGPoint(x: pad, y: h - pad - 1))
                path.closeSubpath()
            case .pentagon:
                let r = min(w, h) * 0.44
                let cx = w / 2, cy = h / 2 + 0.5
                for i in 0..<5 {
                    let a = -CGFloat.pi / 2 + 2 * CGFloat.pi * CGFloat(i) / 5
                    let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
            case .hexagon:
                let r = min(w, h) * 0.44
                let cx = w / 2, cy = h / 2
                for i in 0..<6 {
                    let a = 2 * CGFloat.pi * CGFloat(i) / 6
                    let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
            case .circle:
                let d = min(w, h) - 2 * pad
                path.addEllipse(in: CGRect(x: (w - d) / 2, y: (h - d) / 2, width: d, height: d))
                path.addEllipse(in: CGRect(x: w / 2 - 1, y: h / 2 - 1, width: 2, height: 2))
            case .parabola:
                path.move(to: CGPoint(x: pad + 1, y: pad + 1))
                path.addQuadCurve(to: CGPoint(x: w - pad - 1, y: pad + 1),
                                  control: CGPoint(x: w / 2, y: h * 1.35))
            case .axes:
                // X axis + arrow
                path.move(to: CGPoint(x: pad, y: h / 2))
                path.addLine(to: CGPoint(x: w - pad, y: h / 2))
                path.move(to: CGPoint(x: w - pad - 3, y: h / 2 - 2.5))
                path.addLine(to: CGPoint(x: w - pad, y: h / 2))
                path.addLine(to: CGPoint(x: w - pad - 3, y: h / 2 + 2.5))
                // Y axis + arrow
                path.move(to: CGPoint(x: w / 2, y: h - pad))
                path.addLine(to: CGPoint(x: w / 2, y: pad))
                path.move(to: CGPoint(x: w / 2 - 2.5, y: pad + 3))
                path.addLine(to: CGPoint(x: w / 2, y: pad))
                path.addLine(to: CGPoint(x: w / 2 + 2.5, y: pad + 3))
            }
            ctx.stroke(path, with: .foreground, style: stroke)
        }
    }
}
