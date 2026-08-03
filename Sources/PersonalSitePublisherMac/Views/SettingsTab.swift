import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsContext {
  let store: WorkbenchStore
  let rssStore: RSSReaderStore?
  let browserBridge: KnowledgeBrowserBridge?
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
  case language
  case rss
  case knowledge
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
    case .language:
      return "language"
    case .rss:
      return "rss"
    case .knowledge:
      return "knowledge"
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
    case .language:
      return String(localized: "语言")
    case .rss:
      return String(localized: "RSS 阅读")
    case .knowledge:
      return String(localized: "资料库")
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
    case .language:
      return "globe"
    case .rss:
      return "dot.radiowaves.left.and.right"
    case .knowledge:
      return "books.vertical"
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
    case .language:
      return String(localized: "选择界面语言，并控制 RepoPress 如何跟随 macOS。")
    case .rss:
      return String(localized: "管理本地图片缓存、刷新并发和历史文章清理。")
    case .knowledge:
      if DistributionFeaturePolicy.allowsBrowserCapture {
        return String(localized: "管理本地检索、智能集合、备份与浏览器连接。")
      }
      return String(localized: "管理本地检索、智能集合与资料备份。")
    case .privacy:
      return String(localized: "控制离席时的快速隐藏和私密文章遮挡。")
    }
  }

  var isSiteScoped: Bool {
    switch self {
    case .configurationStatus, .defaultRules, .token, .ai:
      return true
    case .language, .rss, .knowledge, .privacy:
      return false
    }
  }

  var contentMaxWidth: CGFloat {
    switch self {
    case .language, .rss, .privacy:
      return 640
    case .configurationStatus, .defaultRules, .token, .ai, .knowledge:
      return 760
    }
  }

  static var siteSettings: [SettingsTab] {
    var tabs: [SettingsTab] = [.configurationStatus, .defaultRules, .token]
    if DistributionFeaturePolicy.allowsExternalAIProviders {
      tabs.append(.ai)
    }
    return tabs
  }
  // The library's management and settings entry point now lives in the
  // library header menu. Keep the enum/factory for legacy deep links, but do
  // not present a second, disconnected sidebar destination.
  static let applicationSettings: [SettingsTab] = [.language, .rss, .privacy]

  var isAvailableInCurrentDistribution: Bool {
    self != .ai || DistributionFeaturePolicy.allowsExternalAIProviders
  }

  @ViewBuilder
  @MainActor
  func makeContent(context: SettingsContext) -> some View {
    SettingsTabContentFactory.makeContent(for: self, context: context)
  }
}
