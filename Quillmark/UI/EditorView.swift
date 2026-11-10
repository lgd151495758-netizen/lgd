import SwiftUI

struct EditorView: View {
    @StateObject private var session: DocumentSession

    init(meta: DocumentMeta, library: LibraryStore) {
        _session = StateObject(wrappedValue: DocumentSession(meta: meta, library: library))
    }

    var body: some View {
        EditorRepresentable(session: session)
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top) {
                ToolbarView(session: session)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
            .navigationTitle(session.meta.title)
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { session.saveNow() }
    }
}

private struct EditorRepresentable: UIViewControllerRepresentable {
    let session: DocumentSession

    func makeUIViewController(context: Context) -> EditorViewController {
        EditorViewController(session: session)
    }

    func updateUIViewController(_ uiViewController: EditorViewController, context: Context) {}
}

struct ToolbarView: View {
    @ObservedObject var session: DocumentSession

    var body: some View {
        HStack(spacing: 12) {
            ForEach(PenKind.allCases) { pen in
                penButton(pen)
            }
            divider
            ForEach(ToolSettings.palette, id: \.self) { color in
                colorButton(color)
            }
            divider
            ForEach(ToolSettings.widthPresets, id: \.self) { width in
                widthButton(width)
            }
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
        }
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Divider().frame(height: 26)
    }

    private func penButton(_ pen: PenKind) -> some View {
        let selected = session.tool.pen == pen
        return Button {
            session.tool.pen = pen
        } label: {
            VStack(spacing: 2) {
                Image(systemName: pen.symbolName)
                Text(pen.displayName).font(.caption2)
            }
            .frame(minWidth: 44)
            .padding(.vertical, 2)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
    }

    private func colorButton(_ color: RGBAColor) -> some View {
        let selected = session.tool.color == color
        return Button {
            session.tool.color = color
        } label: {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2).padding(-4))
        }
        .buttonStyle(.plain)
    }

    private func widthButton(_ width: Float) -> some View {
        let selected = session.tool.width == width
        return Button {
            session.tool.width = width
        } label: {
            Circle()
                .fill(Color.primary)
                .frame(width: CGFloat(width) * 3 + 2, height: CGFloat(width) * 3 + 2)
                .frame(width: 28, height: 28)
                .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
