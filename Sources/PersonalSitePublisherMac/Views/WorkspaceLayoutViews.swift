import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceShellSplitLayout: View {
  @ObservedObject var store: WorkbenchStore
  let isCompact: Bool
  let isInspectorPresented: Bool
  let isAIInspectorSelected: Bool
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var repositoryContextStage: RepositoryContextStage
  let onSelectSection: (WorkspaceSection) -> Void
  let onOpenAIInspector: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      WorkspaceUnifiedSidebar(
        store: store,
        isCompact: isCompact,
        isAIInspectorSelected: isAIInspectorSelected,
        contentHealthFilter: $contentHealthFilter,
        repositoryContextStage: $repositoryContextStage,
        onSelectSection: onSelectSection,
        onOpenAIInspector: onOpenAIInspector
      )
      .frame(
        minWidth: isCompact ? 230 : 260,
        idealWidth: isCompact ? 240 : 290,
        maxWidth: isCompact ? 280 : 320,
        maxHeight: .infinity
      )

      Divider()

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
