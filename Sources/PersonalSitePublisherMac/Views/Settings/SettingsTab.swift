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
  let selectConfigurationHealthDestination: (SettingsConfigurationHealthDestination) -> Void
  let selectSettingsDestination: (SettingsDestination) -> Void

  var actions: SettingsStoreActions {
    SettingsStoreActions(store: store)
  }
}

enum SettingsScrollOwnership: String, Equatable {
  case nativeForm
  case nativeScrollView
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
      return String(localized: "发布连接")
    case .ai:
      return String(localized: "AI 连接")
    case .siteAI:
      return String(localized: "AI 与写作偏好")
    case .appearance:
      return String(localized: "通用与外观")
    case .editor:
      return String(localized: "编辑器")
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
      return String(localized: "连接代码仓库、部署平台和阅读数据服务。")
    case .ai:
      return String(localized: "编辑当前站点所用的共享连接，修改会影响所有引用此连接的站点。")
    case .siteAI:
      return String(localized: "选择当前站点使用的 AI 连接，并设置本站的写作风格。")
    case .appearance:
      return String(localized: "设置应用语言、启动行为、主题和强调色。")
    case .editor:
      return String(localized: "管理文章编辑、写作体验与所有站点共用的新文章预设。")
    case .rss:
      return String(localized: "管理 RSS 正文离线保存、OPML、内网访问和历史文章清理。")
    case .privacy:
      return String(localized: "控制快速隐藏、私密内容遮挡和快捷键。")
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
    case .configurationStatus, .defaultRules, .token, .ai, .siteAI, .dataManagement:
      return WorkbenchSettingsMetrics.detailedContentWidth
    }
  }

  var scrollOwnership: SettingsScrollOwnership {
    switch self {
    case .dataManagement:
      return .nativeScrollView
    case .configurationStatus, .defaultRules, .token, .ai, .siteAI, .appearance, .editor, .rss,
      .privacy:
      return .nativeForm
    }
  }

  static let siteSettings: [SettingsTab] = [.configurationStatus, .defaultRules, .token, .siteAI]
  static let applicationSettings: [SettingsTab] = [
    .appearance, .editor, .ai, .rss, .dataManagement, .privacy,
  ]

  var searchKeywords: [String] {
    switch self {
    case .configurationStatus:
      return ["状态", "健康", "就绪", "本地发布", "overview", "status"]
    case .defaultRules:
      return ["发布规则", "Front Matter", "作者", "标签", "分类", "Slug", "文件名", "路径", "模板"]
    case .token:
      return ["仓库", "部署", "阅读数据", "GitHub", "GitLab", "Token", "令牌", "凭据", "权限"]
    case .ai:
      return ["模型", "服务", "API Key", "授权", "连接测试", "共享连接", "本地 AI"]
    case .siteAI:
      return ["写作风格", "语气", "受众", "连接选择", "站点 AI", "提示词"]
    case .appearance:
      return ["通用", "启动", "自动检查", "扫描", "主题", "强调色", "语言", "外观"]
    case .editor:
      return [
        "编辑器", "字号", "行距", "正文宽度", "拼写检查", "打字机模式", "当前段落",
        "正文分析", "纸张背景", "自动配对", "段落聚光灯", "新文章", "全局预设", "Front Matter", "editor",
      ]
    case .rss:
      return [
        "订阅", "OPML", "离线", "内网", "保留", "历史文章", "清理", "远程图片", "自动翻译",
        "remote image", "translation",
      ]
    case .privacy:
      return ["隐私", "快速隐藏", "临时遮挡", "遮挡", "快捷键"]
    case .dataManagement:
      return ["数据", "草稿", "版本", "回收站", "存储", "清理", "备份", "恢复", "迁移", "导入"]
    }
  }

  func matchesSearchDirectly(_ query: String) -> Bool {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return true }
    let searchableText = ([title, subtitle] + searchKeywords).joined(separator: " ")
    return searchableText.range(
      of: normalizedQuery,
      options: [.caseInsensitive, .diacriticInsensitive]
    ) != nil
  }

  func matchesSearch(_ query: String) -> Bool {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return true }
    if matchesSearchDirectly(normalizedQuery) {
      return true
    }
    return SettingsSearchIndex.search(query: normalizedQuery).contains(where: { $0.tab == self })
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
