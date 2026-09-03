import PublishingWorkbenchCore
import SwiftUI

struct EditorCenterColumn: View {
  let store: WorkbenchStore
  let selectedSection: WorkspaceSection
  let selectedDraftID: UUID?
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var imageWorkbenchContextStage: ImageWorkbenchContextStage
  @Binding var repositoryContextStage: RepositoryContextStage
  @Binding var repositoryChangedFileSelection: RepositoryChangedFileSelection?
  let contentHealthSidebarProjection: ContentHealthSidebarProjection
  let repositorySourceSession: RepositoryHTMLSourceSession
  let rssStore: RSSReaderStore
  let rssPresentation: RSSReaderPresentationState
  @Binding var knowledgeInspectorPresentation: KnowledgeLibraryInspectorPresentationState
  @ObservedObject private var knowledge: KnowledgeStore

  init(
    store: WorkbenchStore,
    selectedSection: WorkspaceSection,
    selectedDraftID: UUID?,
    contentHealthFilter: Binding<ContentHealthContextFilter>,
    imageWorkbenchContextStage: Binding<ImageWorkbenchContextStage>,
    repositoryContextStage: Binding<RepositoryContextStage>,
    repositoryChangedFileSelection: Binding<RepositoryChangedFileSelection?>,
    contentHealthSidebarProjection: ContentHealthSidebarProjection,
    repositorySourceSession: RepositoryHTMLSourceSession,
    rssStore: RSSReaderStore,
    rssPresentation: RSSReaderPresentationState,
    knowledgeInspectorPresentation: Binding<KnowledgeLibraryInspectorPresentationState>
  ) {
    self.store = store
    self.selectedSection = selectedSection
    self.selectedDraftID = selectedDraftID
    _contentHealthFilter = contentHealthFilter
    _imageWorkbenchContextStage = imageWorkbenchContextStage
    _repositoryContextStage = repositoryContextStage
    _repositoryChangedFileSelection = repositoryChangedFileSelection
    self.contentHealthSidebarProjection = contentHealthSidebarProjection
    self.repositorySourceSession = repositorySourceSession
    self.rssStore = rssStore
    self.rssPresentation = rssPresentation
    _knowledgeInspectorPresentation = knowledgeInspectorPresentation
    _knowledge = ObservedObject(wrappedValue: store.knowledge)
  }

  var body: some View {
    centerSurfaceView(activeSurface)
      .id(activeSurface)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: knowledge.statusMessage) { _, message in
        guard activeSurface == .knowledgeLibrary, let message else { return }
        EditorAccessibilityAnnouncementCenter.announce(message)
      }
  }

  private var activeSurface: WorkspaceCenterSurface {
    selectedSection.centerSurface
  }

  @ViewBuilder
  private func centerSurfaceView(_ surface: WorkspaceCenterSurface) -> some View {
    switch surface {
    case .knowledgeLibrary:
      KnowledgeLibraryDetailView(
        knowledge: store.knowledge,
        inspectorPresentation: $knowledgeInspectorPresentation
      )
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
        changedFileSelection: $repositoryChangedFileSelection,
        sourceSession: repositorySourceSession
      )
    case .images:
      ImageWorkbenchView(store: store, stage: $imageWorkbenchContextStage)
    case .contentHealth:
      ContentHealthDetailView(
        store: store,
        currentDraftID: selectedDraftID,
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
    if let selectedDraftID, let fallbackDraft = store.draft(for: selectedDraftID) {
      let draft = Binding<ArticleDraft>(
        get: { store.draft(for: selectedDraftID) ?? fallbackDraft },
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
