import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceShellSplitLayout: View {
  let store: WorkbenchStore
  let selectedSection: WorkspaceSection
  let selectedDraftID: UUID?
  let isCompact: Bool
  let isFocusMode: Bool
  let isSidebarPresented: Bool
  let isInspectorPresented: Bool
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var imageWorkbenchContextStage: ImageWorkbenchContextStage
  @Binding var repositoryContextStage: RepositoryContextStage
  @Binding var repositoryChangedFileSelection: RepositoryChangedFileSelection?
  @Binding var knowledgeInspectorPresentation: KnowledgeLibraryInspectorPresentationState
  let repositorySourceSession: RepositoryHTMLSourceSession
  let rssStore: RSSReaderStore
  let onSelectSection: (WorkspaceSection) -> Void
  let onSelectDraft: (UUID?) -> Void
  let onFocusDraft: (UUID, WorkspaceSection) -> Void
  @AppStorage("workspacePrimarySidebarWidthV2")
  private var storedSidebarWidth = Double(WorkbenchLayoutMode.defaultSidebarWidth)
  @State private var sidebarResizeStartWidth: CGFloat?
  @StateObject private var contentHealthSidebarProjection = ContentHealthSidebarProjection()
  @StateObject private var rssPresentation = RSSReaderPresentationState()

  init(
    store: WorkbenchStore,
    selectedSection: WorkspaceSection,
    selectedDraftID: UUID?,
    isCompact: Bool,
    isFocusMode: Bool,
    isInspectorPresented: Bool,
    contentHealthFilter: Binding<ContentHealthContextFilter>,
    imageWorkbenchContextStage: Binding<ImageWorkbenchContextStage>,
    repositoryContextStage: Binding<RepositoryContextStage>,
    repositoryChangedFileSelection: Binding<RepositoryChangedFileSelection?>,
    knowledgeInspectorPresentation: Binding<KnowledgeLibraryInspectorPresentationState>,
    repositorySourceSession: RepositoryHTMLSourceSession,
    rssStore: RSSReaderStore,
    onSelectSection: @escaping (WorkspaceSection) -> Void,
    onSelectDraft: @escaping (UUID?) -> Void,
    onFocusDraft: @escaping (UUID, WorkspaceSection) -> Void,
    isSidebarPresented: Bool = true
  ) {
    self.store = store
    self.selectedSection = selectedSection
    self.selectedDraftID = selectedDraftID
    self.isCompact = isCompact
    self.isFocusMode = isFocusMode
    self.isSidebarPresented = isSidebarPresented
    self.isInspectorPresented = isInspectorPresented
    _contentHealthFilter = contentHealthFilter
    _imageWorkbenchContextStage = imageWorkbenchContextStage
    _repositoryContextStage = repositoryContextStage
    _repositoryChangedFileSelection = repositoryChangedFileSelection
    _knowledgeInspectorPresentation = knowledgeInspectorPresentation
    self.repositorySourceSession = repositorySourceSession
    self.rssStore = rssStore
    self.onSelectSection = onSelectSection
    self.onSelectDraft = onSelectDraft
    self.onFocusDraft = onFocusDraft
  }

  var body: some View {
    GeometryReader { geometry in
      workspace(workspaceWidth: geometry.size.width)
    }
  }

  private func workspace(workspaceWidth: CGFloat) -> some View {
    HStack(spacing: 0) {
      if WorkspaceSidebarVisibilityPolicy.shouldShowSidebar(
        userWantsVisible: isSidebarPresented,
        isFocusMode: isFocusMode
      ) {
        WorkspacePrimarySidebar(
          store: store,
          selectedSection: selectedSection,
          selectedDraftID: selectedDraftID,
          contentHealthFilter: $contentHealthFilter,
          imageWorkbenchContextStage: $imageWorkbenchContextStage,
          repositoryContextStage: $repositoryContextStage,
          contentHealthSidebarProjection: contentHealthSidebarProjection,
          rssStore: rssStore,
          rssPresentation: rssPresentation,
          onSelectSection: onSelectSection,
          onSelectDraft: onSelectDraft,
          onFocusDraft: onFocusDraft
        )
        .frame(width: sidebarWidth(workspaceWidth: workspaceWidth))
        .frame(maxHeight: .infinity)

        workspaceSidebarResizeHandle(workspaceWidth: workspaceWidth)
      }

      EditorCenterColumn(
        store: store,
        selectedSection: selectedSection,
        selectedDraftID: selectedDraftID,
        contentHealthFilter: $contentHealthFilter,
        imageWorkbenchContextStage: $imageWorkbenchContextStage,
        repositoryContextStage: $repositoryContextStage,
        repositoryChangedFileSelection: $repositoryChangedFileSelection,
        contentHealthSidebarProjection: contentHealthSidebarProjection,
        repositorySourceSession: repositorySourceSession,
        rssStore: rssStore,
        rssPresentation: rssPresentation,
        knowledgeInspectorPresentation: $knowledgeInspectorPresentation
      )
      .frame(
        minWidth: isFocusMode ? 680 : centerMinimumWidth,
        maxWidth: .infinity,
        maxHeight: .infinity
      )
    }
    .knowledgeFileDropImport(
      knowledge: store.knowledge,
      isEnabled: selectedSection == .library
    )
  }

  private func sidebarWidth(workspaceWidth: CGFloat) -> CGFloat {
    WorkbenchLayoutMode.sidebarWidth(
      storedWidth: CGFloat(storedSidebarWidth),
      workspaceWidth: workspaceWidth,
      centerMinimumWidth: centerMinimumWidth,
      inspectorPresented: isInspectorPresented
    )
  }

  private var centerMinimumWidth: CGFloat {
    if selectedSection == .sync, repositoryContextStage == .source {
      return 680
    }
    return isCompact ? 460 : 560
  }

  private func sidebarMaximumWidth(workspaceWidth: CGFloat) -> CGFloat {
    WorkbenchLayoutMode.sidebarWidth(
      storedWidth: 380,
      workspaceWidth: workspaceWidth,
      centerMinimumWidth: centerMinimumWidth,
      inspectorPresented: isInspectorPresented
    )
  }

  private func workspaceSidebarResizeHandle(workspaceWidth: CGFloat) -> some View {
    let sidebarWidth = sidebarWidth(workspaceWidth: workspaceWidth)
    let sidebarMaximumWidth = sidebarMaximumWidth(workspaceWidth: workspaceWidth)
    return Divider()
      .overlay {
        Color.clear
          .frame(width: 10)
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 1)
              .onChanged { value in
                let startWidth = sidebarResizeStartWidth ?? sidebarWidth
                sidebarResizeStartWidth = startWidth
                storedSidebarWidth = Double(
                  min(max(startWidth + value.translation.width, 240), sidebarMaximumWidth)
                )
              }
              .onEnded { _ in
                sidebarResizeStartWidth = nil
              }
          )
      }
      .accessibilityElement()
      .accessibilityLabel("调整工作区侧栏宽度")
      .accessibilityValue(String(localized: "\(Int(sidebarWidth)) 点"))
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment:
          storedSidebarWidth = Double(min(sidebarWidth + 20, sidebarMaximumWidth))
        case .decrement:
          storedSidebarWidth = Double(max(sidebarWidth - 20, 240))
        @unknown default:
          break
        }
      }
  }
}
