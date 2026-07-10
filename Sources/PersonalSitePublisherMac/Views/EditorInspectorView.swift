import PublishingWorkbenchCore
import SwiftUI

struct EditorInspectorView: View {
  @Binding var draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        EditorFrontMatterSection(draft: $draft, store: store)
        EditorSEOSection(draft: draft, store: store)
        EditorSocialPreviewSection(draft: draft, store: store)
        EditorPathSection(draft: draft, store: store)
        EditorImageSection(draft: $draft, store: store)
        EditorPreflightSection(draft: $draft, store: store)
      }
      .padding(16)
    }
    .background(.bar)
    .onAppear {
      prepareSEOSocialPreviewIfNeeded()
    }
    .onChange(of: draft.id) { _, _ in
      prepareSEOSocialPreviewIfNeeded()
    }
  }

  private func prepareSEOSocialPreviewIfNeeded() {
    store.prepareSEOSocialPreview(for: draft)
  }
}
