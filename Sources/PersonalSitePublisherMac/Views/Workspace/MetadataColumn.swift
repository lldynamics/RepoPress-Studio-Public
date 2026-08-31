import PublishingWorkbenchCore
import SwiftUI

struct MetadataColumn: View {
  private let store: WorkbenchStore
  let selectedSection: WorkspaceSection
  let selectedDraftID: UUID?
  @ObservedObject private var contentPresentation: WorkbenchContentPresentationFeatureFacade
  let rssStore: RSSReaderStore
  let repositoryContextStage: RepositoryContextStage
  @Binding private var repositoryChangedFileSelection: RepositoryChangedFileSelection?
  @ObservedObject var repositorySourceSession: RepositoryHTMLSourceSession
  @Binding private var aiChatSurfaceState: AIChatSurfaceState
  @Binding private var knowledgeInspectorPresentation: KnowledgeLibraryInspectorPresentationState
  private let aiChatOperationSession: AIChatSurfaceOperationSession
  let prioritizesChecks: Bool
  let onResetWidth: (() -> Void)?

  init(
    store: WorkbenchStore,
    selectedSection: WorkspaceSection,
    selectedDraftID: UUID?,
    rssStore: RSSReaderStore,
    repositoryContextStage: RepositoryContextStage,
    repositoryChangedFileSelection: Binding<RepositoryChangedFileSelection?>,
    repositorySourceSession: RepositoryHTMLSourceSession,
    aiChatSurfaceState: Binding<AIChatSurfaceState>,
    knowledgeInspectorPresentation: Binding<KnowledgeLibraryInspectorPresentationState>,
    aiChatOperationSession: AIChatSurfaceOperationSession,
    prioritizesChecks: Bool = false,
    onResetWidth: (() -> Void)? = nil
  ) {
    self.store = store
    self.selectedSection = selectedSection
    self.selectedDraftID = selectedDraftID
    _contentPresentation = ObservedObject(wrappedValue: store.contentPresentation)
    self.rssStore = rssStore
    self.repositoryContextStage = repositoryContextStage
    _repositoryChangedFileSelection = repositoryChangedFileSelection
    _repositorySourceSession = ObservedObject(wrappedValue: repositorySourceSession)
    _aiChatSurfaceState = aiChatSurfaceState
    _knowledgeInspectorPresentation = knowledgeInspectorPresentation
    self.aiChatOperationSession = aiChatOperationSession
    self.prioritizesChecks = prioritizesChecks
    self.onResetWidth = onResetWidth
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      switch WorkspaceInspectorPresentation.route(
        for: selectedSection,
        isAIAssistantPresented: contentPresentation.isAssistantPresented
      ) {
      case .aiAssistant:
        AIChatContextInspectorView(
          store: store,
          selectedDraftID: selectedDraftID,
          usesWindowDraftSelection: true,
          surfaceState: $aiChatSurfaceState,
          operationSession: aiChatOperationSession
        )
      case .siteStarter:
        SiteStarterInspectorView(store: store)
      case .repository:
        if repositoryContextStage == .source,
          repositorySourceSession.activeDocument != nil
        {
          RepositoryHTMLSourceInspectorView(
            store: store,
            session: repositorySourceSession
          )
        } else {
          RepositoryContextInspectorView(
            store: store,
            changedFileSelection: $repositoryChangedFileSelection
          )
        }
      case .knowledgeLibrary:
        knowledgeInspector
      case .rssLibrary:
        ScrollView {
          RSSLibraryInspectorPanel(
            rssStore: rssStore,
            workbenchStore: store
          )
          .padding(14)
        }
        .background(.bar)
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
    .overlay(alignment: .topTrailing) {
      InspectorWidthResetControl(onResetWidth: onResetWidth)
        .padding(8)
    }
  }

  @ViewBuilder
  private var knowledgeInspector: some View {
    if let document = store.knowledge.selectedDocument {
      KnowledgeLibraryInspectorPanel(
        knowledge: store.knowledge,
        document: document,
        activeSearchResult: activeKnowledgeSearchResult,
        onEditMetadata: { knowledgeInspectorPresentation.editMetadata(for: document) },
        onAddAnnotation: { knowledgeInspectorPresentation.addAnnotation(to: document) },
        onAnnotateSearchHit: {
          knowledgeInspectorPresentation.annotateSearchResult(
            activeKnowledgeSearchResult,
            in: document
          )
        },
        onEditAnnotation: { knowledgeInspectorPresentation.editAnnotation($0) },
        onDeleteAnnotation: { annotationID in
          Task { await store.knowledge.deleteAnnotation(annotationID) }
        },
        onOpenSourceHistory: {
          knowledgeInspectorPresentation.openSourceHistory(for: document.id)
        },
        onReportContentIssue: {
          knowledgeInspectorPresentation.openSourceHistory(
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
    guard let result = store.knowledge.selectedSearchResult,
      result.document.id == store.knowledge.selectedDocumentID
    else { return nil }
    return result
  }

  @ViewBuilder
  private var articleInspector: some View {
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

private struct InspectorWidthResetControl: View {
  let onResetWidth: (() -> Void)?

  var body: some View {
    Button {
      onResetWidth?()
    } label: {
      Label(String(localized: "恢复默认检查器宽度"), systemImage: "arrow.counterclockwise")
    }
    .buttonStyle(.borderless)
    .help(String(localized: "恢复默认检查器宽度（Option-Command-0）"))
    .accessibilityHint(String(localized: "恢复默认宽度；也可按 Option-Command-0。"))
    .keyboardShortcut("0", modifiers: [.option, .command])
    .disabled(onResetWidth == nil)
  }
}
