import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskInspector: View {
  let section: WorkspaceSection
  @Binding var draft: ArticleDraft
  let store: WorkbenchStore
  let rssStore: RSSReaderStore
  let presentation: ArticleInspectorPresentationState
  let prioritizesChecks: Bool

  init(
    section: WorkspaceSection,
    draft: Binding<ArticleDraft>,
    store: WorkbenchStore,
    rssStore: RSSReaderStore,
    presentation: ArticleInspectorPresentationState,
    prioritizesChecks: Bool = false
  ) {
    self.section = section
    _draft = draft
    self.store = store
    self.rssStore = rssStore
    self.presentation = presentation
    self.prioritizesChecks = prioritizesChecks
  }

  var body: some View {
    switch section {
    case .sync:
      RepositoryContextInspectorView(store: store)
    case .library, .rss:
      EmptyView()
    case .writing, .contentHealth, .images:
      ArticleInspectorTabs(
        selectedTab: selectedTab,
        draft: $draft,
        store: store,
        rssStore: rssStore,
        section: section,
        availableTabs: availableTabs,
        presentation: presentation
      )
    }
  }

  private func initialTab(for section: WorkspaceSection) -> ArticleInspectorTab {
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      if ScreenshotDemoDataService.isEnabledFromEnvironment,
        ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .seoSocialPreview,
        section == .writing
      {
        return .seo
      }
    #endif
    if prioritizesChecks && ArticleInspectorTab.availableTabs(for: section).contains(.checks) {
      return .checks
    }
    if section == .writing,
      !store.knowledge.documents.contains(where: { !$0.isArchived && $0.allowsLocalSemanticIndex })
    {
      return .metadata
    }
    return ArticleInspectorTab.defaultTab(for: section)
  }

  private var availableTabs: [ArticleInspectorTab] {
    ArticleInspectorTab.availableTabs(for: section)
  }

  private var selectedTab: Binding<ArticleInspectorTab> {
    presentation.binding(
      for: draft.id,
      section: section,
      defaultTab: initialTab(for: section)
    )
  }
}

struct RepositoryContextInspectorView: View {
  let store: WorkbenchStore
  @ObservedObject private var statusState: WorkbenchPublishStatusFeatureFacade
  @Binding private var changedFileSelection: RepositoryChangedFileSelection?

