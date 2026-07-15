import PublishingWorkbenchCore
import SwiftUI

struct MetadataColumn: View {
  @ObservedObject var store: WorkbenchStore
  let prioritizesChecks: Bool

  init(store: WorkbenchStore, prioritizesChecks: Bool = false) {
    self.store = store
    self.prioritizesChecks = prioritizesChecks
  }

  var body: some View {
    if store.selectedSection == .ai {
      AIChatContextInspectorView(store: store)
    } else if store.selectedSection == .siteStarter {
      SiteStarterInspectorView(state: SiteStarterInspectorState(store: store))
    } else if store.selectedSection == .generalDrafts {
      GeneralDraftLibraryInspectorView(store: store)
    } else if let fallbackDraft = store.selectedDraft {
      let draft = Binding<ArticleDraft>(
        get: { store.selectedDraft ?? fallbackDraft },
        set: { store.updateDraftFromEditor($0) }
      )
      WorkspaceTaskInspector(
        section: store.selectedSection,
        draft: draft,
        store: store,
        prioritizesChecks: prioritizesChecks
      )
    } else {
      EmptyStateView(
        title: "没有元数据",
        message: "选择或新建文章后，这里会显示 Front Matter、SEO、图片、检查和发布任务。",
        systemImage: "sidebar.right"
      )
      .background(.bar)
    }
  }
}
