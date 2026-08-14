import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsTabContentFactory {
  @ViewBuilder
  static func makeContent(for tab: SettingsTab, context: SettingsContext) -> some View {
    switch tab {
    case .configurationStatus:
      SettingsConfigurationStatusView(context: context)
    case .defaultRules:
      DefaultRuleSettingsView(
        store: context.store,
        activeProfileBinding: context.activeProfileBinding,
        siteKindBinding: context.siteKindBinding,
        healthDestination: context.healthDestination,
        healthNavigationRequestID: context.healthNavigationRequestID,
        navigationDestination: context.navigationDestination,
        navigationRequestID: context.navigationRequestID
      )
    case .token:
      SettingsTokenTabFactory.make(context: context)
    case .ai:
      SettingsAITabFactory.make(context: context)
    case .appearance:
      AppearanceSettingsView(
        autoRunPreflightBinding: context.autoRunPreflightBinding,
        scanRepositoryOnLaunch: context.scanRepositoryOnLaunch
      )
    case .editor:
      EditorSettingsView()
    case .rss:
      if let rssStore = context.rssStore {
        RSSMaintenanceSettingsView(
          store: rssStore,
          allowsBackgroundRefresh: !context.store.isSafeMode
        )
      } else {
        EmptyStateView(
          title: "RSS 暂不可用",
          message: "请先在主窗口完成数据文件夹设置。",
          systemImage: "dot.radiowaves.left.and.right"
        )
      }
    case .privacy:
      SettingsPrivacyTabFactory.make(context: context)
    case .dataManagement:
      DataManagementView(
        store: context.store,
        rssStore: context.rssStore,
        launchCoordinator: context.launchCoordinator,
        navigationDestination: context.navigationDestination,
        navigationRequestID: context.navigationRequestID
      )
    }
  }
}
