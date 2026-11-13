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

