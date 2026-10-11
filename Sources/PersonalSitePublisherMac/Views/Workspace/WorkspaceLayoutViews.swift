import AppKit
import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceImageInspectorNavigationObserver: ViewModifier {
  @ObservedObject private var images: WorkbenchImageWorkbenchFeatureFacade
  let onRequest: (ImageInspectorFocusRequest) -> Void

  init(store: WorkbenchStore, onRequest: @escaping (ImageInspectorFocusRequest) -> Void) {
    _images = ObservedObject(wrappedValue: store.imageWorkbench)
    self.onRequest = onRequest
  }

  func body(content: Content) -> some View {
    content.onChange(of: images.imageInspectorFocusRequest?.id) { _, _ in
      if let request = images.imageInspectorFocusRequest { onRequest(request) }
    }
  }
}

struct WorkspaceShellSplitLayout: View {
  let store: WorkbenchStore
  let selectedSection: WorkspaceSection
  let selectedDraftID: UUID?
  let writingListState: WritingListWindowPresentationState
  let isCompact: Bool
  let isFocusMode: Bool
  let isSidebarPresented: Bool
  let isInspectorPresented: Bool
  @Binding var selectedHealthIssue: ContentHealthIssueSelection?
  let healthInspectorActions: ContentHealthInspectorActions
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var imageWorkbenchContextStage: ImageWorkbenchContextStage
  let imageBrowserSession: RepositoryImageBrowserSession
  @Binding var repositoryContextStage: RepositoryContextStage
  @Binding var repositoryChangedFileSelection: RepositoryChangedFileSelection?
  @Binding var knowledgeInspectorPresentation: KnowledgeLibraryInspectorPresentationState
  let repositorySourceSession: RepositoryHTMLSourceSession
  let rssStore: RSSReaderStore
  let rssPresentation: RSSReaderPresentationState
  let onSelectSection: (WorkspaceSection) -> Void
  let onSelectDraft: (UUID?) -> Void
  let onFocusDraft: (UUID, WorkspaceSection) -> Void
  let openTaskCenter: () -> Void
  @AppStorage("workspacePrimarySidebarWidthV2")
  private var storedSidebarWidth = Double(WorkbenchLayoutMode.defaultSidebarWidth)
  @State private var sidebarResizeStartWidth: CGFloat?
  @State private var isSidebarResizeCursorActive = false
  @StateObject private var contentHealthSidebarProjection = ContentHealthSidebarProjection()

  init(
    store: WorkbenchStore,
    selectedSection: WorkspaceSection,
    selectedDraftID: UUID?,
    writingListState: WritingListWindowPresentationState,
    isCompact: Bool,
    isFocusMode: Bool,
    isInspectorPresented: Bool,
    contentHealthFilter: Binding<ContentHealthContextFilter>,
    selectedHealthIssue: Binding<ContentHealthIssueSelection?>,
    healthInspectorActions: ContentHealthInspectorActions,
    imageWorkbenchContextStage: Binding<ImageWorkbenchContextStage>,
    imageBrowserSession: RepositoryImageBrowserSession,
    repositoryContextStage: Binding<RepositoryContextStage>,
    repositoryChangedFileSelection: Binding<RepositoryChangedFileSelection?>,
    knowledgeInspectorPresentation: Binding<KnowledgeLibraryInspectorPresentationState>,
    repositorySourceSession: RepositoryHTMLSourceSession,
    rssStore: RSSReaderStore,
    rssPresentation: RSSReaderPresentationState,
    onSelectSection: @escaping (WorkspaceSection) -> Void,
    onSelectDraft: @escaping (UUID?) -> Void,
    onFocusDraft: @escaping (UUID, WorkspaceSection) -> Void,
    openTaskCenter: @escaping () -> Void,
    isSidebarPresented: Bool = true
  ) {
    self.store = store
    self.selectedSection = selectedSection
    self.selectedDraftID = selectedDraftID
    self.writingListState = writingListState
    self.isCompact = isCompact
    self.isFocusMode = isFocusMode
    self.isSidebarPresented = isSidebarPresented
    self.isInspectorPresented = isInspectorPresented
    _contentHealthFilter = contentHealthFilter
    _selectedHealthIssue = selectedHealthIssue
    self.healthInspectorActions = healthInspectorActions
    _imageWorkbenchContextStage = imageWorkbenchContextStage
    self.imageBrowserSession = imageBrowserSession
    _repositoryContextStage = repositoryContextStage
    _repositoryChangedFileSelection = repositoryChangedFileSelection
    _knowledgeInspectorPresentation = knowledgeInspectorPresentation
    self.repositorySourceSession = repositorySourceSession
    self.rssStore = rssStore
    self.rssPresentation = rssPresentation
    self.onSelectSection = onSelectSection
    self.onSelectDraft = onSelectDraft
    self.onFocusDraft = onFocusDraft
    self.openTaskCenter = openTaskCenter
  }

