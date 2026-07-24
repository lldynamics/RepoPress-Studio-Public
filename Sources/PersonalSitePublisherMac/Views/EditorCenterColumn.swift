import PublishingWorkbenchCore
import SwiftUI

struct EditorCenterColumn: View {
  let store: WorkbenchStore
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var imageWorkbenchContextStage: ImageWorkbenchContextStage
  @Binding var repositoryContextStage: RepositoryContextStage
  let contentHealthSidebarProjection: ContentHealthSidebarProjection
  let repositorySourceSession: RepositoryHTMLSourceSession
  @StateObject private var editorState: WorkbenchEditorNavigationFeatureFacade
  @ObservedObject private var knowledge: KnowledgeStore

  init(
    store: WorkbenchStore,
    contentHealthFilter: Binding<ContentHealthContextFilter>,
    imageWorkbenchContextStage: Binding<ImageWorkbenchContextStage>,
    repositoryContextStage: Binding<RepositoryContextStage>,
    contentHealthSidebarProjection: ContentHealthSidebarProjection,
    repositorySourceSession: RepositoryHTMLSourceSession
  ) {
    self.store = store
    _contentHealthFilter = contentHealthFilter
    _imageWorkbenchContextStage = imageWorkbenchContextStage
    _repositoryContextStage = repositoryContextStage
    self.contentHealthSidebarProjection = contentHealthSidebarProjection
    self.repositorySourceSession = repositorySourceSession
    _editorState = StateObject(
      wrappedValue: WorkbenchEditorNavigationFeatureFacade(store: store)
    )
    _knowledge = ObservedObject(wrappedValue: store.knowledge)
  }

  var body: some View {
    Group {
      switch editorState.selectedSection.centerSurface {
      case .knowledgeLibrary:
        KnowledgeLibraryDetailView(knowledge: store.knowledge)
      case .repository:
        RepositoryWorkspaceView(
          store: store,
          stage: $repositoryContextStage,
          sourceSession: repositorySourceSession
        )
      case .images:
        ImageWorkbenchView(store: store, stage: $imageWorkbenchContextStage)
      case .contentHealth:
        ContentHealthDetailView(
          store: store,
          filter: $contentHealthFilter,
          sidebarProjection: contentHealthSidebarProjection
        )
      case .siteStarter:
        SiteStarterWorkspaceView(store: store)
      case .editor:
        writingEditorDetail
      }
    }
    .onAppear {
      ensureDraftIfNeeded()
    }
    .onChange(of: editorState.activeProfileID) { _, _ in
      ensureDraftIfNeeded()
    }
    .onChange(of: editorState.selectedSection) { _, _ in
      ensureDraftIfNeeded()
    }
    .onChange(of: knowledge.statusMessage) { _, message in
      guard editorState.selectedSection.centerSurface == .knowledgeLibrary,
            let message else { return }
      EditorAccessibilityAnnouncementCenter.announce(message)
    }
  }

  private func ensureDraftIfNeeded() {
    if editorState.selectedSection.requiresEditableDraftForCenterSurface {
      store.ensureEditableDraftSelected()
    }
  }

  @ViewBuilder
  private var writingEditorDetail: some View {
    if let fallbackDraft = editorState.selectedDraft {
      let draft = Binding<ArticleDraft>(
        get: { editorState.selectedDraft ?? fallbackDraft },
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
