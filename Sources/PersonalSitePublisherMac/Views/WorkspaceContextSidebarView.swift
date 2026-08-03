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
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.workbenchSectionTitle)
        subtitle()
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 8)

      HStack(spacing: 4) {
        actions()
      }
      .controlSize(.small)
      .frame(height: 28, alignment: .center)
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
      .font(.system(size: 15, weight: .medium))
      .frame(width: 28, height: 28)
      .contentShape(Rectangle())
  }
}

struct WorkspacePrimarySidebar: View {
  let store: WorkbenchStore
  @ObservedObject private var shell: WorkbenchShellFeatureFacade
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var imageWorkbenchContextStage: ImageWorkbenchContextStage
  @Binding var repositoryContextStage: RepositoryContextStage
  let contentHealthSidebarProjection: ContentHealthSidebarProjection
  let rssStore: RSSReaderStore
  let rssPresentation: RSSReaderPresentationState
  let onSelectSection: (WorkspaceSection) -> Void

  init(
    store: WorkbenchStore,
    contentHealthFilter: Binding<ContentHealthContextFilter>,
    imageWorkbenchContextStage: Binding<ImageWorkbenchContextStage>,
    repositoryContextStage: Binding<RepositoryContextStage>,
    contentHealthSidebarProjection: ContentHealthSidebarProjection,
    rssStore: RSSReaderStore,
    rssPresentation: RSSReaderPresentationState,
    onSelectSection: @escaping (WorkspaceSection) -> Void
  ) {
    self.store = store
    _shell = ObservedObject(wrappedValue: store.shell)
    _contentHealthFilter = contentHealthFilter
    _imageWorkbenchContextStage = imageWorkbenchContextStage
    _repositoryContextStage = repositoryContextStage
    self.contentHealthSidebarProjection = contentHealthSidebarProjection
    self.rssStore = rssStore
    self.rssPresentation = rssPresentation
    self.onSelectSection = onSelectSection
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsContextList {
        taskNavigation
          .fixedSize(horizontal: false, vertical: true)

        Divider()

        contextList
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        taskNavigation
          .fixedSize(horizontal: false, vertical: true)

        Divider()

        WorkspaceQuickSearchView(
          store: store,
          scope: quickSearchScope,
          contentHealthSidebarProjection: contentHealthSidebarProjection,
          contentHealthFilter: shell.selectedSection == .contentHealth
            ? $contentHealthFilter
            : nil,
          imageWorkbenchContextStage: shell.selectedSection == .images
            ? $imageWorkbenchContextStage
            : nil,
          repositoryContextStage: shell.selectedSection == .sync
            ? $repositoryContextStage
            : nil
        )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .workbenchGlassContainer(material: .thinMaterial, drawsBorder: false)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace-sidebar")
  }

  private var showsContextList: Bool {
    shell.selectedSection == .writing
      || shell.selectedSection == .library
      || shell.selectedSection == .rss
  }

  private var quickSearchScope: WorkspaceQuickSearchScope {
    switch shell.selectedSection {
    case .images:
      return .imageResources
    case .contentHealth:
      return .aiFixes
    case .writing, .library, .rss, .siteStarter, .sync:
      return .recent
    }
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
    switch shell.selectedSection {
    case .writing:
      WritingDraftColumn(store: store, isCompact: true)
    case .library:
      KnowledgeSourceListColumn(store: store, knowledge: store.knowledge)
    case .rss:
      RSSReaderWorkspaceSidebar(store: rssStore, presentation: rssPresentation)
    default:
      EmptyView()
    }
  }
}
