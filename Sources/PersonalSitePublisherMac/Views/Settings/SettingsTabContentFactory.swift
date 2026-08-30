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
        WorkbenchStateView(
          presentation: WorkbenchStatePresentation(
            kind: .unavailable(
              reason: String(localized: "当前数据文件夹尚未准备完成。")
            ),
            icon: "dot.radiowaves.left.and.right"
          ),
          density: .compactPane,
          detail: "请先在主窗口完成数据文件夹设置。"
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
