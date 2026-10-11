import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

struct MetadataColumn: View {
  private let store: WorkbenchStore
  let selectedSection: WorkspaceSection
  let selectedDraftID: UUID?
  let imageBrowserSession: RepositoryImageBrowserSession
  let onOpenImageDraft: (UUID) -> Void
  @Binding private var selectedTab: WorkspaceInspectorTab
  let selectedHealthIssue: ContentHealthIssueSelection?
  let healthInspectorActions: ContentHealthInspectorActions
  let publishScope: PublishScope
  let publishRequestGeneration: Int
  let completedReleaseRecordID: UUID?
  let onNavigatePublishIssue: (UUID, PublishReadinessTarget, PublishScope) -> Void
  let onRequestAIFix: (UUID, PublishReadinessTarget) -> Void
  @Binding private var isPresented: Bool
  @ObservedObject private var publishStatus: WorkbenchPublishStatusFeatureFacade
  let rssStore: RSSReaderStore
  @Binding private var repositoryChangedFileSelection: RepositoryChangedFileSelection?
  @Binding private var aiChatSurfaceState: AIChatSurfaceState
  @Binding private var knowledgeInspectorPresentation: KnowledgeLibraryInspectorPresentationState
  private let aiChatOperationSession: AIChatSurfaceOperationSession
  let prioritizesChecks: Bool
  @State private var hasOpenedPublish = false
  @ObservedObject private var articlePresentation: ArticleInspectorPresentationState

  init(
    store: WorkbenchStore,
    selectedSection: WorkspaceSection,
    selectedDraftID: UUID?,
    imageBrowserSession: RepositoryImageBrowserSession,
    onOpenImageDraft: @escaping (UUID) -> Void,
    rssStore: RSSReaderStore,
    windowSession: WorkspaceWindowSession,
    selectedHealthIssue: ContentHealthIssueSelection?,
    healthInspectorActions: ContentHealthInspectorActions,
    publishScope: PublishScope,
    publishRequestGeneration: Int,
    completedReleaseRecordID: UUID?,
    isPresented: Binding<Bool>,
    onNavigatePublishIssue: @escaping (UUID, PublishReadinessTarget, PublishScope) -> Void,
    onRequestAIFix: @escaping (UUID, PublishReadinessTarget) -> Void,
    repositoryChangedFileSelection: Binding<RepositoryChangedFileSelection?>,
    aiChatSurfaceState: Binding<AIChatSurfaceState>,
    knowledgeInspectorPresentation: Binding<KnowledgeLibraryInspectorPresentationState>,
    aiChatOperationSession: AIChatSurfaceOperationSession,
    prioritizesChecks: Bool = false,
    articlePresentation: ArticleInspectorPresentationState
  ) {
    self.store = store
    self.selectedSection = selectedSection
    self.selectedDraftID = selectedDraftID
    self.imageBrowserSession = imageBrowserSession
    self.onOpenImageDraft = onOpenImageDraft
    let session = ObservedObject(wrappedValue: windowSession).projectedValue
    _selectedTab = session.inspectorTab
    self.selectedHealthIssue = selectedHealthIssue
    self.healthInspectorActions = healthInspectorActions
    self.publishScope = publishScope
    self.publishRequestGeneration = publishRequestGeneration
    self.completedReleaseRecordID = completedReleaseRecordID
    _isPresented = isPresented
    self.onNavigatePublishIssue = onNavigatePublishIssue
    self.onRequestAIFix = onRequestAIFix
    _publishStatus = ObservedObject(wrappedValue: store.publishStatus)
    self.rssStore = rssStore
    _repositoryChangedFileSelection = repositoryChangedFileSelection
    _aiChatSurfaceState = aiChatSurfaceState
    _knowledgeInspectorPresentation = knowledgeInspectorPresentation
    self.aiChatOperationSession = aiChatOperationSession
    _articlePresentation = ObservedObject(wrappedValue: articlePresentation)
    self.prioritizesChecks = prioritizesChecks
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("检查器", selection: $selectedTab) {
        ForEach(WorkspaceInspectorTab.allCases) { tab in
          if tab == .publish, pendingCount > 0 {
            Text("发布检查 · \(pendingCount)").tag(tab)
          } else {
            Text(tab.title).tag(tab)
          }
        }
      }
      .pickerStyle(.segmented)
      .padding(WorkbenchSpacing.control)
      .accessibilityLabel("检查器标签")
      .accessibilityValue(selectedTab.title)
      .accessibilityIdentifier("workspace-inspector-tabs")
      Divider()
      ZStack {
        switch selectedTab {
        case .information:
          informationContent
        case .assistant:
          AIChatContextInspectorView(
            store: store,
            selectedDraftID: selectedDraftID,
            usesWindowDraftSelection: true,
            surfaceState: $aiChatSurfaceState,
            operationSession: aiChatOperationSession
          )
        case .publish:
          Color.clear
        }
        if selectedTab == .publish || hasOpenedPublish {
          PublishDrawerView(
            publishingFacade: store.publishing,
            store: store,
            draftID: selectedDraftID,
            isPresented: $isPresented,
            initialScope: publishScope,
            requestGeneration: publishRequestGeneration,
            isActive: selectedTab == .publish,
            initialCompletedReleaseRecordID: completedReleaseRecordID,
            onNavigateIssue: onNavigatePublishIssue,
            onRequestAIFix: onRequestAIFix
          )
          .opacity(selectedTab == .publish ? 1 : 0)
          .disabled(selectedTab != .publish)
          .allowsHitTesting(selectedTab == .publish)
          .accessibilityHidden(selectedTab != .publish)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("workspace-publish-inspector")
          .onAppear { hasOpenedPublish = true }
        }
      }
      // Non-scrolling content such as empty states must claim the remaining
      // height; otherwise the whole stack, tabs included, is centered.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(WorkbenchSurface.inspector)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace-inspector")
    .accessibilityLabel("工作区检查器")
  }

