import PublishingWorkbenchCore
import SwiftUI

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
