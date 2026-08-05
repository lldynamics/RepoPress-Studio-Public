import PublishingWorkbenchCore
import SwiftUI

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
  /// 最近访问的中央区 surface（LRU：首元素最近）。写作编辑器总是保留；
  /// 其他页面按 LRU 保留上限，切换时避免整页销毁重建，同时控制常驻
  /// WKWebView / NSTextView 数量以缓解 idle 时的资源占用。
  @State private var retainedSurfaces: [WorkspaceCenterSurface] = []
  private let maximumRetainedNonEditorSurfaces = 2
  private let editorSurface = WorkspaceCenterSurface.editor

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
    ZStack {
      ForEach(displaySurfaces, id: \.self) { surface in
        centerSurfaceView(surface)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .conditionalHidden(surface != activeSurface)
      }
    }
    .onAppear {
      retainSurface(activeSurface)
      ensureDraftIfNeeded()
    }
    .onChange(of: editorState.activeProfileID) { _, _ in
      ensureDraftIfNeeded()
    }
    .onChange(of: editorState.selectedSection) { _, _ in
      retainSurface(activeSurface)
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

  /// 始终包含当前激活 surface 的渲染列表；首次 body 求值时即使 retain
  /// 尚未执行，也能立即显示当前页面，避免闪一帧空白。
  private var displaySurfaces: [WorkspaceCenterSurface] {
    if retainedSurfaces.contains(activeSurface) {
      return retainedSurfaces
    }
    return [activeSurface] + retainedSurfaces.filter { $0 != activeSurface }
  }

  private func retainSurface(_ surface: WorkspaceCenterSurface) {
    retainedSurfaces.removeAll { $0 == surface }
    retainedSurfaces.insert(surface, at: 0)
    // 写作编辑器总是保留（核心编辑面，重建代价最高）；其他页面按 LRU
    // 仅保留最近访问的若干个，避免多个含 WKWebView 的页面同时常驻。
    var nonEditorCount = 0
    retainedSurfaces.removeAll { candidate in
      guard candidate != editorSurface else { return false }
      nonEditorCount += 1
      return nonEditorCount > maximumRetainedNonEditorSurfaces
    }
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

      MacMarkdownComposerView(draft: draft, store: store)
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
          )
        ]
      )
    }
  }

}

private struct ConditionalHiddenModifier: ViewModifier {
  let isHidden: Bool

  func body(content: Content) -> some View {
    if isHidden {
      content.hidden()
    } else {
      content
    }
  }
}

extension View {
  /// 条件隐藏但保留 View 实例与内部状态；隐藏不会触发 onAppear/onDisappear。
  func conditionalHidden(_ isHidden: Bool) -> some View {
    modifier(ConditionalHiddenModifier(isHidden: isHidden))
  }
}