  var body: some View {
    GeometryReader { geometry in
      workspace(workspaceWidth: geometry.size.width)
    }
  }

  private func workspace(workspaceWidth: CGFloat) -> some View {
    HStack(spacing: 0) {
      if WorkspaceSidebarVisibilityPolicy.shouldShowNavigationRail(
        isFocusMode: isFocusMode
      ) {
        WorkspacePrimaryNavigationRail(
          store: store,
          selectedSection: selectedSection,
          siteIssueCount: contentHealthSidebarProjection.knownIssueCount(
            for: store.activeProfile.id),
          onSelectSection: onSelectSection,
          openTaskCenter: openTaskCenter
        )

        Divider()
      }

      if WorkspaceSidebarVisibilityPolicy.shouldShowSidebar(
        userWantsVisible: isSidebarPresented,
        isFocusMode: isFocusMode
      ) {
        WorkspacePrimarySidebar(
          store: store,
          selectedSection: selectedSection,
          selectedDraftID: selectedDraftID,
          writingListState: writingListState,
          contentHealthFilter: $contentHealthFilter,
          imageWorkbenchContextStage: $imageWorkbenchContextStage,
          imageBrowserSession: imageBrowserSession,
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
        selectedHealthIssue: $selectedHealthIssue,
        healthInspectorActions: healthInspectorActions,
        imageWorkbenchContextStage: $imageWorkbenchContextStage,
        imageBrowserSession: imageBrowserSession,
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
      workspaceWidth: workspaceWidth + (isInspectorPresented ? inspectorWidthBudget : 0),
      centerMinimumWidth: centerMinimumWidth,
      inspectorPresented: isInspectorPresented,
      inspectorMinimumWidth: inspectorWidthBudget
    )
  }

  /// `workspaceWidth` is measured beside the Inspector, so the same budget is
  /// added back and subtracted again: the sidebar only yields to the center
  /// minimum, whatever width the user dragged the Inspector to.
  private var inspectorWidthBudget: CGFloat { WorkbenchLayoutMode.inspectorIdealWidth }

  private var centerMinimumWidth: CGFloat {
    return isCompact ? 460 : 560
  }

  private func sidebarMaximumWidth(workspaceWidth: CGFloat) -> CGFloat {
    WorkbenchLayoutMode.sidebarWidth(
      storedWidth: 380,
      workspaceWidth: workspaceWidth + (isInspectorPresented ? inspectorWidthBudget : 0),
      centerMinimumWidth: centerMinimumWidth,
      inspectorPresented: isInspectorPresented,
      inspectorMinimumWidth: inspectorWidthBudget
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
          .onHover(perform: setSidebarResizeCursor)
          .onDisappear { setSidebarResizeCursor(false) }
          .help("拖动以调整侧栏宽度")
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

  private func setSidebarResizeCursor(_ active: Bool) {
    guard isSidebarResizeCursorActive != active else { return }
    isSidebarResizeCursorActive = active
    if active {
      NSCursor.resizeLeftRight.push()
    } else {
      NSCursor.pop()
    }
  }
}
