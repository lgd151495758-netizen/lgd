import SwiftUI

struct EditorView: View {
    @StateObject private var session: DocumentSession
    @ObservedObject private var presentation = PresentationCenter.shared
    @State private var showPresentationPopover = false
    private let library: LibraryStore

    init(meta: DocumentMeta, library: LibraryStore) {
        self.library = library
        _session = StateObject(wrappedValue: DocumentSession(meta: meta, library: library))
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(session: session)
                .padding(.horizontal)
                .padding(.vertical, 6)
            editor
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(session.meta.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentation.scanDisplays()
                    showPresentationPopover = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "airplayvideo")
                        if presentation.isExternalDisplayConnected {
                            Text(presentation.contentOnly ? "投屏中" : "镜像中")
                                .font(.caption.weight(.medium))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(presentation.isExternalDisplayConnected ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: Capsule())
                }
                .accessibilityLabel("投屏设置")
                .popover(isPresented: $showPresentationPopover) {
                    PresentationPopover(presentation: presentation)
                }
            }
        }
        .onDisappear { session.saveNow() }
    }

    @ViewBuilder
    private var editor: some View {
        if session.meta.layout == .live {
            WebEditorRepresentable(session: session, library: library)
        } else {
            EditorRepresentable(session: session)
        }
    }
}

private struct PresentationPopover: View {
    @ObservedObject var presentation: PresentationCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("投屏模式")
                .font(.headline)

            Toggle("投屏仅显示内容", isOn: $presentation.contentOnly)

            Text("开启后，外接屏幕（如 OfflineMirror / AirPlay）只显示工具栏下方的网页与批注内容，工具栏仅在 iPad 上显示。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if presentation.contentOnly {
                Picker("缩放方式", selection: $presentation.fillMode) {
                    ForEach(PresentationFillMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()

            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(presentation.isExternalDisplayConnected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                Text(presentation.connectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                presentation.scanDisplays()
            } label: {
                Label("重新检测外接屏幕", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
        }
        .padding(18)
        .frame(width: 310)
    }
}

private struct WebEditorRepresentable: UIViewControllerRepresentable {
    let session: DocumentSession
    let library: LibraryStore

    func makeUIViewController(context: Context) -> WebEditorViewController {
        WebEditorViewController(session: session, library: library)
    }

    func updateUIViewController(_ uiViewController: WebEditorViewController, context: Context) {}
}

private struct EditorRepresentable: UIViewControllerRepresentable {
    let session: DocumentSession

    func makeUIViewController(context: Context) -> EditorViewController {
        EditorViewController(session: session)
    }

    func updateUIViewController(_ uiViewController: EditorViewController, context: Context) {}
}
