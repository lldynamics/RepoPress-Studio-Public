import PublishingWorkbenchCore
import SwiftUI

struct MetadataColumn: View {
  private let store: WorkbenchStore
  @ObservedObject private var navigation: WorkbenchEditorNavigationFeatureFacade
  @ObservedObject private var contentPresentation: WorkbenchContentPresentationFeatureFacade
  let rssStore: RSSReaderStore
  let repositoryContextStage: RepositoryContextStage
  @ObservedObject var repositorySourceSession: RepositoryHTMLSourceSession
  @Binding private var aiChatSurfaceState: AIChatSurfaceState
  private let aiChatOperationSession: AIChatSurfaceOperationSession
  let prioritizesChecks: Bool

  init(
    store: WorkbenchStore,
    rssStore: RSSReaderStore,
    repositoryContextStage: RepositoryContextStage,
    repositorySourceSession: RepositoryHTMLSourceSession,
    aiChatSurfaceState: Binding<AIChatSurfaceState>,
    aiChatOperationSession: AIChatSurfaceOperationSession,
    prioritizesChecks: Bool = false
  ) {
    self.store = store
    _navigation = ObservedObject(
      wrappedValue: WorkbenchEditorNavigationFeatureFacade(store: store)
    )
    _contentPresentation = ObservedObject(wrappedValue: store.contentPresentation)
    self.rssStore = rssStore
    self.repositoryContextStage = repositoryContextStage
    _repositorySourceSession = ObservedObject(wrappedValue: repositorySourceSession)
    _aiChatSurfaceState = aiChatSurfaceState
    self.aiChatOperationSession = aiChatOperationSession
    self.prioritizesChecks = prioritizesChecks
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      switch WorkspaceInspectorPresentation.route(
        for: navigation.selectedSection,
        isAIAssistantPresented: contentPresentation.isAssistantPresented
      ) {
      case .aiAssistant:
        AIChatContextInspectorView(
          store: store,
          surfaceState: $aiChatSurfaceState,
          operationSession: aiChatOperationSession
        )
      case .siteStarter:
        SiteStarterInspectorView(state: SiteStarterInspectorState(store: store))
      case .repository:
        if repositoryContextStage == .source,
          repositorySourceSession.activeDocument != nil
        {
          RepositoryHTMLSourceInspectorView(
            store: store,
            session: repositorySourceSession
          )
        } else {
          RepositoryContextInspectorView(store: store)
        }
      case .articleMetadata, .articleChecks, .articleImages:
        articleInspector
      case .unavailable:
        EmptyStateView(
          title: "当前页面没有 Inspector",
          message: "此页面的操作已集中在主内容区。",
          systemImage: "sidebar.right",
          density: .compactPane
        )
        .background(.bar)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace-inspector")
    .accessibilityLabel("工作区 Inspector")
    .overlay(alignment: .leading) {
      if contentPresentation.isAssistantPresented {
        Image(systemName: "arrow.left.and.right")
          .font(.workbenchMetadata.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 5)
          .padding(.vertical, 4)
          .background(.regularMaterial, in: Capsule())
          .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 1))
          .offset(x: -11)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
  }

  @ViewBuilder
  private var articleInspector: some View {
    if let fallbackDraft = navigation.selectedDraft {
      let draft = Binding<ArticleDraft>(
        get: { navigation.selectedDraft ?? fallbackDraft },
        set: { store.updateDraftFromEditor($0) }
      )
      WorkspaceTaskInspector(
        section: navigation.selectedSection,
        draft: draft,
        store: store,
        rssStore: rssStore,
        prioritizesChecks: prioritizesChecks
      )
    } else {
      EmptyStateView(
        title: "没有元数据",
        message: "选择或新建文章后，这里会显示文章头信息（Front Matter）、SEO、图片、检查和发布任务。",
        systemImage: "sidebar.right",
        density: .compactPane,
        actionTitle: "新建文章",
        actionSystemImage: "square.and.pencil",
        action: {
          store.createDraft()
          store.selectSection(.writing)
        }
      )
      .background(.bar)
    }
  }
}
