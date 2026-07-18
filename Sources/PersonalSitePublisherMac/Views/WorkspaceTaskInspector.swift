import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskInspector: View {
  let section: WorkspaceSection
  @Binding var draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore
  let prioritizesChecks: Bool
  @State private var selectedTab: ArticleInspectorTab = .metadata

  init(
    section: WorkspaceSection,
    draft: Binding<ArticleDraft>,
    store: WorkbenchStore,
    prioritizesChecks: Bool = false
  ) {
    self.section = section
    _draft = draft
    self.store = store
    self.prioritizesChecks = prioritizesChecks
  }

  var body: some View {
    switch section {
    case .sync, .releaseHistory:
      RepositoryContextInspectorView(store: store)
    case .library:
      EmptyView()
    case .writing, .contentHealth, .images, .generalDrafts, .maintenance:
      ArticleInspectorTabs(
        selectedTab: $selectedTab,
        draft: $draft,
        store: store,
        availableTabs: availableTabs
      )
      .onAppear {
        selectedTab = initialTab(for: section)
      }
      .onChange(of: section) { _, newSection in
        selectedTab = initialTab(for: newSection)
      }
    case .siteStarter:
      SiteStarterInspectorView(state: SiteStarterInspectorState(store: store))
    }
  }

  private func initialTab(for section: WorkspaceSection) -> ArticleInspectorTab {
    if prioritizesChecks && availableTabs.contains(.checks) {
      return .checks
    }
    return ArticleInspectorTab.defaultTab(for: section)
  }

  private var availableTabs: [ArticleInspectorTab] {
    switch section {
    case .writing, .generalDrafts, .maintenance:
      return [.metadata, .seo]
    case .contentHealth:
      return [.checks]
    case .images:
      return [.images]
    case .sync, .releaseHistory:
      return []
    case .library:
      return []
    case .siteStarter:
      return [.metadata]
    }
  }
}

struct RepositoryContextInspectorView: View {
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "arrow.left.arrow.right")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("同步 Inspector")
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
          changedFilesSection
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(.bar)
    .accessibilityIdentifier("repository-context-inspector")
    .accessibilityLabel("同步 Inspector")
  }

  @ViewBuilder
  private var blockerSection: some View {
    let issues = store.repositoryReport?.preflightIssues ?? []
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
    } else if let readiness = store.localPublishReadiness,
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
  private var changedFilesSection: some View {
    let files = store.repositoryReport?.changedFiles ?? []
    inspectorCard(title: "文件变更", systemImage: "doc.text.magnifyingglass") {
      if files.isEmpty {
        Text("当前工作树没有变更。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(files.prefix(8)) { file in
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              WorkbenchPathIdentity(path: file.path)
              Spacer()
              Text(file.status)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
            if let lineDiff = file.lineDiff {
              Text(lineDiff)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(5)
            }
          }
          if file.id != files.prefix(8).last?.id {
            Divider()
          }
        }
      }
    }
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
