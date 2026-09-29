import PublishingKnowledgeCore
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
  let navigationDestination: SettingsDestination?
  let navigationRequestID: UUID
  let selectedSubsection: SettingsSubsection
  let selectConfigurationHealthDestination: (SettingsConfigurationHealthDestination) -> Void
  let selectSettingsDestination: (SettingsDestination) -> Void

  var actions: SettingsStoreActions {
    SettingsStoreActions(store: store)
  }
}

enum SettingsTab: Hashable, CaseIterable, Identifiable, Sendable {
  case configurationStatus
  case defaultRules
  case token
  case ai
  case siteAI
  case appearance
  case editor
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
    case .siteAI:
      return "siteAI"
    case .appearance:
      return "appearance"
    case .editor:
      return "editor"
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
      return String(localized: "站点概览")
    case .defaultRules:
      return String(localized: "内容与路径")
    case .token:
      return String(localized: "发布配置")
    case .ai:
      return String(localized: "应用级 AI 连接")
    case .siteAI:
      return String(localized: "当前站点的 AI 与写作偏好")
    case .appearance:
      return String(localized: "通用与外观")
    case .editor:
      return String(localized: "编辑器偏好")
    case .rss:
      return String(localized: "RSS 阅读")
    case .privacy:
      return String(localized: "隐私与安全")
    case .dataManagement:
      return String(localized: "备份与恢复")
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
    case .siteAI:
      return "text.quote"
    case .appearance:
      return "paintpalette"
    case .editor:
      return "pencil.line"
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
      return String(localized: "查看当前站点的发布基础、凭据和功能就绪状态。")
    case .defaultRules:
      return String(localized: "设置当前站点的文章头信息、文件名和路径模板。")
    case .token:
      return String(localized: "连接代码仓库和部署平台。")
    case .ai:
      return String(localized: "管理应用内共享的 AI 连接，修改会影响所有引用此连接的站点。")
    case .siteAI:
      return String(localized: "为当前站点选择 AI 连接，并设置本站的写作风格。")
    case .appearance:
      return String(localized: "设置启动行为、主题和强调色。")
    case .editor:
      return String(localized: "管理文章编辑、写作体验与所有站点共用的新文章预设。")
    case .rss:
      return String(localized: "管理 RSS 正文离线保存、OPML、内网访问和历史文章清理。")
    case .privacy:
      return String(localized: "管理私密内容的遮挡与保护状态。")
    case .dataManagement:
      return String(localized: "管理草稿生命周期、工作区备份、恢复和内容迁移。")
    }
  }

  var isSiteScoped: Bool {
    switch self {
    case .configurationStatus, .defaultRules, .token, .siteAI:
      return true
    case .ai, .appearance, .editor, .rss, .privacy, .dataManagement:
      return false
    }
  }

  var scopePresentation: SettingsScopePresentation {
    switch self {
    case .configurationStatus, .defaultRules, .token, .siteAI:
      return .currentSite
    case .ai:
      return .sharedConnection
    case .appearance, .editor, .rss, .privacy, .dataManagement:
      return .shared
    }
  }

  var contentMaxWidth: CGFloat {
    switch self {
    case .appearance, .editor, .rss, .privacy:
      return WorkbenchSettingsMetrics.focusedContentWidth
    case .ai, .dataManagement:
      return WorkbenchSettingsMetrics.detailedContentWidth
    case .configurationStatus, .defaultRules, .token, .siteAI:
      return .infinity
    }
  }

  static let siteSettings: [SettingsTab] = [.configurationStatus, .defaultRules, .token, .siteAI]
  static let applicationSettings: [SettingsTab] = [
    .appearance, .editor, .ai, .rss, .dataManagement, .privacy,
  ]

  static func tab(forRequestedID id: String) -> SettingsTab? {
    SettingsDestination(requestedID: id)?.tab
  }

  @ViewBuilder
  @MainActor
  func makeContent(context: SettingsContext) -> some View {
    SettingsTabContentFactory.makeContent(for: self, context: context)
  }
}
