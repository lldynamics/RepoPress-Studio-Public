import PublishingWorkbenchCore
import SwiftUI

private struct WritingDraftListCache {
  var filteredDrafts: [ArticleDraft] = []
  var visibleDraftIDs: [UUID] = []
  var visibleDraftSignatures: [UUID: DraftTaskQueueState.Signature] = [:]
  var searchText = ""
  var filter: DraftListFilter = .all
  var activeProfileID: UUID?
  var draftTaskQueueStateVersion = 0
  var lastLoadMoreTriggerCount = -1

  mutating func resetPaginationTrigger() {
    lastLoadMoreTriggerCount = -1
  }
}

struct WorkspaceTopBar: View {
  @ObservedObject var store: WorkbenchStore
  let isCompact: Bool

  private var profileSelection: Binding<UUID> {
    Binding(
      get: { store.activeProfileID },
      set: { store.selectProfile($0) }
    )
  }

  var body: some View {
    HStack(spacing: isCompact ? 10 : 16) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Picker("站点", selection: profileSelection) {
            ForEach(store.profiles) { profile in
              Text(profile.name).tag(profile.id)
            }
          }
          .labelsHidden()
          .accessibilityLabel("当前站点 Profile")
          .accessibilityValue(store.activeProfile.name)

          PublishingStatusPopover(store: store)
        }

        Label(store.activeProfile.siteKind.displayName, systemImage: "globe")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(width: isCompact ? 210 : 280, alignment: .leading)

      Spacer(minLength: 12)

      Label(compactSectionTitleKey, systemImage: compactSectionSystemImage)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Spacer(minLength: 12)

      Spacer(minLength: isCompact ? 6 : 12)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private var compactSectionMenu: some View {
    Menu {
      ForEach(WorkspaceNavigationPresentation.topBarItems) { item in
        Button {
          store.selectSection(item.section)
        } label: {
          Label(workspaceNavigationLocalizedKey(item.displayNameLocalizationKey), systemImage: item.systemImage)
        }
      }

      Divider()

      siteToolsMenu
    } label: {
      Label(compactSectionTitleKey, systemImage: compactSectionSystemImage)
        .lineLimit(1)
    }
    .accessibilityLabel("工作区导航")
    .accessibilityValue(workspaceNavigationLocalizedString(compactSectionTitleKeyString))
    .help("窗口较窄时，将工作区导航收进菜单。")
  }

  private var siteToolsMenu: some View {
    Menu {
      ForEach(WorkspaceNavigationPresentation.secondaryEntryItems) { item in
        Button {
          store.selectSection(item.section)
        } label: {
          Label(workspaceNavigationLocalizedKey(item.displayNameLocalizationKey), systemImage: item.systemImage)
        }
      }
    } label: {
      Label("站点工具", systemImage: "wrench.and.screwdriver")
    }
    .accessibilityLabel("站点工具")
    .accessibilityValue(WorkspaceNavigationPresentation.secondaryEntryItems.map { workspaceNavigationLocalizedString($0.displayNameLocalizationKey) }.joined(separator: "、"))
    .help("建站、素材库和维护")
  }

  private var compactSectionTitleKey: LocalizedStringKey {
    workspaceNavigationLocalizedKey(compactSectionTitleKeyString)
  }

  private var compactSectionTitleKeyString: String {
    WorkspaceNavigationItem(section: store.selectedSection).displayNameLocalizationKey
  }

  private var compactSectionSystemImage: String {
    WorkspaceNavigationItem(section: store.selectedSection).systemImage
  }

  private func runTopBarPreflight() {
    store.runPreflight()
    store.selectSection(.contentHealth)
  }

  private func handleStatusLightClick(_ status: PublishingStatusLight) {
    switch status {
    case .noRepository:
      store.selectSection(.sync)
      if let url = RepositorySelectionPanel.chooseDirectory() {
        Task {
          await store.repository.rememberRootAsync(url)
        }
      }
    case .localChanges:
      store.selectSection(.sync)
      store.setPublishActionMessage("本地有变更，请从同步工作区审阅 Diff 后再发布。")
    case .remoteChanges:
      store.selectSection(.sync)
      store.setPublishActionMessage("已打开同步工作区，请审阅远端变更队列。")
    case .checksBlocked, .checksNeedReview, .needsCheck:
      runTopBarPreflight()
    case .checksPassed:
      store.selectSection(.sync)
      store.setPublishActionMessage("检查已通过；请从系统工具栏的“发布”打开发布流程。")
    case .deploying, .online:
      store.selectSection(.releaseHistory)
    }
  }
}

private enum PublishingStatusLight {
  case noRepository
  case localChanges(count: Int)
  case remoteChanges(count: Int)
  case checksBlocked(count: Int)
  case checksNeedReview(count: Int)
  case needsCheck
  case checksPassed
  case deploying
  case online

  @MainActor
  init(store: WorkbenchStore) {
    if store.activeProfile.purpose.requiresRepositoryReadiness,
       store.activeProfile.localRepositoryRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      self = .noRepository
      return
    }

    if let report = store.repositoryReport, !report.remoteChangedFiles.isEmpty {
      self = .remoteChanges(count: report.remoteChangedFiles.count)
      return
    }

    if let report = store.repositoryReport, !report.changedFiles.isEmpty {
      self = .localChanges(count: report.changedFiles.count)
      return
    }

    if store.activeProfileReleaseLedger.entries.contains(where: { entry in
      entry.status == .deploying || entry.status == .pendingDeployment
    }) {
      self = .deploying
      return
    }

    if store.activeProfileReleaseLedger.entries.contains(where: { entry in
      entry.status == .succeeded
    }) {
      self = .online
      return
    }

    guard store.selectedDraft != nil else {
      self = .needsCheck
      return
    }

    let readiness = store.localPublishReadiness
    let blockingIssueCount = max(
      store.preflightIssues.filter { $0.severity == .error }.count,
      readiness?.blockingIssueCount ?? 0
    )
    if blockingIssueCount > 0 {
      self = .checksBlocked(count: blockingIssueCount)
      return
    }

