import SwiftUI

struct EditorView: View {
    @StateObject private var session: DocumentSession
    private let library: LibraryStore

    init(meta: DocumentMeta, library: LibraryStore) {
        self.library = library
        _session = StateObject(wrappedValue: DocumentSession(meta: meta, library: library))
    }

    var body: some View {
        editor
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

    @ViewBuilder
    private var editor: some View {
        if session.meta.layout == .live {
            WebEditorRepresentable(session: session, library: library)
        } else {
            EditorRepresentable(session: session)
        }
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

