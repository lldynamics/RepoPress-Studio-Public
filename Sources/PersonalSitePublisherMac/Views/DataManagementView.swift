import PublishingWorkbenchCore
import SwiftUI

enum DataManagementSection: String, CaseIterable, Identifiable {
  case drafts
  case backup
  case migration

  var id: String { rawValue }

  var title: String {
    switch self {
    case .drafts:
      return String(localized: "草稿生命周期")
    case .backup:
      return String(localized: "备份与恢复")
    case .migration:
      return String(localized: "内容迁移")
    }
  }

  var systemImage: String {
    switch self {
    case .drafts:
      return "clock.arrow.circlepath"
    case .backup:
      return "externaldrive"
    case .migration:
      return "arrow.triangle.2.circlepath.doc.on.clipboard"
    }
  }

  var subtitle: String {
    switch self {
    case .drafts:
      return String(localized: "版本、回收站、仓库待清理和草稿归属")
    case .backup:
      return String(localized: "创建、校验、恢复完整工作区并管理存储位置")
    case .migration:
      return String(localized: "导入外部内容并在写入前审阅转换计划")
    }
  }
}

enum DataManagementTaskPresentation: Equatable {
  case sheet
}

enum DataManagementTask: String, CaseIterable, Identifiable {
  case drafts
  case storage
  case backup
  case migration

  var id: String { rawValue }

  var title: String {
    switch self {
    case .drafts:
      return String(localized: "草稿与版本")
    case .storage:
      return String(localized: "存储与清理")
    case .backup:
      return String(localized: "备份与恢复")
    case .migration:
      return String(localized: "内容迁移")
    }
  }

  var subtitle: String {
    switch self {
    case .drafts:
      return String(localized: "查看版本历史、回收站、草稿归属和待清理的仓库文件。")
    case .storage:
      return String(localized: "查看空间占用，清理资料库数据，或更改存储位置。")
    case .backup:
      return String(localized: "创建、校验和恢复完整工作区，并管理自动备份。")
    case .migration:
      return String(localized: "导入 WordPress、RSS、Markdown 等内容，写入前先审阅转换计划。")
    }
  }

  var systemImage: String {
    switch self {
    case .drafts:
      return "clock.arrow.circlepath"
    case .storage:
      return "internaldrive"
    case .backup:
      return "externaldrive.badge.timemachine"
    case .migration:
      return "arrow.triangle.2.circlepath.doc.on.clipboard"
    }
  }

  var actionTitle: String {
    String(localized: "打开\(title)")
  }

  var presentation: DataManagementTaskPresentation { .sheet }

  init(destination: SettingsDataDestination) {
    switch destination {
    case .drafts:
      self = .drafts
    case .backup:
      self = .backup
    case .migration:
      self = .migration
    }
  }

  init(section: DataManagementSection) {
    switch section {
    case .drafts:
      self = .drafts
    case .backup:
      self = .backup
    case .migration:
      self = .migration
    }
  }
}

enum DataManagementLayout {
  static let minimumTaskCardWidth: CGFloat = 240
  static let gridSpacing = WorkbenchSpacing.card
}

@MainActor
struct DataManagementView: View {
  @ObservedObject var store: WorkbenchStore
  let rssStore: RSSReaderStore?
  @ObservedObject var launchCoordinator: WorkbenchLaunchCoordinator
  let navigationDestination: SettingsDestination?
  let navigationRequestID: UUID
  @ObservedObject private var backupScheduler: WorkspaceBackupScheduler
  @AppStorage("dataManagementRequestedSection")
  private var legacyRequestedSectionRawValue = ""
  @State private var presentedTask: DataManagementTask?

  init(
    store: WorkbenchStore,
    rssStore: RSSReaderStore?,
    launchCoordinator: WorkbenchLaunchCoordinator,
    navigationDestination: SettingsDestination?,
    navigationRequestID: UUID
  ) {
    self.store = store
    self.rssStore = rssStore
    self.launchCoordinator = launchCoordinator
    self.navigationDestination = navigationDestination
    self.navigationRequestID = navigationRequestID
    _backupScheduler = ObservedObject(wrappedValue: store.workspaceBackupScheduler)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.section) {
        overviewSection
        taskSection
      }
      .padding(WorkbenchSpacing.content)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .scrollIndicators(.automatic)
    // Match the horizontal content inset used by Form-backed Settings pages so
    // this page's native scroll view and visible thumb share the same trailing
    // content-panel edge.
    .padding(.horizontal, WorkbenchSpacing.content)
    .task(id: navigationRequestID) {
      presentRequestedTask()
    }
    .onAppear(perform: presentLegacyRequestedTaskIfNeeded)
    .onChange(of: legacyRequestedSectionRawValue) { _, _ in
      presentLegacyRequestedTaskIfNeeded()
    }
    .sheet(item: $presentedTask) { task in
      taskSheet(for: task)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("data-management-settings")
  }

