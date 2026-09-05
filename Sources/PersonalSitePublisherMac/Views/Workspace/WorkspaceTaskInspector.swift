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
        availableTabs: availableTabs
      )
    case .siteStarter:
      SiteStarterInspectorView(store: store)
    }
  }

  private func initialTab(for section: WorkspaceSection) -> ArticleInspectorTab {
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    if ScreenshotDemoDataService.isEnabledFromEnvironment,
       ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .seoSocialPreview,
       section == .writing {
      return .seo
    }
#endif
    if prioritizesChecks && ArticleInspectorTab.availableTabs(for: section).contains(.checks) {
      return .checks
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
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("仓库与发布 Inspector")
            .font(.headline)
          Text("只显示当前阻断与文件变更")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(14)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          blockerSection
          selectedFileSection
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(.bar)
    .accessibilityIdentifier("repository-context-inspector")
    .accessibilityLabel("仓库与发布 Inspector")
  }

  @ViewBuilder
  private var blockerSection: some View {
    let issues = statusState.repositoryReport?.preflightIssues ?? []
    if let issue = issues.first(where: { $0.severity == .error })
      ?? issues.first(where: { $0.severity == .warning }) {
      inspectorCard(title: "当前阻断", systemImage: "exclamationmark.triangle") {
        SeverityBadge(severity: issue.severity)
        Text(issue.title)
          .font(.callout.weight(.medium))
        Text(issue.message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else if let readiness = statusState.localPublishReadiness,
              readiness.blockingIssueCount > 0 {
      inspectorCard(title: "当前阻断", systemImage: "checklist") {
        Text("当前文章有 \(readiness.blockingIssueCount) 个发布阻断项。")
          .font(.callout)
        Text("在内容健康中选择文章，可在 Inspector 直接处理检查结果。")
          .font(.caption)
          .foregroundStyle(.secondary)
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
          .font(.caption)
          .foregroundStyle(.secondary)
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
      Label(source.localizedDisplayName, systemImage: source == .local ? "desktopcomputer" : "arrow.down.doc")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      WorkbenchPathIdentity(path: file.displayPath)
      LabeledContent("状态", value: file.status)
        .font(.caption.monospaced())
      LabeledContent("变更", value: file.kind.localizedDisplayName)
        .font(.caption)

      if let lineDiff = file.lineDiff {
        DisclosureGroup("完整差异") {
          ScrollView([.horizontal, .vertical]) {
            Text(lineDiff)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 260)
          .padding(.top, 6)
        }
        .font(.caption.weight(.medium))
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
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}