  init(
    store: WorkbenchStore,
    changedFileSelection: Binding<RepositoryChangedFileSelection?> = .constant(nil)
  ) {
    self.store = store
    _statusState = ObservedObject(wrappedValue: store.publishStatus)
    _changedFileSelection = changedFileSelection
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "arrow.left.arrow.right")
          .foregroundStyle(.workbenchSecondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("仓库与发布详情栏")
            .font(.workbenchHeadline)
          Text("只显示当前阻断与文件变更")
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
        }
        Spacer()
      }
      .padding(WorkbenchSpacing.content)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          blockerSection
          selectedFileSection
        }
        .padding(WorkbenchSpacing.content)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(.bar)
    .accessibilityIdentifier("repository-context-inspector")
    .accessibilityLabel("仓库与发布详情栏")
  }

  @ViewBuilder
  private var blockerSection: some View {
    let issues = statusState.repositoryReport?.preflightIssues ?? []
    let repositoryFailureIsShownInOverview =
      store.repositoryOperationLifecycle?.readFailure != nil
      || statusState.repositoryReport?.hasGitDirectory == false
    if repositoryFailureIsShownInOverview {
      EmptyView()
    } else if let issue = issues.first(where: { $0.severity == .error })
      ?? issues.first(where: { $0.severity == .warning })
    {
      // Only an error blocks; a warning is shown under a neutral heading so the
      // card title never contradicts its own severity badge.
      inspectorCard(
        title: issue.severity == .error
          ? LocalizedStringKey("当前阻断") : LocalizedStringKey("需要注意"),
        systemImage: "exclamationmark.triangle"
      ) {
        SeverityBadge(severity: issue.severity)
        Text(issue.title)
          .font(.workbenchBody.weight(.medium))
        Text(issue.message)
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
      }
    } else if let readiness = statusState.localPublishReadiness,
      readiness.blockingIssueCount > 0
    {
      inspectorCard(title: "当前阻断", systemImage: "checklist") {
        Text("当前文章有 \(readiness.blockingIssueCount) 个发布阻断项。")
          .font(.workbenchBody)
        Text("在“检查”中选择文章，可在详情栏直接处理检查结果。")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
      }
    } else {
      Label("没有仓库或发布阻断", systemImage: "checkmark.circle")
        .foregroundStyle(WorkbenchTheme.success)
    }
  }

  @ViewBuilder
  private var selectedFileSection: some View {
    let report = statusState.repositoryReport
    let localFiles = report?.changedFiles ?? []
    let remoteFiles = report?.remoteChangedFiles ?? []
    let selection = RepositoryChangedFileSelectionPresentation.reconciledSelection(
      changedFileSelection,
      localFiles: localFiles,
      remoteFiles: remoteFiles
    )
    let file = RepositoryChangedFileSelectionPresentation.selectedFile(
      for: selection,
      localFiles: localFiles,
      remoteFiles: remoteFiles
    )

    inspectorCard(title: "当前文件", systemImage: "doc.text.magnifyingglass") {
      if let selection, let file {
        selectedFileDetails(file, source: selection.source)
          .onAppear { reconcileSelection(selection) }
      } else {
        Text("在主区域选择本地或远端文件后，这里会显示完整状态和可选差异。")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .onAppear { reconcileSelection(nil) }
      }
    }
    .onChange(of: report) { _, newReport in
      reconcileSelection(
        RepositoryChangedFileSelectionPresentation.reconciledSelection(
          changedFileSelection,
          localFiles: newReport?.changedFiles ?? [],
          remoteFiles: newReport?.remoteChangedFiles ?? []
        )
      )
    }
  }

  private func selectedFileDetails(
    _ file: RepositoryChangedFile,
    source: RepositoryChangedFileSource
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        source.localizedDisplayName,
        systemImage: source == .local ? "desktopcomputer" : "arrow.down.doc"
      )
      .font(.workbenchMetadata.weight(.semibold))
      .foregroundStyle(.workbenchSecondary)
      WorkbenchPathIdentity(path: file.displayPath)
      LabeledContent("状态", value: file.status)
        .font(.workbenchMetadata.monospaced())
      LabeledContent("变更", value: file.kind.localizedDisplayName)
        .font(.workbenchMetadata)

      if let lineDiff = file.lineDiff {
        DisclosureGroup("完整差异") {
          ScrollView([.horizontal, .vertical]) {
            Text(lineDiff)
              .font(.workbenchMetadata.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 260)
          .padding(.top, WorkbenchSpacing.icon)
        }
        .font(.workbenchMetadata.weight(.medium))
        .accessibilityIdentifier("repository-inspector-selected-file-diff")
      } else {
        Button {
          Task {
            _ = await store.repository.loadLineDiff(for: file, isRemote: source == .remote)
          }
        } label: {
          Label("读取完整差异", systemImage: "doc.text.magnifyingglass")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("repository-inspector-selected-file-load-diff")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("当前选择的\(source.localizedDisplayName)文件")
    .accessibilityValue("\(file.displayPath)，\(file.status)，\(file.kind.localizedDisplayName)")
    .accessibilityIdentifier("repository-inspector-selected-file")
  }

  private func reconcileSelection(_ selection: RepositoryChangedFileSelection?) {
    guard changedFileSelection != selection else { return }
    changedFileSelection = selection
  }

  private func inspectorCard<Content: View>(
    title: LocalizedStringKey,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: systemImage)
        .font(.workbenchMetadata.weight(.semibold))
        .foregroundStyle(.workbenchSecondary)
      content()
    }
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}
