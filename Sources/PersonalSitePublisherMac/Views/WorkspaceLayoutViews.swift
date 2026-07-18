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
        WorkspacePrimarySidebar(
          store: store,
          isCompact: isCompact,
          contentHealthFilter: $contentHealthFilter,
          onSelectSection: onSelectSection
        )
        .frame(width: isCompact ? 240 : 260)
        .frame(maxHeight: .infinity)

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
