import PublishingWorkbenchCore
import SwiftUI

struct EditorCenterColumn: View {
  let store: WorkbenchStore
  let contentHealthFilter: ContentHealthContextFilter
  @Binding var repositoryContextStage: RepositoryContextStage
  @ObservedObject private var publishingState: WorkbenchPublishingFeatureFacade

  init(
    store: WorkbenchStore,
    contentHealthFilter: ContentHealthContextFilter,
    repositoryContextStage: Binding<RepositoryContextStage>
  ) {
    self.store = store
    self.contentHealthFilter = contentHealthFilter
    _repositoryContextStage = repositoryContextStage
    _publishingState = ObservedObject(wrappedValue: store.publishing)
  }

  var body: some View {
    Group {
      switch publishingState.selectedSection.centerSurface {
      case .aiChat:
        AIChatWorkspaceView(store: store)
      case .repository:
        RepositoryWorkspaceView(store: store, stage: $repositoryContextStage)
      case .images:
        ImageWorkbenchView(store: store)
      case .contentHealth:
        ContentHealthDetailView(store: store, filter: contentHealthFilter)
      case .releaseHistory:
        ReleaseHistoryDetailView(store: store)
      case .siteStarter:
        SiteStarterWorkspaceView(store: store)
      case .generalDrafts:
        GeneralDraftLibraryDetailView(store: store)
      case .maintenance:
        SiteMaintenanceDetailView(store: store)
      case .editor:
        if let fallbackDraft = publishingState.selectedDraft {
          let draft = Binding<ArticleDraft>(
            get: { publishingState.selectedDraft ?? fallbackDraft },
            set: { store.updateDraftFromEditor($0) }
          )

          MacMarkdownComposerView(draft: draft, store: store)
        } else {
          EmptyStateView(
            title: "还没有草稿",
            message: "新建一篇文章后，中间区域只负责正文编辑；预览通过编辑器顶部按钮打开。",
            systemImage: "doc.badge.plus"
          )
        }
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
    .onAppear {
      ensureDraftIfNeeded()
    }
    .onChange(of: publishingState.activeProfileID) { _, _ in
      ensureDraftIfNeeded()
    }
    .onChange(of: publishingState.selectedSection) { _, _ in
      ensureDraftIfNeeded()
    }
  }

  private func ensureDraftIfNeeded() {
    if publishingState.selectedSection.requiresEditableDraftForCenterSurface {
      store.ensureEditableDraftSelected()
    }
  }
}