  private var overviewSection: some View {
    GroupBox {
      LazyVGrid(
        columns: [
          GridItem(
            .adaptive(minimum: DataManagementLayout.minimumTaskCardWidth),
            spacing: DataManagementLayout.gridSpacing,
            alignment: .topLeading
          )
        ],
        alignment: .leading,
        spacing: DataManagementLayout.gridSpacing
      ) {
        overviewMetric(
          title: String(localized: "草稿"),
          value: store.drafts.count.formatted(),
          detail: String(localized: "工作台中的草稿"),
          systemImage: "doc.text"
        )
        overviewMetric(
          title: String(localized: "待恢复与清理"),
          value: pendingItemCount.formatted(),
          detail: pendingItemDetail,
          systemImage: pendingItemCount == 0 ? "checkmark.circle" : "exclamationmark.triangle"
        )
        overviewMetric(
          title: String(localized: "最近备份"),
          value: latestBackupValue,
          detail: latestBackupDetail,
          systemImage: backupScheduler.settings.lastBackupAt == nil
            ? "externaldrive"
            : "checkmark.shield"
        )
        overviewMetric(
          title: String(localized: "数据文件夹"),
          value: launchCoordinator.dataRootPath == nil
            ? String(localized: "待准备")
            : String(localized: "可用"),
          detail: launchCoordinator.dataRootPath == nil
            ? String(localized: "请先在主窗口完成设置")
            : String(localized: "位置已配置，可管理占用与备份"),
          systemImage: launchCoordinator.dataRootPath == nil
            ? "folder.badge.questionmark"
            : "folder.badge.checkmark"
        )
      }
      .padding(.top, 4)
    } label: {
      Label(String(localized: "数据概览"), systemImage: "chart.bar.doc.horizontal")
        .font(.workbenchSectionTitle)
    }
    .accessibilityIdentifier("data-management-overview")
  }

