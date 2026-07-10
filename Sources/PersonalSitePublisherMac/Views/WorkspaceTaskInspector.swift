import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskInspector: View {
  let section: WorkspaceSection
  @Binding var draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore
  @State private var selectedTab: ArticleInspectorTab = .metadata

  var body: some View {
    switch section {
    case .writing, .sync, .contentHealth, .images, .releaseHistory:
      ArticleInspectorTabs(
        selectedTab: $selectedTab,
        draft: $draft,
        store: store
      )
      .onAppear {
        selectedTab = ArticleInspectorTab.defaultTab(for: section)
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
    case .releaseReadiness:
      ReleaseQualityGateInspectorView(store: store)
    }
  }
}