    let warningIssueCount = max(
      store.preflightIssues.filter { $0.severity == .warning }.count,
      readiness?.warningIssues.count ?? 0
    )
    if warningIssueCount > 0 || readiness?.writeReadiness == .needsReview || readiness?.commitReadiness == .needsReview {
      self = .checksNeedReview(count: max(warningIssueCount, 1))
      return
    }

    guard let readiness,
          readiness.writeReadiness != .blocked,
          readiness.commitReadiness != .blocked else {
      self = .needsCheck
      return
    }

    self = .checksPassed
  }

  var title: String {
    switch self {
    case .noRepository:
      return "未选仓库"
    case .localChanges:
      return "有本地变更"
    case .remoteChanges:
      return "有远端变更"
    case .checksBlocked:
      return "检查阻断"
    case .checksNeedReview:
      return "需确认"
    case .needsCheck:
      return "待检查"
    case .checksPassed:
      return "检查通过"
    case .deploying:
      return "部署中"
    case .online:
      return "已上线"
    }
  }

  var systemImage: String {
    switch self {
    case .noRepository:
      return "externaldrive.badge.questionmark"
    case .localChanges:
      return "arrow.triangle.2.circlepath"
    case .remoteChanges:
      return "arrow.down.doc"
    case .checksBlocked:
      return "xmark.octagon"
    case .checksNeedReview:
      return "exclamationmark.triangle"
    case .needsCheck:
      return "checklist"
    case .checksPassed:
      return "checkmark.circle"
    case .deploying:
      return "hourglass"
    case .online:
      return "checkmark.seal"
    }
  }

  var color: Color {
    switch self {
    case .noRepository:
      return .secondary
    case .localChanges:
      return .orange
    case .remoteChanges:
      return .red
    case .checksBlocked:
      return .red
    case .checksNeedReview:
      return .orange
    case .needsCheck:
      return .secondary
    case .checksPassed:
      return .green
    case .deploying:
      return .blue
    case .online:
      return .green
    }
  }

  var statusDescription: String {
    switch self {
    case .noRepository:
      return "当前站点还没有选择本地仓库。"
    case let .localChanges(count):
      return "本地工作树有 \(count) 个文件变更，发布前建议先审阅 diff。"
    case let .remoteChanges(count):
      return "远端有 \(count) 个文件变更，发布前建议先同步确认。"
    case let .checksBlocked(count):
      return "当前文章有 \(count) 个发布阻断项，请先处理检查结果。"
    case let .checksNeedReview(count):
      return "当前文章有 \(count) 个需要确认的发布提示，请先审阅检查结果或 diff。"
    case .needsCheck:
      return "请选择文章并运行发布前检查。"
    case .checksPassed:
      return "当前文章检查和发布 readiness 均已通过。"
    case .deploying:
      return "最近发布记录仍在等待部署或部署检查。"
    case .online:
      return "最近发布记录已经通过部署检查。"
    }
  }

  var tooltipText: String {
    "\(statusDescription) \(actionHint)"
  }

  var accessibilityValue: String {
    switch self {
    case .noRepository:
      return "未选择本地仓库"
    case let .localChanges(count):
      return "\(count) 个本地文件变更"
    case let .remoteChanges(count):
      return "\(count) 个远端文件变更"
    case let .checksBlocked(count):
      return "\(count) 个阻断项"
    case let .checksNeedReview(count):
      return "\(count) 个待确认项"
    case .needsCheck:
      return "等待运行发布检查"
    case .checksPassed:
      return "发布检查已通过"
    case .deploying:
      return "部署检查进行中"
    case .online:
      return "最近发布已上线"
    }
  }

  var actionHelpText: String {
    actionHint
  }

  var actionHint: String {
    switch self {
    case .noRepository:
      return "选择本地仓库"
    case .localChanges:
      return "打开发布流程"
    case .remoteChanges:
      return "打开同步队列"
    case .checksBlocked, .checksNeedReview, .needsCheck:
      return "打开内容健康检查"
    case .checksPassed:
      return "打开发布流程"
    case .deploying, .online:
      return "打开发布记录"
    }
  }
}

private enum PublishingStatusArea {
  case repository
  case draft
  case deployment

  var title: String {
    switch self {
    case .repository:
      return "仓库"
    case .draft:
      return "当前文章"
    case .deployment:
      return "部署历史"
    }
  }

  var systemImage: String {
    switch self {
    case .repository:
      return "externaldrive"
    case .draft:
      return "doc.text"
    case .deployment:
      return "clock.arrow.circlepath"
    }
  }

  var actionTitle: String {
    switch self {
    case .repository:
      return "打开同步"
    case .draft:
      return "打开检查"
    case .deployment:
      return "打开发布记录"
    }
  }
}

private struct PublishingStatusPopoverItem: Identifiable {
  let area: PublishingStatusArea
  let value: String
  let detail: String
  let statusImage: String
  let color: Color

  var id: String { area.title }
}