  private var taskSection: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.card) {
      VStack(alignment: .leading, spacing: 3) {
        Text("数据任务")
          .font(.workbenchSectionTitle)
        Text("每项任务会在单独界面中打开，设置页保持简洁。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }

      LazyVGrid(
        columns: [
          GridItem(
            .adaptive(minimum: DataManagementLayout.minimumTaskCardWidth),
            spacing: DataManagementLayout.gridSpacing,
            alignment: .topLeading
          )
        ],
        alignment: .leading,
        spacing: DataManagementLayout.gridSpacing
      ) {
        ForEach(DataManagementTask.allCases) { task in
          taskCard(task)
        }
      }
    }
    .accessibilityIdentifier("data-management-tasks")
  }

  private func overviewMetric(
    title: String,
    value: String,
    detail: String,
    systemImage: String
  ) -> some View {
    HStack(alignment: .top, spacing: WorkbenchSpacing.card) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(WorkbenchTheme.navigationSelection)
        .frame(width: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.workbenchMetricValue)
        Text(detail)
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(WorkbenchSpacing.card)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .combine)
  }

  private func taskCard(_ task: DataManagementTask) -> some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.card) {
      HStack(alignment: .top, spacing: WorkbenchSpacing.card) {
        Image(systemName: task.systemImage)
          .font(.title3)
          .foregroundStyle(WorkbenchTheme.navigationSelection)
          .frame(width: 24)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 4) {
          Text(task.title)
            .font(.workbenchCardTitle)
          Text(task.subtitle)
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Text(taskStatus(for: task))
        .font(.workbenchMetadata)
        .foregroundStyle(taskStatusColor(for: task))
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer(minLength: 0)
        Button {
          present(task)
        } label: {
          Label(task.actionTitle, systemImage: "arrow.up.forward.app")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("data-management-task-\(task.rawValue)")
      }
    }
    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
    .padding(WorkbenchSpacing.content)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(.primary.opacity(0.08), lineWidth: 1)
        .allowsHitTesting(false)
    }
  }

  private var pendingItemCount: Int {
    store.recycledDrafts.count + store.pendingRepositoryCleanupRequests.count
  }

  private var pendingItemDetail: String {
    let recycledDraftCount = store.recycledDrafts.count
    let repositoryCleanupCount = store.pendingRepositoryCleanupRequests.count
    return String(
      localized: "\(recycledDraftCount) 篇在回收站 · \(repositoryCleanupCount) 项仓库待清理"
    )
  }

  private var latestBackupValue: String {
    guard let lastBackupAt = backupScheduler.settings.lastBackupAt else {
      return String(localized: "尚无")
    }
    return lastBackupAt.formatted(date: .abbreviated, time: .shortened)
  }

  private var latestBackupDetail: String {
    if backupScheduler.invalidRecentBackupCount > 0 {
      return String(
        localized: "\(backupScheduler.invalidRecentBackupCount) 个自动备份校验失败"
      )
    }
    guard backupScheduler.settings.lastBackupAt != nil else {
      return String(localized: "建议创建并校验第一个工作区备份")
    }
    return String(localized: "最近成功备份已记录")
  }

  private func taskStatus(for task: DataManagementTask) -> String {
    switch task {
    case .drafts:
      return pendingItemDetail
    case .storage:
      return launchCoordinator.dataRootPath == nil
        ? String(localized: "数据文件夹尚未准备完成")
        : String(localized: "数据文件夹可用")
    case .backup:
      return backupScheduler.settings.lastBackupAt == nil
        ? String(localized: "尚无成功备份")
        : String(localized: "最近备份：\(latestBackupValue)")
    case .migration:
      return String(localized: "先生成预览，确认后才写入本地草稿")
    }
  }

  private func taskStatusColor(for task: DataManagementTask) -> Color {
    switch task {
    case .drafts where pendingItemCount > 0,
      .storage where launchCoordinator.dataRootPath == nil,
      .backup where backupScheduler.settings.lastBackupAt == nil:
      return WorkbenchTheme.warning
    default:
      return WorkbenchTheme.neutral
    }
  }

  private func presentRequestedTask() {
    guard case .data(let destination) = navigationDestination else { return }
    present(DataManagementTask(destination: destination))
  }

  private func presentLegacyRequestedTaskIfNeeded() {
    guard let section = DataManagementSection(rawValue: legacyRequestedSectionRawValue) else {
      return
    }
    legacyRequestedSectionRawValue = ""
    present(DataManagementTask(section: section))
  }

  private func present(_ task: DataManagementTask) {
    switch task.presentation {
    case .sheet:
      presentedTask = task
    }
  }

  @ViewBuilder
  private func taskSheet(for task: DataManagementTask) -> some View {
    switch task {
    case .drafts:
      DraftLifecycleCenterView(store: store, presentation: .standalone)
        .settingsThinRedScroller()
    case .storage, .backup:
      if let rssStore {
        DataManagementStorageTaskSheet(
          task: task,
          store: store,
          rssStore: rssStore,
          launchCoordinator: launchCoordinator,
          backupScheduler: backupScheduler
        )
      } else {
        DataManagementUnavailableTaskSheet(task: task)
          .settingsThinRedScroller()
      }
    case .migration:
      ContentMigrationAssistantView(store: store)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .settingsThinRedScroller()
    }
  }
}

@MainActor
private struct DataManagementStorageTaskSheet: View {
  let task: DataManagementTask
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var rssStore: RSSReaderStore
  @ObservedObject var launchCoordinator: WorkbenchLaunchCoordinator
  @ObservedObject var backupScheduler: WorkspaceBackupScheduler
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      taskHeader
      Divider()
      StorageManagementView(
        store: store,
        rssStore: rssStore,
        coordinator: launchCoordinator,
        backupScheduler: backupScheduler,
        presentation: .standalone,
        scope: task == .storage ? .storageAndCleanup : .backupAndRestore
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .settingsThinRedScroller()
    }
    .workbenchSheetSize(.wide)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("data-management-\(task.rawValue)-task")
  }

  private var taskHeader: some View {
    HStack(alignment: .top, spacing: WorkbenchSpacing.card) {
      Image(systemName: task.systemImage)
        .font(.title2)
        .foregroundStyle(WorkbenchTheme.navigationSelection)
        .frame(width: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(task.title)
          .font(.workbenchPageTitle)
        Text(task.subtitle)
          .font(.workbenchPageSubtitle)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: WorkbenchSpacing.content)

      Button("完成") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("data-management-\(task.rawValue)-task-close")
    }
    .padding(WorkbenchSpacing.page)
  }
}

private struct DataManagementUnavailableTaskSheet: View {
  let task: DataManagementTask
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(task.title, systemImage: task.systemImage)
          .font(.workbenchPageTitle)
        Spacer()
        Button("完成") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("data-management-\(task.rawValue)-task-close")
      }
      .padding(WorkbenchSpacing.page)

      Divider()

      EmptyStateView(
        title: "数据管理暂不可用",
        message: "请先在主窗口完成数据文件夹设置。",
        systemImage: "externaldrive"
      )
    }
    .workbenchSheetSize(.detail)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("data-management-\(task.rawValue)-task")
  }
}
