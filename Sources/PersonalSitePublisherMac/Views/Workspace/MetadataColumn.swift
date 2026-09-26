import PublishingKnowledgeCore
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
  let defaultWidth: CGFloat?
  @State private var measuredWidth: CGFloat?
  @ObservedObject private var articlePresentation: ArticleInspectorPresentationState

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
    articlePresentation: ArticleInspectorPresentationState,
    defaultWidth: CGFloat? = nil,
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
    _articlePresentation = ObservedObject(wrappedValue: articlePresentation)
    self.prioritizesChecks = prioritizesChecks
    self.onResetWidth = onResetWidth
    self.defaultWidth = defaultWidth
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      switch WorkspaceInspectorPresentation.route(
        for: selectedSection
      ) {
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
        KnowledgeInspectorContentView(
          knowledge: store.knowledge,
          presentation: $knowledgeInspectorPresentation
        )
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
          .opacity(isAssistantOverlayPresented ? 0 : 1)
          .allowsHitTesting(!isAssistantOverlayPresented)
          .accessibilityHidden(isAssistantOverlayPresented)
      case .aiAssistant:
        EmptyView()
      case .unavailable:
        EmptyStateView(
          title: "当前页面没有详情栏",
          message: "此页面的操作已集中在主内容区。",
          systemImage: "sidebar.right",
          density: .compactPane
        )
        .background(.bar)
      }

      if isAssistantOverlayPresented {
        AIChatContextInspectorView(
          store: store,
          selectedDraftID: selectedDraftID,
          usesWindowDraftSelection: true,
          surfaceState: $aiChatSurfaceState,
          operationSession: aiChatOperationSession
        )
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace-inspector")
    .accessibilityLabel("工作区详情栏")
    .onGeometryChange(for: CGFloat.self) { geometry in
      geometry.size.width
    } action: { width in
      measuredWidth = width
    }
    .overlay(alignment: .topTrailing) {
      if WorkspaceInspectorWidthResetPolicy.showsResetControl(
        measuredWidth: measuredWidth,
        defaultWidth: defaultWidth
      ) {
        InspectorWidthResetControl(onResetWidth: onResetWidth)
          .padding(8)
      }
    }
  }

  /// AI is an overlay only for Writing. The underlying article Inspector stays
  /// at a stable tree position, so its selected tab and ScrollView state can
  /// survive a temporary AI presentation without exposing a second host.
  private var isAssistantOverlayPresented: Bool {
    selectedSection == .writing && contentPresentation.isAssistantPresented
  }
}

private struct KnowledgeInspectorContentView: View {
  @ObservedObject var knowledge: KnowledgeStore
  @Binding var presentation: KnowledgeLibraryInspectorPresentationState

  @ViewBuilder
  var body: some View {
    if let document = knowledge.selectedDocument {
      KnowledgeLibraryInspectorPanel(
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

private struct InspectorWidthResetControl: View {
  let onResetWidth: (() -> Void)?

  var body: some View {
    Button {
      onResetWidth?()
    } label: {
      Label(String(localized: "恢复默认详情栏宽度"), systemImage: "arrow.counterclockwise")
        .labelStyle(.iconOnly)
        .frame(width: 22, height: 22)
        .background(.bar, in: Circle())
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(String(localized: "恢复默认详情栏宽度"))
    .help(String(localized: "恢复默认详情栏宽度（Option-Command-0）"))
    .accessibilityHint(String(localized: "恢复默认宽度；也可按 Option-Command-0。"))
    .keyboardShortcut("0", modifiers: [.option, .command])
    .disabled(onResetWidth == nil)
  }
}
