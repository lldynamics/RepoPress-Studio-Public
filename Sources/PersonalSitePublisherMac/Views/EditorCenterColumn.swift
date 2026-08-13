import PublishingWorkbenchCore
import SwiftUI

private struct EditableDraftSelectionTaskInput: Equatable {
  let activeProfileID: UUID
  let selectedSection: WorkspaceSection
}

struct EditorCenterColumn: View {
  let store: WorkbenchStore
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var imageWorkbenchContextStage: ImageWorkbenchContextStage
  @Binding var repositoryContextStage: RepositoryContextStage
  let contentHealthSidebarProjection: ContentHealthSidebarProjection
  let repositorySourceSession: RepositoryHTMLSourceSession
  let rssStore: RSSReaderStore
  let rssPresentation: RSSReaderPresentationState
  @StateObject private var editorState: WorkbenchEditorNavigationFeatureFacade
  @ObservedObject private var knowledge: KnowledgeStore

  init(
    store: WorkbenchStore,
    contentHealthFilter: Binding<ContentHealthContextFilter>,
    imageWorkbenchContextStage: Binding<ImageWorkbenchContextStage>,
    repositoryContextStage: Binding<RepositoryContextStage>,
    contentHealthSidebarProjection: ContentHealthSidebarProjection,
    repositorySourceSession: RepositoryHTMLSourceSession,
    rssStore: RSSReaderStore,
    rssPresentation: RSSReaderPresentationState
  ) {
    self.store = store
    _contentHealthFilter = contentHealthFilter
    _imageWorkbenchContextStage = imageWorkbenchContextStage
    _repositoryContextStage = repositoryContextStage
    self.contentHealthSidebarProjection = contentHealthSidebarProjection
    self.repositorySourceSession = repositorySourceSession
    self.rssStore = rssStore
    self.rssPresentation = rssPresentation
    _editorState = StateObject(
      wrappedValue: WorkbenchEditorNavigationFeatureFacade(store: store)
    )
    _knowledge = ObservedObject(wrappedValue: store.knowledge)
  }

  var body: some View {
    centerSurfaceView(activeSurface)
      .id(activeSurface)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .task(
        id: EditableDraftSelectionTaskInput(
          activeProfileID: editorState.activeProfileID,
          selectedSection: editorState.selectedSection
        )
      ) {
        // Selecting a fallback draft publishes preflight and selection state.
        // Let the current SwiftUI update finish before starting that work.
        await MainRunLoopUpdateDeferral.waitForNextDefaultModeCycle()
        guard !Task.isCancelled else { return }
        ensureDraftIfNeeded()
      }
      .onChange(of: knowledge.statusMessage) { _, message in
        guard activeSurface == .knowledgeLibrary, let message else { return }
        EditorAccessibilityAnnouncementCenter.announce(message)
      }
  }

  private func ensureDraftIfNeeded() {
    if editorState.selectedSection.requiresEditableDraftForCenterSurface {
      store.ensureEditableDraftSelected()
    }
  }

  private var activeSurface: WorkspaceCenterSurface {
    editorState.selectedSection.centerSurface
  }

  @ViewBuilder
  private func centerSurfaceView(_ surface: WorkspaceCenterSurface) -> some View {
    switch surface {
    case .knowledgeLibrary:
      KnowledgeLibraryDetailView(knowledge: store.knowledge)
    case .rssReader:
      RSSReaderView(
        store: rssStore,
        workbenchStore: store,
        presentation: rssPresentation
      )
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

  @ViewBuilder
  private var writingEditorDetail: some View {
    if let fallbackDraft = editorState.selectedDraft {
      let draft = Binding<ArticleDraft>(
        get: { editorState.selectedDraft ?? fallbackDraft },
        set: { store.updateDraftFromEditor($0) }
      )

      MacMarkdownComposerView(
        draft: draft,
        store: store
      )
    } else {
      GuidedEmptyStateView(
        title: "创作你的首篇文章",
        message: "随时新建草稿或从线上同步已有文章，在中央纯粹专注正文编辑。",
        systemImage: "square.and.pencil",
        actions: [
          GuidedEmptyStateAction(
            id: "create-markdown-draft",
            title: "新建 Markdown 草稿",
            subtitle: "创建本地空白文章，开始文字与图文排版",
            systemImage: "doc.badge.plus",
            action: {
              store.createDraft()
            }
          ),
          GuidedEmptyStateAction(
            id: "sync-remote-drafts",
            title: "从 GitHub/GitLab 同步文章",
            subtitle: "连接线上 Git 仓库，同步并导入远端草稿",
            systemImage: "arrow.triangle.2.circlepath",
            action: {
              store.selectSection(.sync)
            }
          ),
          GuidedEmptyStateAction(
            id: "configure-site-repository",
            title: "绑定站点仓库",
            subtitle: "配置 Hexo / Hugo / Astro 静态建站框架目录",
            systemImage: "folder.badge.gearshape",
            action: {
              store.selectSection(.siteStarter)
            }
          ),
        ]
      )
    }
  }

}
