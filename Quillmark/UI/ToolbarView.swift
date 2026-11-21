import SwiftUI

/// Floating editor toolbar: tool selector, options of the current tool, undo/redo, finger drawing.
struct ToolbarView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject private var presentation = PresentationCenter.shared

    private var tool: ToolSettings { session.tool }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(PenKind.allCases) { pen in
                    toolButton(title: pen.displayName, symbol: pen.symbolName,
                               selected: tool.kind == .pen && tool.pen == pen) {
                        session.tool.select(.pen)
                        session.tool.pen = pen
                    }
                }
                toolButton(title: "荧光笔", symbol: "highlighter", selected: tool.kind == .highlighter) {
                    session.tool.select(.highlighter)
                }
                toolButton(title: "胶带", symbol: "bandage", selected: tool.kind == .tape) {
                    session.tool.select(.tape)
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

        case .highlighter:
            ForEach(ToolSettings.highlighterPalette, id: \.self) { color in
                colorButton(color, selected: tool.highlighterColor == color) { session.tool.highlighterColor = color }
            }
            divider
            ForEach(ToolSettings.highlighterWidthPresets, id: \.self) { width in
                sizeButton(diameter: CGFloat(width) * 0.7 + 4, selected: tool.highlighterWidth == width,
                           shape: AnyShape(Capsule())) {
                    session.tool.highlighterWidth = width
                }
            }
            Toggle(isOn: $session.tool.highlighterStraight) {
                Label("直线", systemImage: "line.diagonal")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            }
            .toggleStyle(.button)

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
            Toggle(isOn: $session.tool.eraseHighlighterOnly) {
                Text("只擦荧光笔").font(.callout)
            }
            .toggleStyle(.button)
        }
    }

    private var divider: some View {
        Divider().frame(height: 26)
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
