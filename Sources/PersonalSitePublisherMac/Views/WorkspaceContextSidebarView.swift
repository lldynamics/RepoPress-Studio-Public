import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceUnifiedSidebar: View {
  @ObservedObject var store: WorkbenchStore
  let isCompact: Bool
  @Binding var contentHealthFilter: ContentHealthContextFilter
  let onSelectSection: (WorkspaceSection) -> Void

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceTaskNavigation(
        store: store,
        contentHealthFilter: $contentHealthFilter,
        onSelectSection: onSelectSection
      )
      .frame(
        maxWidth: .infinity,
        maxHeight: store.selectedSection.contextSidebarMode == .writingDrafts ? 170 : .infinity
      )

      if store.selectedSection.contextSidebarMode == .writingDrafts {
        WritingDraftColumn(store: store, isCompact: isCompact)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .accessibilityIdentifier("workspace-sidebar")
  }
}