  private var pendingCount: Int {
    ArticlePublishAttention.make(store: store, draftID: selectedDraftID)?.pendingCount ?? 0
  }

  @ViewBuilder
  private var informationContent: some View {
    if selectedSection == .contentHealth {
      ContentHealthSelectedIssueInspector(
        selectedIssue: selectedHealthIssue, actions: healthInspectorActions
      )
    } else {
      switch WorkspaceInspectorPresentation.route(for: selectedSection) {
      case .repository:
        RepositoryContextInspectorView(
          store: store, changedFileSelection: $repositoryChangedFileSelection
        )
      case .knowledgeLibrary:
        KnowledgeInspectorContentView(
          store: store, knowledge: store.knowledge,
          presentation: $knowledgeInspectorPresentation
        )
      case .rssLibrary:
        ScrollView {
          RSSLibraryInspectorPanel(rssStore: rssStore, workbenchStore: store)
            .padding(WorkbenchSpacing.content)
        }
      case .articleImages:
        RepositoryImageInspectorHost(
          store: store, session: imageBrowserSession, onOpenDraft: onOpenImageDraft
        )
      case .articleMetadata, .articleChecks:
        articleInspector
      case .aiAssistant, .unavailable:
        EmptyStateView(
          title: "当前页面没有详情栏", message: "此页面的操作已集中在主内容区。",
          systemImage: "sidebar.right", density: .compactPane
        )
      }
    }
  }

}

private struct KnowledgeInspectorContentView: View {
  let store: WorkbenchStore
  @ObservedObject var knowledge: KnowledgeStore
  @Binding var presentation: KnowledgeLibraryInspectorPresentationState

  @ViewBuilder
  var body: some View {
    if let document = knowledge.selectedDocument {
      KnowledgeLibraryInspectorPanel(
        store: store,
        knowledge: knowledge,
        document: document,
        activeSearchResult: activeKnowledgeSearchResult,
        onEditMetadata: { presentation.editMetadata(for: document) },
        onAddAnnotation: { presentation.addAnnotation(to: document) },
        onAnnotateSearchHit: {
          presentation.annotateSearchResult(
            activeKnowledgeSearchResult,
            in: document
          )
        },
        onEditAnnotation: { presentation.editAnnotation($0) },
        onDeleteAnnotation: { annotationID in
          Task { await knowledge.deleteAnnotation(annotationID) }
        },
        onOpenSourceHistory: {
          presentation.openSourceHistory(for: document.id)
        },
        onReportContentIssue: {
          presentation.openSourceHistory(
            for: document.id,
            preparesLocalRepairOnAppear: true
          )
        }
      )
      .background(.bar)
    } else {
      EmptyStateView(
        title: "没有选中的资料",
        message: "从左侧资料列表选择一项后，这里会显示批注、相关内容和版本操作。",
        systemImage: "sidebar.right",
        density: .compactPane
      )
      .background(.bar)
    }
  }

  private var activeKnowledgeSearchResult: KnowledgeSearchResult? {
    guard let result = knowledge.selectedSearchResult,
      result.document.id == knowledge.selectedDocumentID
    else { return nil }
    return result
  }

}

extension MetadataColumn {
  @ViewBuilder
  fileprivate var articleInspector: some View {
    if let selectedDraftID, let fallbackDraft = store.draft(for: selectedDraftID) {
      let draft = Binding<ArticleDraft>(
        get: { store.draft(for: selectedDraftID) ?? fallbackDraft },
        set: { store.updateDraftFromEditor($0) }
      )
      WorkspaceTaskInspector(
        section: selectedSection,
        draft: draft,
        store: store,
        rssStore: rssStore,
        presentation: articlePresentation,
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
