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
  let selectConfigurationHealthDestination: (SettingsConfigurationHealthDestination) -> Void

  var actions: SettingsStoreActions {
    SettingsStoreActions(store: store)
  }
}

enum SettingsScrollOwnership: String, Equatable {
  case nativeForm
  case nativeScrollView
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
      return String(localized: "站点概览")
    case .defaultRules:
      return String(localized: "内容与路径")
    case .token:
      return String(localized: "发布连接")
    case .ai:
      return String(localized: "AI 助手")
    case .appearance:
      return String(localized: "通用与外观")
    case .rss:
      return String(localized: "RSS 阅读")
    case .privacy:
      return String(localized: "隐私与安全")
    case .dataManagement:
      return String(localized: "数据与备份")
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
      return String(localized: "查看当前站点的发布基础、凭据和功能就绪状态。")
    case .defaultRules:
      return String(localized: "设置当前站点的文章头信息、文件名和路径模板。")
    case .token:
      return String(localized: "连接代码仓库、部署平台和阅读数据服务。")
    case .ai:
      return String(localized: "管理 AI 连接、凭据和当前站点的写作偏好。")
    case .appearance:
      return String(localized: "设置应用语言、启动行为、主题和强调色。")
    case .rss:
      return String(localized: "管理 RSS 正文离线保存、OPML、内网访问和历史文章清理。")
    case .privacy:
      return String(localized: "控制快速隐藏、私密内容遮挡和安全状态。")
    case .dataManagement:
      return String(localized: "管理草稿生命周期、工作区备份、恢复和内容迁移。")
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

  var scrollOwnership: SettingsScrollOwnership {
    switch self {
    case .dataManagement:
      return .nativeScrollView
    case .configurationStatus, .defaultRules, .token, .ai, .appearance, .rss, .privacy:
      return .nativeForm
    }
  }

  static let siteSettings: [SettingsTab] = [.configurationStatus, .defaultRules, .token, .ai]
  static let applicationSettings: [SettingsTab] = [.dataManagement, .appearance, .rss, .privacy]

  var searchKeywords: [String] {
    switch self {
    case .configurationStatus:
      return ["状态", "健康", "就绪", "本地发布", "overview", "status"]
    case .defaultRules:
      return ["发布规则", "Front Matter", "作者", "标签", "分类", "Slug", "文件名", "路径", "模板"]
    case .token:
      return ["仓库", "部署", "阅读数据", "GitHub", "GitLab", "Token", "令牌", "凭据", "权限"]
    case .ai:
      return ["模型", "服务", "API Key", "授权", "连接测试", "写作风格", "本地 AI"]
    case .appearance:
      return ["通用", "启动", "自动检查", "扫描", "主题", "强调色", "语言", "外观"]
    case .rss:
      return ["订阅", "OPML", "离线", "内网", "保留", "历史文章", "清理"]
    case .privacy:
      return ["隐私", "安全", "快速隐藏", "防偷窥", "遮挡", "快捷键"]
    case .dataManagement:
      return ["数据", "草稿", "版本", "回收站", "存储", "清理", "备份", "恢复", "迁移", "导入"]
    }
  }

  func matchesSearch(_ query: String) -> Bool {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return true }
    let searchableText = ([title, subtitle] + searchKeywords).joined(separator: " ")
    return searchableText.range(
      of: normalizedQuery,
      options: [.caseInsensitive, .diacriticInsensitive]
    ) != nil
  }

  static func tab(forRequestedID id: String) -> SettingsTab? {
    SettingsDestination(requestedID: id)?.tab
  }

  @ViewBuilder
  @MainActor
  func makeContent(context: SettingsContext) -> some View {
    SettingsTabContentFactory.makeContent(for: self, context: context)
  }
}
