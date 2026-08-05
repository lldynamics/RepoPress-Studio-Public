import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsContext {
  let store: WorkbenchStore
  let rssStore: RSSReaderStore?
  let launchCoordinator: WorkbenchLaunchCoordinator
  let activeProfileBinding: Binding<SiteProfile>
  let autoRunPreflightBinding: Binding<Bool>
  let scanRepositoryOnLaunch: Binding<Bool>
  let siteKindBinding: Binding<SiteKind>
  let healthDestination: SettingsConfigurationHealthDestination?
  let healthNavigationRequestID: UUID
  let selectConfigurationHealthDestination: (SettingsConfigurationHealthDestination) -> Void

  var actions: SettingsStoreActions {
    SettingsStoreActions(store: store)
  }
}

enum SettingsTab: Hashable, CaseIterable, Identifiable {
  case configurationStatus
  case defaultRules
  case token
  case ai
  case appearance
  case rss
  case privacy
  case dataManagement

  var id: String {
    switch self {
    case .configurationStatus:
      return "configurationStatus"
    case .defaultRules:
      return "defaultRules"
    case .token:
      return "token"
    case .ai:
      return "ai"
    case .appearance:
      return "appearance"
    case .rss:
      return "rss"
    case .privacy:
      return "privacy"
    case .dataManagement:
      return "dataManagement"
    }
  }

  var title: String {
    switch self {
    case .configurationStatus:
      return String(localized: "配置状态")
    case .defaultRules:
      return String(localized: "发布规则")
    case .token:
      return String(localized: "仓库与部署")
    case .ai:
      return String(localized: "AI 写作")
    case .appearance:
      return String(localized: "外观")
    case .rss:
      return String(localized: "RSS 阅读")
    case .privacy:
      return String(localized: "隐私")
    case .dataManagement:
      return String(localized: "数据管理")
    }
  }

  var systemImage: String {
    switch self {
    case .configurationStatus:
      return "checkmark.seal"
    case .defaultRules:
      return "slider.horizontal.3"
    case .token:
      return "link"
    case .ai:
      return "sparkles"
    case .appearance:
      return "paintpalette"
    case .rss:
      return "dot.radiowaves.left.and.right"
    case .privacy:
      return "hand.raised"
    case .dataManagement:
      return "externaldrive"
    }
  }

  var subtitle: String {
    switch self {
    case .configurationStatus:
      return String(localized: "集中检查当前站点的发布基础、凭据和应用功能状态。")
    case .defaultRules:
      return String(localized: "设置当前站点的发布检查、文章头信息和文件路径。")
    case .token:
      return String(localized: "连接仓库与部署平台，并将凭据安全保存在钥匙串。")
    case .ai:
      return String(localized: "选择 AI 服务、模型和当前站点的写作风格。")
    case .appearance:
      return String(localized: "自定义 RepoPress Studio 的主题强调色，并决定选择态如何跟随 macOS。")
    case .rss:
      return String(localized: "管理 RSS 离线缓存、图片缓存、刷新并发和历史文章清理。")
    case .privacy:
      return String(localized: "控制离席时的快速隐藏和私密文章遮挡。")
    case .dataManagement:
      return String(localized: "集中管理版本、回收站、备份、恢复和内容迁移。")
    }
  }

  var isSiteScoped: Bool {
    switch self {
    case .configurationStatus, .defaultRules, .token, .ai:
      return true
    case .appearance, .rss, .privacy, .dataManagement:
      return false
    }
  }

  var contentMaxWidth: CGFloat {
    switch self {
    case .appearance, .rss, .privacy:
      return WorkbenchSettingsMetrics.focusedContentWidth
    case .configurationStatus, .defaultRules, .token, .ai, .dataManagement:
      return WorkbenchSettingsMetrics.detailedContentWidth
    }
  }

  static let siteSettings: [SettingsTab] = [.configurationStatus, .defaultRules, .token, .ai]
  static let applicationSettings: [SettingsTab] = [.dataManagement, .appearance, .rss, .privacy]

  static func tab(forRequestedID id: String) -> SettingsTab? {
    if let tab = allCases.first(where: { $0.id == id }) {
      return tab
    }

    switch id {
    case "language":
      return .appearance
    case "storage", "data":
      return .dataManagement
    default:
      return nil
    }
  }

  @ViewBuilder
  @MainActor
  func makeContent(context: SettingsContext) -> some View {
    SettingsTabContentFactory.makeContent(for: self, context: context)
  }
}
