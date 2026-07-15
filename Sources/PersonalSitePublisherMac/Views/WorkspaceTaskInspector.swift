import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskInspector: View {
  let section: WorkspaceSection
  @Binding var draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore
  let prioritizesChecks: Bool
  @State private var selectedTab: ArticleInspectorTab = .metadata

  init(
    section: WorkspaceSection,
    draft: Binding<ArticleDraft>,
    store: WorkbenchStore,
    prioritizesChecks: Bool = false
  ) {
    self.section = section
    _draft = draft
    self.store = store
    self.prioritizesChecks = prioritizesChecks
  }

  var body: some View {
    switch section {
    case .writing, .sync, .contentHealth, .images, .releaseHistory:
      ArticleInspectorTabs(
        selectedTab: $selectedTab,
        draft: $draft,
        store: store
      )
      .onAppear {
        selectedTab = initialTab(for: section)
      }
      .onChange(of: section) { _, newSection in
        selectedTab = ArticleInspectorTab.defaultTab(for: newSection)
      }
    case .siteStarter:
      SiteStarterInspectorView(state: SiteStarterInspectorState(store: store))
    case .ai:
      AIChatContextInspectorView(store: store)
    case .generalDrafts:
      GeneralDraftLibraryInspectorView(store: store)
    case .maintenance:
      MaintenanceTaskInspector(store: store)
    }
  }

  private func initialTab(for section: WorkspaceSection) -> ArticleInspectorTab {
    prioritizesChecks ? .checks : ArticleInspectorTab.defaultTab(for: section)
  }
}
