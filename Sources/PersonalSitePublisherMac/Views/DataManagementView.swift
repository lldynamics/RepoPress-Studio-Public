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

@MainActor
struct DataManagementView: View {
  @ObservedObject var store: WorkbenchStore
  let rssStore: RSSReaderStore?
  @ObservedObject var launchCoordinator: WorkbenchLaunchCoordinator

  @AppStorage("dataManagementRequestedSection")
  private var requestedSectionRawValue = DataManagementSection.drafts.rawValue

  private var selectedSection: Binding<DataManagementSection> {
    Binding(
      get: {
        DataManagementSection(rawValue: requestedSectionRawValue) ?? .drafts
      },
      set: { requestedSectionRawValue = $0.rawValue }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      sectionPicker
        .padding(.horizontal, WorkbenchSpacing.page)
        .padding(.vertical, WorkbenchSpacing.card)

      Divider()

      sectionContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .accessibilityIdentifier("data-management-settings")
  }

  private var sectionPicker: some View {
    Picker(String(localized: "数据管理范围"), selection: selectedSection) {
      ForEach(DataManagementSection.allCases) { section in
        Label(section.title, systemImage: section.systemImage)
          .tag(section)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .help(selectedSection.wrappedValue.subtitle)
    .accessibilityLabel("数据管理范围")
  }

  @ViewBuilder
  private var sectionContent: some View {
    switch selectedSection.wrappedValue {
    case .drafts:
      DraftLifecycleCenterView(store: store, presentation: .embedded)
    case .backup:
      if let rssStore {
        Form {
          StorageManagementView(
            store: store,
            rssStore: rssStore,
            coordinator: launchCoordinator,
            backupScheduler: store.workspaceBackupScheduler,
            presentation: .embedded
          )
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("data-management-backup")
      } else {
        EmptyStateView(
          title: "备份管理暂不可用",
          message: "请先在主窗口完成数据文件夹设置。",
          systemImage: "externaldrive"
        )
      }
    case .migration:
      ContentMigrationAssistantView(store: store)
        .accessibilityIdentifier("data-management-migration")
    }
  }
}
