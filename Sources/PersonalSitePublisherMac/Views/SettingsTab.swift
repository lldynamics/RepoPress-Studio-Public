import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsContext {
  let store: WorkbenchStore
  let browserBridge: KnowledgeBrowserBridge?
  let storeKitProEntitlementCoordinator: StoreKitProEntitlementCoordinator
  let activeProfileBinding: Binding<SiteProfile>
  let autoRunPreflightBinding: Binding<Bool>
  let scanRepositoryOnLaunch: Binding<Bool>
  let siteKindBinding: Binding<SiteKind>
  let healthDestination: SettingsConfigurationHealthDestination?
  let healthNavigationRequestID: UUID
  let selectConfigurationHealthDestination: (SettingsConfigurationHealthDestination) -> Void

  var actions: SettingsStoreActions {
    SettingsStoreActions(
      store: store,
      storeKitProEntitlementCoordinator: storeKitProEntitlementCoordinator
    )
  }
}

enum SettingsTab: Hashable, CaseIterable, Identifiable {
  case configurationStatus
  case defaultRules
  case token
  case ai
  case knowledge
  case privacy
  case pro

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
    case .knowledge:
      return "knowledge"
    case .privacy:
      return "privacy"
    case .pro:
      return "pro"
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
    case .knowledge:
      return String(localized: "资料库")
    case .privacy:
      return String(localized: "隐私")
    case .pro:
      return String(localized: "Pro")
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
    case .knowledge:
      return "books.vertical"
    case .privacy:
      return "hand.raised"
    case .pro:
      return "crown"
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
    case .knowledge:
      if DistributionFeaturePolicy.allowsBrowserCapture {
        return String(localized: "管理本地检索、智能集合、备份与浏览器连接。")
      }
      return String(localized: "管理本地检索、智能集合与资料备份。")
    case .privacy:
      return String(localized: "控制离席时的快速隐藏和私密文章遮挡。")
    case .pro:
      return String(localized: "查看权益状态、免费额度和购买选项。")
    }
  }

  var isSiteScoped: Bool {
    switch self {
    case .configurationStatus, .defaultRules, .token, .ai:
      return true
    case .knowledge, .privacy, .pro:
      return false
    }
  }

  var contentMaxWidth: CGFloat {
    switch self {
    case .privacy:
      return 640
    case .pro:
      return 720
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
  static let applicationSettings: [SettingsTab] = [.knowledge, .privacy, .pro]

  var isAvailableInCurrentDistribution: Bool {
    self != .ai || DistributionFeaturePolicy.allowsExternalAIProviders
  }

  @ViewBuilder
  @MainActor
  func makeContent(context: SettingsContext) -> some View {
    SettingsTabContentFactory.makeContent(for: self, context: context)
  }
}
