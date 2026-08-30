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
      InspectorSplitResizeHandle(
        isAIAssistantPresented: contentPresentation.isAssistantPresented,
        onResetWidth: onResetWidth
      )
    }
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

private struct InspectorSplitResizeHandle: View {
  let isAIAssistantPresented: Bool
  let onResetWidth: (() -> Void)?
  @State private var isHovered = false

  var body: some View {
    ZStack(alignment: .center) {
      // Hover highlight hairline along divider
      Rectangle()
        .fill(isHovered ? WorkbenchTheme.primary.opacity(0.45) : Color.clear)
        .frame(width: 2)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)

      // Capsule indicator
      HStack(spacing: 3) {
        Image(systemName: "arrow.left.and.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(isHovered ? WorkbenchTheme.primary : .secondary)
      }
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .background(.regularMaterial, in: Capsule())
      .overlay(
        Capsule()
          .stroke(
            isHovered
              ? WorkbenchTheme.primary.opacity(0.35)
              : Color.primary.opacity(0.12),
            lineWidth: 1
          )
      )
      .shadow(color: .black.opacity(isHovered ? 0.12 : 0.04), radius: 3, x: 0, y: 1)
      .opacity(isHovered ? 1.0 : (isAIAssistantPresented ? 0.65 : 0.28))
    }
    .frame(width: 16)
    .frame(maxHeight: .infinity)
    .contentShape(Rectangle())
    .offset(x: -8)
    .onHover { hovering in
      isHovered = hovering
      if hovering {
        NSCursor.resizeLeftRight.push()
      } else {
        NSCursor.pop()
      }
    }
    .onTapGesture(count: 2) {
      onResetWidth?()
    }
    .help("拖拽调整检查器宽度，双击恢复默认宽度（320pt）")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("检查器分栏拖拽手柄")
    .accessibilityHint("双击恢复默认宽度")
  }
}