private struct PublishingStatusPopover: View {
  @ObservedObject var store: WorkbenchStore
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      Label("状态", systemImage: "chart.bar")
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(WorkbenchBackgroundStyle.badge, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help("查看仓库、当前文章和部署历史的独立状态")
    .accessibilityLabel("工作台状态")
    .accessibilityValue("仓库、当前文章和部署历史")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 0) {
        Label("工作台状态", systemImage: "chart.bar")
          .font(.headline)
          .padding(.horizontal, 14)
          .padding(.vertical, 12)

        Divider()

        ForEach(statusItems) { item in
          statusRow(item)
          if item.id != statusItems.last?.id {
            Divider()
              .padding(.leading, 14)
          }
        }
      }
      .frame(width: 360)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("工作台状态详情")
    }
  }

  private var statusItems: [PublishingStatusPopoverItem] {
    [repositoryStatus, draftStatus, deploymentStatus]
  }

  private var repositoryStatus: PublishingStatusPopoverItem {
    let area = PublishingStatusArea.repository
    if store.activeProfile.purpose.requiresRepositoryReadiness,
       store.activeProfile.localRepositoryRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return PublishingStatusPopoverItem(
        area: area,
        value: "未配置",
        detail: "当前站点尚未选择本地仓库。",
        statusImage: "externaldrive.badge.questionmark",
        color: .secondary
      )
    }

    guard let report = store.repositoryReport else {
      return PublishingStatusPopoverItem(
        area: area,
        value: "待扫描",
        detail: "尚未读取当前仓库状态。",
        statusImage: "arrow.clockwise",
        color: .secondary
      )
    }

    if !report.remoteChangedFiles.isEmpty {
      return PublishingStatusPopoverItem(
        area: area,
        value: "远端有 \(report.remoteChangedFiles.count) 项变化",
        detail: "同步前请审阅远端变更队列。",
        statusImage: "arrow.down.doc",
        color: .red
      )
    }

    if !report.changedFiles.isEmpty {
      return PublishingStatusPopoverItem(
        area: area,
        value: "本地有 \(report.changedFiles.count) 项变化",
        detail: "发布前请审阅本地 Diff。",
        statusImage: "arrow.triangle.2.circlepath",
        color: .orange
      )
    }

    return PublishingStatusPopoverItem(
      area: area,
      value: report.syncStatusTitle,
      detail: report.rootPath,
      statusImage: "checkmark.circle",
      color: .green
    )
  }

  private var draftStatus: PublishingStatusPopoverItem {
    let area = PublishingStatusArea.draft
    guard let draft = store.selectedDraft else {
      return PublishingStatusPopoverItem(
        area: area,
        value: "未选择文章",
        detail: "选择文章后可查看其发布检查状态。",
        statusImage: "doc.badge.questionmark",
        color: .secondary
      )
    }

    let issues = store.preflightIssues(for: draft)
    let blockingCount = max(
      issues.filter { $0.severity == .error }.count,
      store.localPublishReadiness?.blockingIssueCount ?? 0
    )
    if blockingCount > 0 {
      return PublishingStatusPopoverItem(
        area: area,
        value: "\(blockingCount) 个阻断项",
        detail: draft.title.nilIfEmpty ?? "当前文章存在发布阻断项。",
        statusImage: "xmark.octagon",
        color: .red
      )
    }

    let warningCount = max(
      issues.filter { $0.severity == .warning }.count,
      store.localPublishReadiness?.warningIssues.count ?? 0
    )
    if warningCount > 0 {
      return PublishingStatusPopoverItem(
        area: area,
        value: "\(warningCount) 个待确认项",
        detail: draft.title.nilIfEmpty ?? "当前文章需要审阅发布提示。",
        statusImage: "exclamationmark.triangle",
        color: .orange
      )
    }

    guard let readiness = store.localPublishReadiness,
          readiness.writeReadiness != .blocked,
          readiness.commitReadiness != .blocked else {
      return PublishingStatusPopoverItem(
        area: area,
        value: "待运行检查",
        detail: draft.title.nilIfEmpty ?? "请运行发布前检查。",
        statusImage: "checklist",
        color: .secondary
      )
    }

    return PublishingStatusPopoverItem(
      area: area,
      value: "检查通过",
      detail: draft.title.nilIfEmpty ?? "当前文章已具备写入和提交条件。",
      statusImage: "checkmark.circle",
      color: .green
    )
  }

  private var deploymentStatus: PublishingStatusPopoverItem {
    let area = PublishingStatusArea.deployment
    let entries = store.activeProfileReleaseLedger.entries
    guard !entries.isEmpty else {
      return PublishingStatusPopoverItem(
        area: area,
        value: "暂无发布记录",
        detail: "远端发布后会在这里显示部署检查结果。",
        statusImage: "clock",
        color: .secondary
      )
    }

    if let failedEntry = entries.first(where: { $0.status == .failed || $0.status == .pendingRemoteRecovery || $0.status == .pendingRetry }) {
      return PublishingStatusPopoverItem(
        area: area,
        value: failedEntry.status.displayName,
        detail: failedEntry.statusMessage,
        statusImage: failedEntry.status.systemImage,
        color: .red
      )
    }

    if let pendingEntry = entries.first(where: { $0.status == .pendingDeployment || $0.status == .deploying }) {
      return PublishingStatusPopoverItem(
        area: area,
        value: pendingEntry.status.displayName,
        detail: pendingEntry.statusMessage,
        statusImage: pendingEntry.status.systemImage,
        color: .blue
      )
    }

    if let latestEntry = entries.first {
      return PublishingStatusPopoverItem(
        area: area,
        value: latestEntry.status.displayName,
        detail: latestEntry.statusMessage,
        statusImage: latestEntry.status.systemImage,
        color: latestEntry.status == .succeeded ? .green : .secondary
      )
    }

    return PublishingStatusPopoverItem(
      area: area,
      value: "待检查",
      detail: "尚未记录部署检查结果。",
      statusImage: "clock",
      color: .secondary
    )
  }

  private func statusRow(_ item: PublishingStatusPopoverItem) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: item.area.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 3) {
        Text(item.area.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Label(item.value, systemImage: item.statusImage)
          .font(.callout.weight(.medium))
          .foregroundStyle(item.color)
          .lineLimit(1)

        Text(item.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
      }

      Spacer(minLength: 8)

      Button(item.area.actionTitle) {
        open(item.area)
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(item.area.title)
    .accessibilityValue(item.value)
  }

  private func open(_ area: PublishingStatusArea) {
    isPresented = false
    switch area {
    case .repository:
      store.selectSection(.sync)
    case .draft:
      store.runPreflight()
      store.selectSection(.contentHealth)
    case .deployment:
      store.selectSection(.releaseHistory)
    }
  }
}

private extension ReleaseLedgerEntry {
  @MainActor
  func matchesActiveProfile(_ store: WorkbenchStore) -> Bool {
    record.siteProfileID == nil || record.siteProfileID == store.activeProfileID
  }
}

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

struct WorkspaceRail: View {
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    VStack(spacing: 6) {
      ForEach(WorkspaceSection.allCases) { section in
        Button {
          store.selectSection(section)
        } label: {
          Image(systemName: section.systemImage)
            .frame(width: 30, height: 30)
            .foregroundStyle(store.selectedSection == section ? Color.accentColor : Color.secondary)
            .background {
              if store.selectedSection == section {
                RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
                  .fill(Color.accentColor.opacity(WorkbenchOpacity.accentBackground))
              }
            }
        }
        .buttonStyle(.plain)
        .help(workspaceNavigationLocalizedString(section.displayNameLocalizationKey))
        .accessibilityLabel(workspaceNavigationLocalizedString(section.displayNameLocalizationKey))
        .accessibilityValue(store.selectedSection == section ? "当前工作区" : "")
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, 10)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("工作区导航")
  }
}

struct WorkspaceContextSidebar: View {
  @ObservedObject var store: WorkbenchStore
  let isCompact: Bool
  @Binding var contentHealthFilter: ContentHealthContextFilter
  @Binding var repositoryContextStage: RepositoryContextStage

  var body: some View {
    switch store.selectedSection.contextSidebarMode {
    case .writingDrafts:
      WritingDraftColumn(store: store, isCompact: isCompact)
    case .contentHealthFilters:
      contentHealthFilters
    case .repositoryStages:
      repositoryStages
    case .none:
      EmptyView()
    }
  }

  private var contentHealthFilters: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(workspaceNavigationLocalizedKey("workspace.contentHealth"))
        .font(.headline)
        .padding(.horizontal, 12)
        .padding(.top, 12)

      contextButton("全站发布检查", systemImage: "checklist", isSelected: contentHealthFilter == .overview) {
        contentHealthFilter = .overview
      }
      contextButton("公开风险", systemImage: "exclamationmark.shield", isSelected: contentHealthFilter == .publicRisks) {
        contentHealthFilter = .publicRisks
      }
      contextButton("AI 修复队列", systemImage: "sparkles", isSelected: contentHealthFilter == .aiFixes) {
        contentHealthFilter = .aiFixes
      }
      contextButton("站点级问题", systemImage: "globe.badge.chevron.backward", isSelected: contentHealthFilter == .siteIssues) {
        contentHealthFilter = .siteIssues
      }
      contextButton("文章级问题", systemImage: "doc.badge.gearshape", isSelected: contentHealthFilter == .draftIssues) {
        contentHealthFilter = .draftIssues
      }
      contextButton("站点维护", systemImage: "wrench.and.screwdriver", isSelected: contentHealthFilter == .maintenance) {
        contentHealthFilter = .maintenance
      }

      Spacer()
    }
    .background(.bar)
    .accessibilityLabel("内容健康筛选")
  }

  private var repositoryStages: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(workspaceNavigationLocalizedKey("workspace.sync"))
        .font(.headline)
        .padding(.horizontal, 12)
        .padding(.top, 12)

      contextButton("本地仓库", systemImage: "externaldrive", isSelected: repositoryContextStage == .overview) {
        repositoryContextStage = .overview
      }
      if !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty {
        contextButton("变更", systemImage: "arrow.left.arrow.right", isSelected: repositoryContextStage == .changes) {
          repositoryContextStage = .changes
        }
        contextButton("写入与发布", systemImage: "paperplane", isSelected: repositoryContextStage == .publishing) {
          repositoryContextStage = .publishing
        }
        contextButton("自动化", systemImage: "arrow.triangle.2.circlepath", isSelected: repositoryContextStage == .automation) {
          repositoryContextStage = .automation
        }
        contextButton("本地预览", systemImage: "play.rectangle", isSelected: repositoryContextStage == .preview) {
          repositoryContextStage = .preview
        }
      }

      Spacer()
    }
    .background(.bar)
    .accessibilityLabel("同步阶段导航")
  }

  private func contextButton(
    _ title: LocalizedStringKey,
    systemImage: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
          if isSelected {
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
              .fill(Color.accentColor.opacity(WorkbenchOpacity.accentBackground))
          }
        }
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
    .padding(.horizontal, 8)
  }
}

  struct WritingDraftColumn: View {
    @ObservedObject var store: WorkbenchStore
    let isCompact: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var filter: DraftListFilter = .all
    @State private var density: WritingDraftDensity = .compact
    @State private var isDraftListLoading = false
    @State private var draftListLoadingNonce = 0
    @State private var visibleDraftCount = 0
    @State private var filteredDraftCount = 0
    @State private var draftCountDelta: Int?
    @State private var isDraftCountPunching = false
    @State private var draftListLoadingTask: Task<Void, Never>?
    @State private var draftCountBadgeTask: Task<Void, Never>?
    @State private var draftFilterDebounceTask: Task<Void, Never>?
    @State private var draftListLimit: Int = 60
    @State private var debouncedSearchText = ""
    @State private var debouncedFilter: DraftListFilter = .all
    @State private var draftListCache = WritingDraftListCache()
    private let draftLoadMorePrefetchThreshold = 15
    @FocusState private var isSearchFieldFocused: Bool
    @State private var draftPendingDeletion: ArticleDraft?

  private var draftSelection: Binding<UUID?> {
    Binding(
      get: { store.selectedDraftID },
      set: { store.selectDraft($0) }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      writingHeader
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      Divider()

      draftList

      Divider()

      statusFooter
        .padding(12)
    }
    .background(.bar)
    .focusedSceneValue(\.writingDraftCommandActions, writingDraftCommandActions)
    .confirmationDialog(
      "删除文章？",
      isPresented: deleteConfirmationPresented,
      titleVisibility: .visible,
      presenting: draftPendingDeletion
    ) { draft in
      Button("删除文章", role: .destructive) {
        store.deleteDraft(id: draft.id)
        draftPendingDeletion = nil
      }
      Button("取消", role: .cancel) {
        draftPendingDeletion = nil
      }
    } message: { draft in
      Text("这会从工作台移除「\(draft.title.nilIfEmpty ?? "未命名文章")」，不会直接删除本地仓库里的文件。")
    }
  }

  private var writingHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text("写作")
            .font(.headline)
          HStack(spacing: 6) {
            Text("\(filteredDraftCount) / \(visibleDraftCount) 篇")
              .font(.caption)
              .foregroundStyle(.secondary)

            if let delta = draftCountDelta {
              Text(delta > 0 ? "+\(delta)" : "\(delta)")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(delta > 0 ? .green : .red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((delta > 0 ? Color.green : Color.red).opacity(WorkbenchOpacity.accentBackground), in: Capsule())
                .scaleEffect(isDraftCountPunching ? 1.06 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDraftCountPunching)
                .transition(.scale.combined(with: .opacity))
            }
          }
          .lineLimit(1)
        }

        Spacer()

        if isDraftListLoading && store.visibleDrafts.isEmpty {
          ProgressView()
            .controlSize(.small)
            .help("加载草稿中…")
        }

        Spacer(minLength: 8)

        Button(role: .destructive) {
          requestDeleteSelectedDraft()
        } label: {
          Label("删除文章", systemImage: "trash")
        }
        .labelStyle(.iconOnly)
        .disabled(selectedDraftForDeletion == nil)
        .help("删除选中文章")
        .accessibilityLabel("删除选中文章")

      }
    }
  }

  private var draftListToolbar: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .font(.footnote)

        TextField("搜索草稿", text: $searchText)
          .textFieldStyle(.plain)
          .focused($isSearchFieldFocused)
          .accessibilityLabel("搜索草稿")
          .accessibilityValue(searchText.nilIfEmpty ?? "未输入")

        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("清除搜索")
          .accessibilityLabel("清除草稿搜索")
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))

      HStack(spacing: 6) {
        if isCompact {
          draftFilterMenu
        } else {
          ForEach(DraftListFilter.primaryFilters) { candidate in
            Button(candidate.displayName) {
              filter = candidate
            }
            .buttonStyle(.bordered)
            .tint(filter == candidate ? .accentColor : .secondary)
            .controlSize(.small)
          }

          Menu {
            ForEach(DraftListFilter.overflowFilters) { candidate in
              filterButton(candidate)
            }
          } label: {
            Label(overflowFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
          }
          .controlSize(.small)
          .accessibilityLabel("更多草稿筛选")
          .accessibilityValue(filter.displayName)
        }

        Spacer(minLength: 0)

        Menu {
          Picker("列表密度", selection: $density) {
            ForEach(WritingDraftDensity.allCases) { option in
              Text(option.displayName).tag(option)
            }
          }
        } label: {
          Image(systemName: density == .compact ? "line.3.horizontal" : "rectangle.3.group")
        }
        .menuStyle(.borderlessButton)
        .help("列表密度：\(density.displayName)")
        .accessibilityLabel("草稿列表密度")
        .accessibilityValue(density.displayName)
      }
    }
  }

  private var overflowFilterLabel: String {
    DraftListFilter.primaryFilters.contains(filter) ? "更多" : filter.displayName
  }

  private var draftFilterMenu: some View {
    Menu {
      ForEach(DraftListFilter.allCases) { candidate in
        filterButton(candidate)
      }
    } label: {
      Label(filter.displayName, systemImage: "line.3.horizontal.decrease.circle")
        .lineLimit(1)
    }
    .controlSize(.small)
    .accessibilityLabel("草稿筛选")
    .accessibilityValue(filter.displayName)
    .help("筛选草稿")
  }

  @ViewBuilder
  private func filterButton(_ candidate: DraftListFilter) -> some View {
    Button {
      filter = candidate
    } label: {
      if filter == candidate {
        Label(candidate.displayName, systemImage: "checkmark")
      } else {
        Text(candidate.displayName)
      }
    }
  }

  private var paginatedDrafts: ArraySlice<ArticleDraft> {
    filteredDrafts.prefix(draftListLimit)
  }

  private var draftList: some View {
    List(selection: draftSelection) {
      if isDraftListLoading {
        ForEach(0..<skeletonPlaceholderCount, id: \.self) { _ in
          WritingDraftSkeletonRow(density: density)
            .listRowInsets(listRowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .allowsHitTesting(false)
        }
      } else {
        ForEach(Array(paginatedDrafts.enumerated()), id: \.1.id) { index, draft in
          draftRow(draft)
            .onAppear {
              maybeLoadMoreDraftsIfNeeded(
                currentIndex: index,
                visibleCount: paginatedDrafts.count
              )
            }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .safeAreaInset(edge: .top, spacing: 0) {
      draftListToolbar
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.clear)
        .overlay(alignment: .bottom) {
          Divider()
        }
    }
    .onDeleteCommand {
      requestDeleteSelectedDraft()
    }
    .onAppear {
      applyDraftFilterDebounce()
      refreshDraftListLoadingState()
      refreshDraftCounts()
    }
    .onChange(of: searchText) { _, _ in
      scheduleDraftFilterDebounce()
    }
    .onChange(of: filter) { _, _ in
      scheduleDraftFilterDebounce()
    }
    .onChange(of: density) { _, _ in
      resetDraftPagination()
    }
    .onChange(of: debouncedSearchText) { _, _ in
      resetDraftPagination()
      refreshFilteredDraftsCache()
      refreshDraftCounts()
    }
    .onChange(of: debouncedFilter) { _, _ in
      resetDraftPagination()
      refreshFilteredDraftsCache()
      refreshDraftCounts()
    }
    .onChange(of: store.draftTaskQueueStateVersion) { _, _ in
      refreshFilteredDraftsCache()
      refreshDraftCounts()
    }
    .onChange(of: store.repositoryReport) { _, _ in
      refreshFilteredDraftsCache()
      refreshDraftCounts()
    }
    .onChange(of: store.visibleDrafts) { _, newDrafts in
      if isDraftListLoading && !newDrafts.isEmpty {
        isDraftListLoading = false
        draftListLoadingTask?.cancel()
      }
      refreshFilteredDraftsCache()
      refreshDraftCounts()
      refreshDraftListLoadingState()
      resetDraftPagination()
    }
    .onChange(of: filteredDrafts.count) { _, newCount in
      if newCount == 0 {
        draftListLimit = 0
      } else if newCount < draftListLimit {
        draftListLimit = newCount
      }
      refreshDraftCounts()
    }
  }
  private func maybeLoadMoreDraftsIfNeeded(
    currentIndex: Int,
    visibleCount: Int
  ) {
    guard visibleCount < filteredDrafts.count else {
      return
    }
    let triggerIndex = max(0, visibleCount - draftLoadMorePrefetchThreshold)
    guard currentIndex >= triggerIndex else {
      return
    }
    guard draftListCache.lastLoadMoreTriggerCount != visibleCount else {
      return
    }
    draftListCache.lastLoadMoreTriggerCount = visibleCount
    loadMoreDrafts()
  }

  private func draftRow(_ draft: ArticleDraft) -> some View {
    WritingDraftRow(
      draft: draft,
      profile: store.activeProfile,
      display: store.privateContentDisplay(for: draft),
      density: density
    )
    .tag(draft.id)
    .listRowInsets(listRowInsets)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .contextMenu {
      draftContextMenu(for: draft)
    }
  }

  @ViewBuilder
  private func draftContextMenu(for draft: ArticleDraft) -> some View {
    Button {
      _ = store.focusDraft(draft.id, section: .writing)
    } label: {
      Label("编辑文章", systemImage: "square.and.pencil")
    }

    Button {
      _ = store.focusDraft(draft.id, section: .contentHealth)
    } label: {
      Label("查看发布检查", systemImage: "checklist")
    }

    Button {
      _ = store.focusDraft(draft.id, section: .images)
    } label: {
      Label("查看图片元数据", systemImage: "photo.on.rectangle")
    }

    Divider()

    Button {
      openWindow(value: draft.id)
    } label: {
      Label("在新窗口打开", systemImage: "macwindow.badge.plus")
    }

    Divider()

    Button(role: .destructive) {
      requestDelete(draft)
    } label: {
      Label("删除文章", systemImage: "trash")
    }
  }

  private func loadMoreDrafts() {
    let nextLimit = draftListLimit + draftPageStep
    let totalCount = filteredDrafts.count
    guard nextLimit <= totalCount else {
      draftListLimit = totalCount
      return
    }
    withAnimation(.easeInOut(duration: 0.15)) {
      draftListLimit = nextLimit
    }
  }

  private func scheduleDraftFilterDebounce() {
    draftFilterDebounceTask?.cancel()

    let nextSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let nextFilter = filter

    draftFilterDebounceTask = Task {
      do {
        try await Task.sleep(nanoseconds: 180_000_000)
      } catch {
        return
      }

      guard !Task.isCancelled else {
        return
      }

      await MainActor.run {
        let changedSearchText = nextSearchText
        let searchDidChange = changedSearchText != debouncedSearchText
        let filterDidChange = nextFilter != debouncedFilter
        if searchDidChange || filterDidChange {
          debouncedSearchText = changedSearchText
          debouncedFilter = nextFilter
        }
      }
    }
  }

  private func applyDraftFilterDebounce() {
    debouncedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    debouncedFilter = filter
    refreshFilteredDraftsCache()
    resetDraftPagination()
    refreshDraftCounts()
  }

  private func refreshDraftCounts() {
    refreshFilteredDraftsCache()
    let nextFilteredCount = filteredDrafts.count
    let nextVisibleCount = store.visibleDrafts.count
    let delta = nextVisibleCount - visibleDraftCount

    visibleDraftCount = nextVisibleCount
    filteredDraftCount = nextFilteredCount

    if delta != 0 {
      applyDraftCountDelta(delta)
    } else if draftCountDelta == nil {
      isDraftCountPunching = false
    }
  }

  private func applyDraftCountDelta(_ delta: Int) {
    draftCountDelta = delta
    isDraftCountPunching = true
    draftCountBadgeTask?.cancel()

    draftCountBadgeTask = Task {
      try? await Task.sleep(nanoseconds: 800_000_000)
      if Task.isCancelled {
        return
      }
      await MainActor.run {
        withAnimation(.easeInOut(duration: 0.2)) {
          isDraftCountPunching = false
          draftCountDelta = nil
        }
      }
    }
  }

  private var draftPageStep: Int {
    density == .compact ? 48 : 36
  }

  private func resetDraftPagination() {
    refreshFilteredDraftsCache()
    guard !filteredDrafts.isEmpty else {
      draftListLimit = 0
      draftListCache.resetPaginationTrigger()
      return
    }
    draftListLimit = min(filteredDrafts.count, draftPageStep)
    draftListCache.resetPaginationTrigger()
  }

  private var listRowInsets: EdgeInsets {
    EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
  }

  private func refreshDraftListLoadingState() {
    draftListLoadingTask?.cancel()
    draftListLoadingNonce += 1
    let nonce = draftListLoadingNonce

    guard store.visibleDrafts.isEmpty else {
      isDraftListLoading = false
      return
    }

    isDraftListLoading = true
    draftListLoadingTask = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 250_000_000)
      } catch {
        return
      }
      guard isDraftListLoading && nonce == draftListLoadingNonce else {
        return
      }
      isDraftListLoading = false
    }
  }

  private var filteredDrafts: [ArticleDraft] {
    draftListCache.filteredDrafts
  }

  private func refreshFilteredDraftsCache() {
    let visibleDrafts = store.visibleDrafts
    let visibleDraftIDs = visibleDrafts.map(\.id)
    let activeProfileID = store.activeProfile.id
    let taskQueueStates: [UUID: DraftTaskQueueState] = debouncedFilter.requiresTaskQueueState
      ? store.draftTaskQueueStates(for: visibleDrafts)
      : [:]
    let visibleDraftSignatures = Dictionary(
      uniqueKeysWithValues: visibleDrafts.map { draft in
        (
          draft.id,
          taskQueueStates[draft.id]?.signature ?? DraftTaskQueueState.Signature(
            draft: draft,
            profileID: activeProfileID,
            imageIssueCount: 0
          )
        )
      }
    )
    let query = debouncedSearchText
    let draftTaskQueueStateVersion = store.draftTaskQueueStateVersion

    guard visibleDraftIDs != draftListCache.visibleDraftIDs || visibleDraftSignatures != draftListCache.visibleDraftSignatures ||
      query != draftListCache.searchText || draftListCache.filter != debouncedFilter ||
      draftListCache.activeProfileID != activeProfileID ||
      draftListCache.draftTaskQueueStateVersion != draftTaskQueueStateVersion else {
      return
    }

    draftListCache.visibleDraftIDs = visibleDraftIDs
    draftListCache.visibleDraftSignatures = visibleDraftSignatures
    draftListCache.searchText = query
    draftListCache.filter = debouncedFilter
    draftListCache.activeProfileID = activeProfileID
    draftListCache.draftTaskQueueStateVersion = draftTaskQueueStateVersion
    let searchableDrafts = visibleDrafts.filter { draft in
      debouncedFilter.matches(draft, taskState: debouncedFilter.requiresTaskQueueState ? taskQueueStates[draft.id] : nil)
    }
    guard !query.isEmpty else {
      draftListCache.filteredDrafts = searchableDrafts
      return
    }

    draftListCache.filteredDrafts = searchableDrafts.filter { draft in
      store.matchesPrivacyProtectedDraftSearch(
        draft,
        query: query,
        profile: store.activeProfile
      )
    }
  }

  private var repositoryStatus: String {
    if let report = store.repositoryReport, !report.rootPath.isEmpty {
      return report.statusTitle
    }
    return store.activeProfile.purpose.repositoryStatusWhenUnconfigured
  }

  private var statusFooter: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(repositoryStatus, systemImage: store.activeProfile.purpose.systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      HStack(spacing: 5) {
        if store.hasUnsavedChanges {
          Image(systemName: "circle.fill")
            .font(.system(size: 5))
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
        }
        if store.hasUnsavedChanges {
          Text(store.lastSaveStatus)
            .font(.caption2)
            .foregroundStyle(.orange)
            .lineLimit(1)
        } else {
          Text(store.lastSaveStatus)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      .accessibilityLabel("保存状态")
      .accessibilityValue(store.lastSaveStatus)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { draftPendingDeletion != nil },
      set: { isPresented in
        if !isPresented {
          draftPendingDeletion = nil
        }
      }
    )
  }

  private var skeletonPlaceholderCount: Int {
    return density == .compact ? 10 : 8
  }

  private var selectedDraftForDeletion: ArticleDraft? {
    guard let selectedDraftID = store.selectedDraftID else {
      return nil
    }
    return store.visibleDrafts.first { $0.id == selectedDraftID }
  }

  private var writingDraftCommandActions: WritingDraftCommandActions {
    WritingDraftCommandActions(
      createDraft: {
        store.createDraft()
      },
      focusSearch: {
        isSearchFieldFocused = true
        if !searchText.isEmpty {
          searchText = ""
        }
      },
      selectPreviousDraft: {
        selectDraft(byOffset: -1)
      },
      selectNextDraft: {
        selectDraft(byOffset: 1)
      }
    )
  }

  private func requestDelete(_ draft: ArticleDraft) {
    draftPendingDeletion = draft
  }

  private func requestDeleteSelectedDraft() {
    guard let draft = selectedDraftForDeletion else {
      return
    }
    requestDelete(draft)
  }

  private func selectDraft(byOffset offset: Int) {
    guard !filteredDrafts.isEmpty else {
      return
    }

    guard let selectedDraftID = store.selectedDraftID,
          let currentIndex = filteredDrafts.firstIndex(where: { $0.id == selectedDraftID }) else {
      let targetIndex = offset >= 0 ? 0 : (filteredDrafts.count - 1)
      store.selectDraft(filteredDrafts[targetIndex].id)
      return
    }

    let targetIndex = currentIndex + offset
    if targetIndex < 0 {
      if let lastDraft = filteredDrafts.last {
        store.selectDraft(lastDraft.id)
      }
    } else if targetIndex >= filteredDrafts.count {
      if let firstDraft = filteredDrafts.first {
        store.selectDraft(firstDraft.id)
      }
    } else {
      store.selectDraft(filteredDrafts[targetIndex].id)
    }
  }
}

