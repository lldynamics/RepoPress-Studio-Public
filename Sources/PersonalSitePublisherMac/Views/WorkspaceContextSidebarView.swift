import PublishingWorkbenchCore
import SwiftUI

enum WorkspaceSidebarMetrics {
  static let horizontalPadding: CGFloat = 12
  static let headerVerticalPadding: CGFloat = 10
  static let toolbarVerticalPadding: CGFloat = 8
  static let rowInsets = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
}

struct WorkspaceContextListHeader<Subtitle: View, Actions: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder let subtitle: () -> Subtitle
  @ViewBuilder let actions: () -> Actions

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        subtitle()
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      HStack(spacing: 4) {
        actions()
      }
      .controlSize(.small)
    }
    .frame(minHeight: 38)
  }
}

struct WorkspaceSidebarHeaderIcon: View {
  let systemName: String

  init(_ systemName: String) {
    self.systemName = systemName
  }

  var body: some View {
    Image(systemName: systemName)
      .frame(width: 24, height: 24)
      .contentShape(Rectangle())
  }
}

struct WorkspacePrimarySidebar: View {
  @ObservedObject var store: WorkbenchStore
  let isCompact: Bool
  @Binding var contentHealthFilter: ContentHealthContextFilter
  let onSelectSection: (WorkspaceSection) -> Void

  var body: some View {
    VStack(spacing: 0) {
      if showsContextList {
        taskNavigation
          .frame(height: isCompact ? 198 : 210)

        Divider()

        contextList
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        taskNavigation
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.bar)
    .accessibilityIdentifier("workspace-sidebar")
  }

  private var showsContextList: Bool {
    store.selectedSection == .writing || store.selectedSection == .library
  }

  private var taskNavigation: some View {
    WorkspaceTaskNavigation(
      store: store,
      contentHealthFilter: $contentHealthFilter,
      onSelectSection: onSelectSection
    )
  }

  @ViewBuilder
  private var contextList: some View {
    switch store.selectedSection {
    case .writing:
      WritingDraftColumn(store: store, isCompact: true)
    case .library:
      KnowledgeSourceListColumn(knowledge: store.knowledge)
    default:
      EmptyView()
    }
  }
}
