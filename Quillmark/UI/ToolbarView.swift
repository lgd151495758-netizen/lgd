import SwiftUI

/// Floating editor toolbar: tool selector, options of the current tool, undo/redo, finger drawing.
struct ToolbarView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject private var presentation = PresentationCenter.shared

    private var tool: ToolSettings { session.tool }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
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
                toolButton(title: "橡皮", symbol: "eraser", selected: tool.kind == .eraser) {
                    session.tool.select(.eraser)
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
            .padding(.horizontal, 16)
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
            .frame(minWidth: 44)
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
                .overlay(Circle().stroke(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2).padding(-4))
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
