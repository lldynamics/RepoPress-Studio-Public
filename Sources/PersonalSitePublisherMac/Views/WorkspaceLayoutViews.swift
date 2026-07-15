import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceShellSplitLayout: View {
  @ObservedObject var store: WorkbenchStore
  let isCompact: Bool
  let isInspectorPresented: Bool
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var repositoryContextStage: RepositoryContextStage

  var body: some View {
    HStack(spacing: 0) {
      WorkspaceRail(store: store)
        .frame(minWidth: 52, maxWidth: 52, maxHeight: .infinity)

      Divider()

      if store.selectedSection.contextSidebarMode != .none {
        WorkspaceContextSidebar(
          store: store,
          isCompact: isCompact,
          contentHealthFilter: $contentHealthFilter,
          repositoryContextStage: $repositoryContextStage
        )
        .frame(
          minWidth: isCompact ? 220 : 260,
          idealWidth: isCompact ? 240 : 300,
          maxWidth: isCompact ? 300 : 380,
          maxHeight: .infinity
        )

        Divider()
      }

      HSplitView {
        EditorCenterColumn(
          store: store,
          contentHealthFilter: contentHealthFilter,
          repositoryContextStage: $repositoryContextStage
        )
        .frame(minWidth: isCompact ? 460 : 560, maxWidth: .infinity, maxHeight: .infinity)

        if isInspectorPresented && !isCompact {
          MetadataColumn(store: store)
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 460, maxHeight: .infinity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
