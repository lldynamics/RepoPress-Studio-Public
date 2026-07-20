import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceShellSplitLayout: View {
  let store: WorkbenchStore
  @ObservedObject private var layoutState: WorkbenchWorkspaceLayoutFeatureFacade
  let isCompact: Bool
  let isFocusMode: Bool
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var repositoryContextStage: RepositoryContextStage
  let onSelectSection: (WorkspaceSection) -> Void
  @AppStorage("workspacePrimarySidebarWidthV1") private var storedSidebarWidth = 260.0
  @State private var sidebarResizeStartWidth: CGFloat?

  init(
    store: WorkbenchStore,
    isCompact: Bool,
    isFocusMode: Bool,
    contentHealthFilter: Binding<ContentHealthContextFilter>,
    repositoryContextStage: Binding<RepositoryContextStage>,
    onSelectSection: @escaping (WorkspaceSection) -> Void
  ) {
    self.store = store
    _layoutState = ObservedObject(wrappedValue: store.workspaceLayout)
    self.isCompact = isCompact
    self.isFocusMode = isFocusMode
    _contentHealthFilter = contentHealthFilter
    _repositoryContextStage = repositoryContextStage
    self.onSelectSection = onSelectSection
  }

  var body: some View {
    HStack(spacing: 0) {
      if !isFocusMode {
        WorkspacePrimarySidebar(
          store: store,
          contentHealthFilter: $contentHealthFilter,
          onSelectSection: onSelectSection
        )
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity)

        workspaceSidebarResizeHandle
      }

      if isFocusMode {
        EditorCenterColumn(
          store: store,
          contentHealthFilter: contentHealthFilter,
          repositoryContextStage: $repositoryContextStage
        )
        .frame(minWidth: 680, maxWidth: .infinity, maxHeight: .infinity)
      } else {
        EditorCenterColumn(
          store: store,
          contentHealthFilter: contentHealthFilter,
          repositoryContextStage: $repositoryContextStage
        )
        .frame(minWidth: isCompact ? 460 : 560, maxWidth: .infinity, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .knowledgeFileDropImport(
      knowledge: store.knowledge,
      isEnabled: layoutState.selectedSection == .library
    )
  }

  private var sidebarWidth: CGFloat {
    min(max(CGFloat(storedSidebarWidth), 240), 380)
  }

  private var workspaceSidebarResizeHandle: some View {
    Divider()
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
                  min(max(startWidth + value.translation.width, 240), 380)
                )
              }
              .onEnded { _ in
                sidebarResizeStartWidth = nil
              }
          )
      }
      .accessibilityElement()
      .accessibilityLabel("调整工作区侧栏宽度")
      .accessibilityValue("\(Int(sidebarWidth)) 点")
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment:
          storedSidebarWidth = Double(min(sidebarWidth + 20, 380))
        case .decrement:
          storedSidebarWidth = Double(max(sidebarWidth - 20, 240))
        @unknown default:
          break
        }
      }
  }
}
