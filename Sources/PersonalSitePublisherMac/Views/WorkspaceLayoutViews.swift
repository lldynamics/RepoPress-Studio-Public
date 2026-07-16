import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceShellSplitLayout: View {
  @ObservedObject var store: WorkbenchStore
  let isCompact: Bool
  let isFocusMode: Bool
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var repositoryContextStage: RepositoryContextStage
  let onSelectSection: (WorkspaceSection) -> Void

  var body: some View {
    HStack(spacing: 0) {
      if !isFocusMode {
        WorkspaceUnifiedSidebar(
          store: store,
          isCompact: isCompact,
          contentHealthFilter: $contentHealthFilter,
          onSelectSection: onSelectSection
        )
        .frame(
          minWidth: isCompact ? 230 : 260,
          idealWidth: isCompact ? 240 : 290,
          maxWidth: isCompact ? 280 : 320,
          maxHeight: .infinity
        )

        Divider()
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
  }
}
