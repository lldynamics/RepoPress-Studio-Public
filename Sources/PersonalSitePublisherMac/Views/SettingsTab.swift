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
  case language
  case storage
  case rss
  case privacy

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
    case .language:
      return "language"
    case .storage:
      return "storage"
    case .rss:
      return "rss"
    case .privacy:
      return "privacy"
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
    case .language:
      return String(localized: "语言")
    case .storage:
      return String(localized: "存储管理")
    case .rss:
      return String(localized: "RSS 阅读")
    case .privacy:
      return String(localized: "隐私")
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
    case .language:
      return "globe"
    case .storage:
      return "externaldrive"
    case .rss:
      return "dot.radiowaves.left.and.right"
    case .privacy:
      return "hand.raised"
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
      return String(localized: "自定义 RepoPress 的主题强调色，并决定选择态如何跟随 macOS。")
    case .language:
      return String(localized: "选择界面语言，并控制 RepoPress 如何跟随 macOS。")
    case .storage:
      return String(localized: "管理资料库与 RSS 的本地文件、备份、导入和存储位置。")
    case .rss:
      return String(localized: "管理 RSS 离线缓存、图片缓存、刷新并发和历史文章清理。")
    case .privacy:
      return String(localized: "控制离席时的快速隐藏和私密文章遮挡。")
    }
  }

  var isSiteScoped: Bool {
    switch self {
    case .configurationStatus, .defaultRules, .token, .ai:
      return true
    case .appearance, .language, .storage, .rss, .privacy:
      return false
    }
  }

  var contentMaxWidth: CGFloat {
    switch self {
    case .appearance, .language, .rss, .privacy:
      return WorkbenchSettingsMetrics.focusedContentWidth
    case .configurationStatus, .defaultRules, .token, .ai, .storage:
      return WorkbenchSettingsMetrics.detailedContentWidth
    }
  }

  static let siteSettings: [SettingsTab] = [.configurationStatus, .defaultRules, .token, .ai]
  static let applicationSettings: [SettingsTab] = [
    .appearance,
    .language,
    .storage,
    .rss,
    .privacy,
  ]

  @ViewBuilder
  @MainActor
  func makeContent(context: SettingsContext) -> some View {
    SettingsTabContentFactory.makeContent(for: self, context: context)
  }
}
