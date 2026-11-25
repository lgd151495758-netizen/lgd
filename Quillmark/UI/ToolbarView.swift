import SwiftUI
import UIKit

/// Floating editor toolbar with pinned left tool buttons, pinned right undo/redo/input controls,
/// and a dedicated scrollable middle options strip so critical controls never scroll off-screen on 10.9" iPads.
struct ToolbarView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject private var presentation = PresentationCenter.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var showColorPalette = false
    @State private var showShapePicker = false
    @State private var editingQuickSlotIndex: Int?

    private var tool: ToolSettings { session.tool }
    private var isShapeMode: Bool { tool.kind == .shape }

    var body: some View {
        HStack(spacing: 8) {
            // Pinned left: primary tool switcher
            HStack(spacing: 4) {
                toolButton(title: "画笔", symbol: "pencil", selected: tool.kind == .pen) {
                    session.selectToolManually(.pen)
                }
                toolButton(title: "套索", symbol: "lasso", selected: tool.kind == .lasso) {
                    session.selectToolManually(.lasso)
                }
                toolButton(title: "胶带", symbol: "bandage", selected: tool.kind == .tape) {
                    session.selectToolManually(.tape)
                }
                toolButton(title: "图形", symbol: "square.on.circle", selected: tool.kind == .shape) {
                    session.selectToolManually(.shape)
                }
                toolButton(title: "激光笔", symbol: "laser.burst", selected: tool.kind == .laser) {
                    session.selectToolManually(.laser)
                }
                toolButton(title: "橡皮", symbol: "eraser", selected: tool.kind == .eraser) {
                    session.selectToolManually(.eraser)
                }
                divider
                geometryAidMenu
                toolButton(title: "便签", symbol: "note.text", selected: session.isScratchpadOpen) {
                    session.toggleScratchpad()
                }
            }

            divider

            // Scrollable middle: per-tool options only (never pushes tools or undo/redo off-screen)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    options
                }
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity)

            divider

            // Pinned right: undo/redo, finger drawing, and content-only projection toggle
            HStack(spacing: 6) {
                Button {
                    session.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(minWidth: 34, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .disabled(!session.canUndo)
                .accessibilityLabel("撤销")

                Button {
                    session.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .frame(minWidth: 34, minHeight: 36)
                        .contentShape(Rectangle())
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
                        Label("仅投内容", systemImage: "rectangle.on.rectangle")
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                    }
                    .toggleStyle(.button)
                    .accessibilityHint("打开：投屏画面只显示文档内容，工具栏只在 iPad 上显示")
                }
            }
        }
        .font(.title3)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: .infinity)
        .onChange(of: session.colorPaletteRequestID) { _, _ in
            if tool.kind == .pen || tool.kind == .shape {
                editingQuickSlotIndex = nil
                showColorPalette = true
            }
        }
    }

    @ViewBuilder
    private var options: some View {
        switch tool.kind {
        case .pen:
            quickColorStrip(
                activeColor: tool.color,
                setColor: { session.tool.color = $0 },
                isForShape: false
            )
            divider
            widthStrip(selectedWidth: tool.width) { session.tool.width = $0 }
            divider
            Picker("线型", selection: $session.tool.lineStyle) {
                ForEach(StrokeLineStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 126, maxWidth: 142)
            Toggle(isOn: $session.tool.drawAndHold) {
                Label("按住成形", systemImage: "square.on.circle")
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
            ForEach(Array(ToolSettings.tapePalette.enumerated()), id: \.offset) { idx, color in
                colorButton(color, selected: tool.tapeColor == color, label: "胶带颜色 \(idx + 1)") {
                    session.tool.tapeColor = color
                }
            }
            divider
            ForEach(Array(ToolSettings.tapeWidthPresets.enumerated()), id: \.offset) { idx, width in
                sizeButton(diameter: CGFloat(width) * 0.45 + 6,
                           selected: tool.tapeWidth == width,
                           shape: AnyShape(RoundedRectangle(cornerRadius: 3)),
                           label: "胶带宽度 \(idx + 1)") {
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
                Label("全部遮住", systemImage: "eye.slash")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            Button {
                session.setAllTapesRevealed(true)
            } label: {
                Label("全部揭开", systemImage: "eye")
                    .font(.callout)
            }
            .buttonStyle(.bordered)

        case .shape:
            // Compact shape picker button opening a crisp 4-column grid popover (prevents 14-button toolbar overflow).
            Button {
                showShapePicker = true
            } label: {
                HStack(spacing: 6) {
                    ShapePresetIcon(preset: tool.shapePreset)
                        .frame(width: 20, height: 16)
                    Text(tool.shapePreset.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.65)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择图形：当前为\(tool.shapePreset.displayName)")
            .popover(isPresented: $showShapePicker) {
                ShapePresetGridPopover(selected: $session.tool.shapePreset) {
                    showShapePicker = false
                }
            }

            divider

            quickColorStrip(
                activeColor: tool.resolvedShapeColor,
                setColor: { session.tool.resolvedShapeColor = $0 },
                isForShape: true
            )
            divider
            widthStrip(selectedWidth: tool.resolvedShapeWidth) { session.tool.resolvedShapeWidth = $0 }
            divider
            Picker("图形线型", selection: $session.tool.resolvedShapeLineStyle) {
                ForEach(StrokeLineStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 126, maxWidth: 142)
            if tool.shapePreset.supportsFill {
                Toggle(isOn: $session.tool.shapeFilled) {
                    Label("填充", systemImage: "square.fill.on.square")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                }
                .toggleStyle(.button)
                .accessibilityLabel("半透明填充")
            }

        case .laser:
            ForEach(Array(ToolSettings.laserPalette.enumerated()), id: \.offset) { idx, color in
                colorButton(color, selected: tool.laserColor == color, label: "激光笔颜色 \(idx + 1)") {
                    session.tool.laserColor = color
                }
            }

        case .eraser:
            Picker("橡皮模式", selection: $session.tool.eraserMode) {
                ForEach(EraserMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 168, maxWidth: 190)
            ForEach(Array(ToolSettings.eraserRadiusPresets.enumerated()), id: \.offset) { idx, radius in
                sizeButton(diameter: CGFloat(radius) + 6,
                           selected: tool.eraserRadius == radius,
                           filled: false,
                           label: "橡皮大小 \(idx + 1)") {
                    session.tool.eraserRadius = radius
                }
            }
        }
    }

    @ViewBuilder
    private func widthStrip(selectedWidth: Float, onSelect: @escaping (Float) -> Void) -> some View {
        let names = ["极细", "常规", "较粗", "醒目粗"]
        ForEach(Array(ToolSettings.widthPresets.enumerated()), id: \.offset) { idx, width in
            let name = idx < names.count ? names[idx] : "粗细 \(idx + 1)"
            sizeButton(diameter: CGFloat(width) * 2.8 + 2.5,
                       selected: abs(selectedWidth - width) < 0.05,
                       label: "线条粗细 \(name)") {
                onSelect(width)
            }
        }
    }

    /// Shows only the 4 most-used colors on the toolbar + a compact rainbow color-palette trigger.
    /// Tapping a quick dot strictly selects it (never surprises the teacher with an unexpected popover);
    /// long-pressing a dot or tapping the rainbow palette opens the color palette for customization.
    private func quickColorStrip(activeColor: RGBAColor,
                                 setColor: @escaping (RGBAColor) -> Void,
                                 isForShape: Bool) -> some View {
        let quickColors = tool.resolvedQuickColors
        let isCustomActive = !quickColors.contains(activeColor)
        return HStack(spacing: 6) {
            ForEach(Array(quickColors.enumerated()), id: \.offset) { idx, color in
                let isSelected = (activeColor == color)
                colorButton(color, selected: isSelected, label: "常用颜色 \(idx + 1)") {
                    setColor(color)
                }
                .contextMenu {
                    Button {
                        editingQuickSlotIndex = idx
                        showColorPalette = true
                    } label: {
                        Label("自定义此常用色…", systemImage: "paintpalette")
                    }
                    Button {
                        session.tool.resetQuickColorsToDefault()
                    } label: {
                        Label("恢复默认 4 种常用色", systemImage: "arrow.counterclockwise")
                    }
                }
            }

            Button {
                editingQuickSlotIndex = nil
                showColorPalette = true
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                                center: .center
                            ),
                            lineWidth: 2.6
                        )
                        .frame(width: 26, height: 26)
                    if isCustomActive {
                        Circle()
                            .fill(Color(cgColor: activeColor.cgColor))
                            .frame(width: 17, height: 17)
                            .overlay(
                                Circle()
                                    .stroke(swatchBorderColor(for: activeColor), lineWidth: 0.9)
                            )
                    } else {
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.8))
                    }
                }
                .overlay(
                    Circle()
                        .stroke(Color.accentColor.opacity(isCustomActive ? 0.95 : 0), lineWidth: 2.2)
                        .padding(-4)
                )
                .frame(minWidth: 34, minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开调色盘选择更多颜色")
            .popover(isPresented: $showColorPalette) {
                ColorPalettePopover(
                    session: session,
                    isForShape: isForShape,
                    editingSlotIndex: $editingQuickSlotIndex,
                    dismiss: { showColorPalette = false }
                )
            }
        }
    }

    private var geometryAidMenu: some View {
        let aid = session.geometryAid
        let isActive = (aid != .none)
        let title: String
        let symbol: String
        switch aid {
        case .none:
            title = "尺规"
            symbol = "compass.drawing"
        case .compass:
            title = "圆规"
            symbol = "compass.drawing"
        case .protractor:
            title = "量角器"
            symbol = "angle"
        }

        return Menu {
            Button {
                session.toggleGeometryAid(.compass)
            } label: {
                Label(aid == .compass ? "圆规（使用中）" : "圆规",
                      systemImage: aid == .compass ? "checkmark.circle.fill" : "compass.drawing")
            }
            Button {
                session.toggleGeometryAid(.protractor)
            } label: {
                Label(aid == .protractor ? "量角器（使用中）" : "量角器",
                      systemImage: aid == .protractor ? "checkmark.circle.fill" : "angle")
            }
            if isActive {
                Divider()
                Button(role: .destructive) {
                    session.geometryAid = .none
                } label: {
                    Label("关闭尺规", systemImage: "xmark.circle")
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                HStack(spacing: 1) {
                    Text(title).font(.caption2)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .opacity(0.65)
                }
            }
            .frame(minWidth: 42, minHeight: 36)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("几何尺规工具（圆规与量角器）")
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
            .frame(minWidth: 40, minHeight: 36)
            .padding(.vertical, 2)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func swatchBorderColor(for color: RGBAColor) -> Color {
        if color.isVeryLight {
            return Color.primary.opacity(0.38)
        }
        let luma = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b
        if colorScheme == .dark && luma < 0.25 {
            return Color.white.opacity(0.45)
        }
        return Color.primary.opacity(0.16)
    }

    private func colorButton(_ color: RGBAColor, selected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .frame(width: 24, height: 24)
                .overlay(
                    Circle()
                        .stroke(swatchBorderColor(for: color), lineWidth: 1.0)
                )
                .overlay(
                    Circle()
                        .stroke(Color.accentColor.opacity(selected ? 0.95 : 0), lineWidth: 2.2)
                        .padding(-4)
                )
                .frame(minWidth: 32, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sizeButton(diameter: CGFloat, selected: Bool, filled: Bool = true,
                            shape: AnyShape = AnyShape(Circle()), label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if filled {
                    shape.fill(Color.primary).frame(width: min(diameter, 20), height: min(diameter, 20))
                } else {
                    Circle().stroke(Color.primary, lineWidth: 1.5).frame(width: min(diameter, 22), height: min(diameter, 22))
                }
            }
            .frame(width: 32, height: 36)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Compact 4-column math shape grid popover replacing the 14-button horizontal strip so toolbar controls stay visible.
private struct ShapePresetGridPopover: View {
    @Binding var selected: ShapePreset
    let dismiss: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("选择标准数学图形", systemImage: "square.on.circle")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .font(.subheadline.weight(.semibold))
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(ShapePreset.allCases) { preset in
                    let isSelected = (selected == preset)
                    Button {
                        selected = preset
                        dismiss()
                    } label: {
                        VStack(spacing: 5) {
                            ShapePresetIcon(preset: preset)
                                .frame(width: 26, height: 20)
                            Text(preset.displayName)
                                .font(.caption2.weight(isSelected ? .semibold : .regular))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .padding(14)
        .frame(minWidth: 320, maxWidth: 360)
    }
}

/// Compact color palette popover with 16 curated classroom swatches, native full-gamut ColorPicker,
/// and one-tap assignment into the 4 toolbar quick-color slots.
private struct ColorPalettePopover: View {
    @ObservedObject var session: DocumentSession
    let isForShape: Bool
    @Binding var editingSlotIndex: Int?
    let dismiss: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    private var activeColor: RGBAColor {
        isForShape ? session.tool.resolvedShapeColor : session.tool.color
    }

    private func setActiveColor(_ newColor: RGBAColor) {
        if isForShape {
            session.tool.resolvedShapeColor = newColor
        } else {
            session.tool.color = newColor
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(cgColor: activeColor.cgColor) },
            set: { newColor in
                let rgba = RGBAColor(swiftUIColor: newColor)
                applyPickedColor(rgba)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(editingSlotIndex.map { "自定义常用色 \($0 + 1)" } ?? (isForShape ? "图形调色盘" : "画笔调色盘"),
                      systemImage: "paintpalette")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
            }

            // 16 curated teaching colors (light + dark courseware friendly)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ToolSettings.extendedPalette, id: \.self) { color in
                    let isSelected = (activeColor == color)
                    Button {
                        applyPickedColor(color)
                    } label: {
                        Circle()
                            .fill(Color(cgColor: color.cgColor))
                            .frame(width: 34, height: 34)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(color.isVeryLight ? 0.35 : 0.14), lineWidth: 1)
                            )
                            .overlay(
                                Circle()
                                    .stroke(Color.accentColor.opacity(isSelected ? 1 : 0), lineWidth: 2.5)
                                    .padding(-4)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // Native iPadOS full-spectrum ColorPicker (wheel / spectrum / sliders / eyedropper)
            ColorPicker("自由选色（色轮 / 吸管）", selection: colorBinding, supportsOpacity: false)
                .font(.subheadline.weight(.medium))

            Divider()

            // One-tap bar to pin the current color into any of the 4 toolbar quick slots
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(editingSlotIndex == nil ? "点下方槽位，将当前色固定到常用：" : "正在替换高亮槽位（点其他切换）：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("恢复默认") {
                        session.tool.resetQuickColorsToDefault()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    ForEach(Array(session.tool.resolvedQuickColors.enumerated()), id: \.offset) { idx, slotColor in
                        let isEditingTarget = (editingSlotIndex == idx)
                        Button {
                            if isEditingTarget {
                                editingSlotIndex = nil
                            } else if editingSlotIndex != nil {
                                editingSlotIndex = idx
                                setActiveColor(slotColor)
                            } else {
                                session.tool.setQuickColor(activeColor, at: idx, applyToPen: !isForShape)
                                if isForShape {
                                    session.tool.resolvedShapeColor = activeColor
                                }
                            }
                        } label: {
                            VStack(spacing: 3) {
                                Circle()
                                    .fill(Color(cgColor: slotColor.cgColor))
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary.opacity(slotColor.isVeryLight ? 0.35 : 0.16), lineWidth: 0.9)
                                    )
                                    .overlay(
                                        Circle()
                                            .stroke(Color.accentColor.opacity(isEditingTarget ? 1 : 0), lineWidth: 2.2)
                                            .padding(-3.5)
                                    )
                                Text("常用\(idx + 1)")
                                    .font(.caption2)
                                    .foregroundStyle(isEditingTarget ? Color.accentColor : Color.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .frame(minWidth: 280, maxWidth: 310)
    }

    private func applyPickedColor(_ color: RGBAColor) {
        if let idx = editingSlotIndex {
            session.tool.setQuickColor(color, at: idx, applyToPen: !isForShape)
            if isForShape {
                session.tool.resolvedShapeColor = color
            }
        } else {
            setActiveColor(color)
        }
    }
}

private extension RGBAColor {
    init(swiftUIColor: Color) {
        let uiColor = UIColor(swiftUIColor)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            self.init(
                Float(min(max(r, 0), 1)),
                Float(min(max(g, 0), 1)),
                Float(min(max(b, 0), 1)),
                1
            )
        } else if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let converted = uiColor.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
                  let comps = converted.components, comps.count >= 3 {
            self.init(
                Float(min(max(comps[0], 0), 1)),
                Float(min(max(comps[1], 0), 1)),
                Float(min(max(comps[2], 0), 1)),
                1
            )
        } else {
            self = .ink
        }
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