struct EditorCenterColumn: View {
  let store: WorkbenchStore
  let contentHealthFilter: ContentHealthContextFilter
  @Binding var repositoryContextStage: RepositoryContextStage
  @ObservedObject private var publishingState: WorkbenchPublishingFeatureFacade

  init(
    store: WorkbenchStore,
    contentHealthFilter: ContentHealthContextFilter,
    repositoryContextStage: Binding<RepositoryContextStage>
  ) {
    self.store = store
    self.contentHealthFilter = contentHealthFilter
    _repositoryContextStage = repositoryContextStage
    _publishingState = ObservedObject(wrappedValue: store.publishing)
  }

  var body: some View {
    Group {
      if publishingState.selectedSection == .ai {
        AIChatWorkspaceView(store: store)
      } else if publishingState.selectedSection == .sync {
        RepositoryWorkspaceView(store: store, stage: $repositoryContextStage)
      } else if publishingState.selectedSection == .images {
        ImageWorkbenchView(store: store)
      } else if publishingState.selectedSection == .contentHealth {
        ContentHealthDetailView(store: store, filter: contentHealthFilter)
      } else if publishingState.selectedSection == .releaseHistory {
        ReleaseHistoryDetailView(store: store)
      } else if publishingState.selectedSection == .siteStarter {
        SiteStarterWorkspaceView(store: store)
      } else if publishingState.selectedSection == .generalDrafts {
        GeneralDraftLibraryDetailView(store: store)
      } else if publishingState.selectedSection == .maintenance {
        SiteMaintenanceDetailView(store: store)
      } else if publishingState.selectedSection == .releaseReadiness {
        ReleaseQualityGateDetailView(store: store)
      } else if let fallbackDraft = publishingState.selectedDraft {
        let draft = Binding<ArticleDraft>(
          get: { publishingState.selectedDraft ?? fallbackDraft },
          set: { store.updateDraft($0) }
        )

        MacMarkdownComposerView(draft: draft, store: store)
      } else {
        EmptyStateView(
          title: "还没有草稿",
          message: "新建一篇文章后，中间区域只负责正文编辑；预览通过编辑器顶部按钮打开。",
          systemImage: "doc.badge.plus"
        )
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
    .onAppear {
      ensureDraftIfNeeded()
    }
    .onChange(of: publishingState.activeProfileID) { _, _ in
      ensureDraftIfNeeded()
    }
    .onChange(of: publishingState.selectedSection) { _, _ in
      ensureDraftIfNeeded()
    }
  }

  private func ensureDraftIfNeeded() {
    switch publishingState.selectedSection {
    case .siteStarter, .ai, .generalDrafts, .maintenance, .releaseReadiness:
      return
    case .writing, .sync, .contentHealth, .images, .releaseHistory:
      store.ensureEditableDraftSelected()
    }
  }
}

struct MetadataColumn: View {
  @ObservedObject var store: WorkbenchStore
  let prioritizesChecks: Bool

  init(store: WorkbenchStore, prioritizesChecks: Bool = false) {
    self.store = store
    self.prioritizesChecks = prioritizesChecks
  }

  var body: some View {
    if store.selectedSection == .ai {
      AIChatContextInspectorView(store: store)
    } else if store.selectedSection == .siteStarter {
      SiteStarterInspectorView(state: SiteStarterInspectorState(store: store))
    } else if store.selectedSection == .generalDrafts {
      GeneralDraftLibraryInspectorView(store: store)
    } else if store.selectedSection == .releaseReadiness {
      ReleaseQualityGateInspectorView(store: store)
    } else if let fallbackDraft = store.selectedDraft {
      let draft = Binding<ArticleDraft>(
        get: { store.selectedDraft ?? fallbackDraft },
        set: { store.updateDraft($0) }
      )
      WorkspaceTaskInspector(
        section: store.selectedSection,
        draft: draft,
        store: store,
        prioritizesChecks: prioritizesChecks
      )
    } else {
      EmptyStateView(
        title: "没有元数据",
        message: "选择或新建文章后，这里会显示 Front Matter、SEO、图片、检查和发布任务。",
        systemImage: "sidebar.right"
      )
      .background(.bar)
    }
  }
}

private enum DraftListFilter: String, CaseIterable, Identifiable {
  case all
  case draft
  case checkFailed
  case ready
  case published
  case imageIssues

  var id: String { rawValue }

  static let primaryFilters: [DraftListFilter] = [.all, .draft, .ready]
  static let overflowFilters: [DraftListFilter] = [.checkFailed, .published, .imageIssues]

  var displayName: String {
    switch self {
    case .all:
      return "全部任务"
    case .draft:
      return "待写作"
    case .checkFailed:
      return "检查失败"
    case .ready:
      return "待发布"
    case .published:
      return "已上线"
    case .imageIssues:
      return "有图片问题"
    }
  }

  var requiresTaskQueueState: Bool {
    switch self {
    case .checkFailed, .imageIssues:
      return true
    case .all, .draft, .ready, .published:
      return false
    }
  }

  func matches(
    _ draft: ArticleDraft,
    taskState: DraftTaskQueueState?
  ) -> Bool {
    switch self {
    case .all:
      return true
    case .draft:
      return draft.status == .draft
    case .checkFailed:
      return taskState?.hasPreflightErrors == true
    case .ready:
      return draft.status == .ready
    case .published:
      return draft.status == .published
    case .imageIssues:
      return taskState?.hasImageIssues == true
    }
  }
}

private enum WritingDraftDensity: String, CaseIterable, Identifiable {
  case compact
  case comfortable

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .compact:
      return "紧凑"
    case .comfortable:
      return "舒适"
    }
  }

