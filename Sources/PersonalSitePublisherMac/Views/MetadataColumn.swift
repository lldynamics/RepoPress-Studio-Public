import PublishingWorkbenchCore
import SwiftUI

struct MetadataColumn: View {
  private let store: WorkbenchStore
  @ObservedObject private var navigation: WorkbenchEditorNavigationFeatureFacade
  @ObservedObject private var ai: WorkbenchAIFeatureFacade
  let rssStore: RSSReaderStore
  let repositoryContextStage: RepositoryContextStage
  @ObservedObject var repositorySourceSession: RepositoryHTMLSourceSession
  let prioritizesChecks: Bool

  init(
    store: WorkbenchStore,
    rssStore: RSSReaderStore,
    repositoryContextStage: RepositoryContextStage,
    repositorySourceSession: RepositoryHTMLSourceSession,
    prioritizesChecks: Bool = false
  ) {
    self.store = store
    _navigation = ObservedObject(
      wrappedValue: WorkbenchEditorNavigationFeatureFacade(store: store)
    )
    _ai = ObservedObject(wrappedValue: store.ai)
    self.rssStore = rssStore
    self.repositoryContextStage = repositoryContextStage
    _repositorySourceSession = ObservedObject(wrappedValue: repositorySourceSession)
    self.prioritizesChecks = prioritizesChecks
  }

  var body: some View {
    Group {
      switch WorkspaceInspectorPresentation.route(
        for: navigation.selectedSection,
        isAIAssistantPresented: DistributionFeaturePolicy.allowsExternalAIProviders
          && ai.isAssistantPresented
      ) {
      case .aiAssistant:
        if DistributionFeaturePolicy.allowsExternalAIProviders {
          AIChatContextInspectorView(store: store)
        } else {
          articleInspector
        }
      case .siteStarter:
        SiteStarterInspectorView(state: SiteStarterInspectorState(store: store))
      case .repository:
        if repositoryContextStage == .source,
           repositorySourceSession.activeDocument != nil {
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
    .accessibilityIdentifier("workspace-inspector")
    .accessibilityLabel("工作区 Inspector")
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