  var titleFont: Font {
    switch self {
    case .compact:
      return .callout.weight(.medium)
    case .comfortable:
      return .body.weight(.medium)
    }
  }

  var metadataFont: Font {
    switch self {
    case .compact:
      return .caption2
    case .comfortable:
      return .caption
    }
  }

  var rowSpacing: CGFloat {
    switch self {
    case .compact:
      return 2
    case .comfortable:
      return 4
    }
  }

  var rowVerticalPadding: CGFloat {
    switch self {
    case .compact:
      return 3
    case .comfortable:
      return 5
    }
  }
}

private struct WritingDraftRow: View {
  let draft: ArticleDraft
  let profile: SiteProfile
  let display: PrivateContentDisplay
  let density: WritingDraftDensity

  var body: some View {
    VStack(alignment: .leading, spacing: density.rowSpacing) {
      HStack(spacing: 8) {
        Image(systemName: display.isMasked ? "lock.shield" : draft.status.systemImage)
          .foregroundStyle(.secondary)
          .frame(width: 16)

        VStack(alignment: .leading, spacing: 1) {
          Text(display.title)
            .font(density.titleFont)
            .lineLimit(1)

          Text("上次修改：\(draft.updatedAt.workbenchShortText) · \(draft.wordCount) 字 · \(draft.status.displayName)")
            .font(density.metadataFont)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }

      if density == .comfortable {
        Text(display.isMasked ? display.summary : profile.markdownPath(for: draft))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, density.rowVerticalPadding)
  }
}

private struct WritingDraftSkeletonRow: View {
  let density: WritingDraftDensity

  var body: some View {
    VStack(alignment: .leading, spacing: density.rowSpacing) {
      HStack(spacing: 8) {
        Circle()
          .frame(width: 16, height: 16)

        VStack(alignment: .leading, spacing: 1) {
          Text("标题占位")
            .font(density.titleFont)
            .lineLimit(1)

          Text("上次修改占位 · 0000 字 · 发布中")
            .font(density.metadataFont)
            .lineLimit(1)
        }
      }

      if density == .comfortable {
        Text("路径占位文本内容示例")
          .font(.caption)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, density.rowVerticalPadding)
    .redacted(reason: .placeholder)
    .foregroundStyle(.secondary)
  }
}

private extension ArticleDraft {
  var wordCount: Int {
    bodyMarkdown
      .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
      .filter { !$0.isEmpty }
      .count
  }
}
