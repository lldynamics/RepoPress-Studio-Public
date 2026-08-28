import SwiftUI

/// A stable second navigation level shared by every top-level settings page.
///
/// Top-level tabs keep their existing identifiers for deep-link and restoration
/// compatibility. Subsections only control which focused group is visible in
/// the detail pane, so long settings forms no longer require users to scan one
/// continuous page.
enum SettingsSubsection: String, CaseIterable, Identifiable, Sendable {
  case configurationReadiness

  case rulesBasics
  case rulesDiscovery
  case rulesFrontMatter
  case rulesPaths

  case tokenRepository
  case tokenDeployment
  case tokenAnalytics

  case aiConnection
  case aiAdvanced
  case aiWritingStyle

  case dataDrafts
  case dataStorage
  case dataBackup
  case dataMigration

  case appearanceBehavior
  case appearanceTheme
  case appearanceLanguage
  case appearanceDefaults

  case editorPreview
  case editorTypography
  case editorAssistance
  case editorAutomation

  case rssRefresh
  case rssReading
  case rssOfflineNetwork
  case rssMigration
  case rssCleanup

  case privacyQuickHide
  case privacyMasking
  case privacyStatus

  var id: String { rawValue }

  var tab: SettingsTab {
    switch self {
    case .configurationReadiness:
      return .configurationStatus
    case .rulesBasics, .rulesDiscovery, .rulesFrontMatter, .rulesPaths:
      return .defaultRules
    case .tokenRepository, .tokenDeployment, .tokenAnalytics:
      return .token
    case .aiConnection, .aiAdvanced, .aiWritingStyle:
      return .ai
    case .dataDrafts, .dataStorage, .dataBackup, .dataMigration:
      return .dataManagement
    case .appearanceBehavior, .appearanceTheme, .appearanceLanguage, .appearanceDefaults:
      return .appearance
    case .editorPreview, .editorTypography, .editorAssistance, .editorAutomation:
      return .editor
    case .rssRefresh, .rssReading, .rssOfflineNetwork, .rssMigration, .rssCleanup:
      return .rss
    case .privacyQuickHide, .privacyMasking, .privacyStatus:
      return .privacy
    }
  }

  var title: String {
    switch self {
    case .configurationReadiness: return String(localized: "就绪状态")
    case .rulesBasics: return String(localized: "常用默认值")
    case .rulesDiscovery: return String(localized: "仓库发现")
    case .rulesFrontMatter: return String(localized: "Front Matter")
    case .rulesPaths: return String(localized: "路径与模板")
    case .tokenRepository: return String(localized: "代码仓库")
    case .tokenDeployment: return String(localized: "部署平台")
    case .tokenAnalytics: return String(localized: "阅读数据")
    case .aiConnection: return String(localized: "模型与连接")
    case .aiAdvanced: return String(localized: "参数与网络")
    case .aiWritingStyle: return String(localized: "写作风格")
    case .dataDrafts: return String(localized: "草稿生命周期")
    case .dataStorage: return String(localized: "存储管理")
    case .dataBackup: return String(localized: "备份与恢复")
    case .dataMigration: return String(localized: "迁移与导入")
    case .appearanceBehavior: return String(localized: "应用行为")
    case .appearanceTheme: return String(localized: "外观")
    case .appearanceLanguage: return String(localized: "语言")
    case .appearanceDefaults: return String(localized: "新建内容默认值")
    case .editorPreview: return String(localized: "效果预览")
    case .editorTypography: return String(localized: "字体与布局")
    case .editorAssistance: return String(localized: "编辑辅助")
    case .editorAutomation: return String(localized: "自动化")
    case .rssRefresh: return String(localized: "刷新与缓存")
    case .rssReading: return String(localized: "阅读默认值")
    case .rssOfflineNetwork: return String(localized: "离线与网络")
    case .rssMigration: return String(localized: "订阅迁移")
    case .rssCleanup: return String(localized: "历史清理")
    case .privacyQuickHide: return String(localized: "快速隐藏")
    case .privacyMasking: return String(localized: "内容遮挡")
    case .privacyStatus: return String(localized: "当前状态")
    }
  }

  var subtitle: String {
    switch self {
    case .configurationReadiness: return String(localized: "发布基础、凭据和需要处理的项目")
    case .rulesBasics: return String(localized: "作者、分类与站点类型")
    case .rulesDiscovery: return String(localized: "识别仓库中的内容结构")
    case .rulesFrontMatter: return String(localized: "字段、模板与预览")
    case .rulesPaths: return String(localized: "文章、图片与日期路径规则")
    case .tokenRepository: return String(localized: "远端仓库、权限与访问令牌")
    case .tokenDeployment: return String(localized: "发布目标、自动化与凭据")
    case .tokenAnalytics: return String(localized: "统计服务和验证状态")
    case .aiConnection: return String(localized: "账号、服务商、模型与凭据")
    case .aiAdvanced: return String(localized: "生成参数、网络与能力检查")
    case .aiWritingStyle: return String(localized: "当前站点的写作偏好")
    case .dataDrafts: return String(localized: "版本、回收站与保留策略")
    case .dataStorage: return String(localized: "数据位置和空间使用")
    case .dataBackup: return String(localized: "备份计划、恢复与校验")
    case .dataMigration: return String(localized: "导入、导出和工作区迁移")
    case .appearanceBehavior: return String(localized: "启动、检查与扫描行为")
    case .appearanceTheme: return String(localized: "主题、强调色与界面密度")
    case .appearanceLanguage: return String(localized: "应用语言与翻译")
    case .appearanceDefaults: return String(localized: "所有站点共用的新文章预设")
    case .editorPreview: return String(localized: "即时查看排版与阅读效果")
    case .editorTypography: return String(localized: "字号、行距与正文宽度")
    case .editorAssistance: return String(localized: "拼写、配对与聚光灯")
    case .editorAutomation: return String(localized: "保存、分析与重置行为")
    case .rssRefresh: return String(localized: "本地缓存和后台刷新")
    case .rssReading: return String(localized: "文章打开与阅读体验")
    case .rssOfflineNetwork: return String(localized: "离线范围、图片与网络安全")
    case .rssMigration: return String(localized: "OPML 导入与导出")
    case .rssCleanup: return String(localized: "保留周期和数据库整理")
    case .privacyQuickHide: return String(localized: "一键保护工作台内容")
    case .privacyMasking: return String(localized: "私密正文、路径和预览")
    case .privacyStatus: return String(localized: "保护状态、快捷键和支持")
    }
  }

  var systemImage: String {
    switch self {
    case .configurationReadiness: return "checkmark.seal"
    case .rulesBasics: return "slider.horizontal.3"
    case .rulesDiscovery: return "magnifyingglass"
    case .rulesFrontMatter: return "text.badge.checkmark"
    case .rulesPaths: return "folder.badge.gearshape"
    case .tokenRepository: return "shippingbox"
    case .tokenDeployment: return "rocket"
    case .tokenAnalytics: return "chart.bar"
    case .aiConnection: return "link"
    case .aiAdvanced: return "dial.medium"
    case .aiWritingStyle: return "text.quote"
    case .dataDrafts: return "doc.on.doc"
    case .dataStorage: return "externaldrive"
    case .dataBackup: return "arrow.triangle.2.circlepath"
    case .dataMigration: return "square.and.arrow.down.on.square"
    case .appearanceBehavior: return "switch.2"
    case .appearanceTheme: return "paintpalette"
    case .appearanceLanguage: return "globe"
    case .appearanceDefaults: return "doc.badge.plus"
    case .editorPreview: return "eye"
    case .editorTypography: return "textformat.size"
    case .editorAssistance: return "wand.and.stars"
    case .editorAutomation: return "gearshape.2"
    case .rssRefresh: return "arrow.clockwise"
    case .rssReading: return "book"
    case .rssOfflineNetwork: return "network"
    case .rssMigration: return "arrow.up.arrow.down"
    case .rssCleanup: return "trash"
    case .privacyQuickHide: return "eye.slash"
    case .privacyMasking: return "rectangle.dashed.badge.record"
    case .privacyStatus: return "shield.checkered"
    }
  }

  static func sections(for tab: SettingsTab) -> [SettingsSubsection] {
    allCases.filter { $0.tab == tab }
  }

  static func defaultSection(for tab: SettingsTab) -> SettingsSubsection {
    sections(for: tab).first ?? .configurationReadiness
  }

  var previous: SettingsSubsection? {
    adjacent(offset: -1)
  }

  var next: SettingsSubsection? {
    adjacent(offset: 1)
  }

  private func adjacent(offset: Int) -> SettingsSubsection? {
    let siblings = Self.sections(for: tab)
    guard let index = siblings.firstIndex(of: self) else { return nil }
    let adjacentIndex = index + offset
    guard siblings.indices.contains(adjacentIndex) else { return nil }
    return siblings[adjacentIndex]
  }

  static func section(for destination: SettingsDestination) -> SettingsSubsection {
    switch destination {
    case .tab(let tab):
      return defaultSection(for: tab)
    case .rules:
      return .rulesPaths
    case .token(let destination):
      switch destination {
      case .repository: return .tokenRepository
      case .deployment: return .tokenDeployment
      case .analytics: return .tokenAnalytics
      }
    case .ai(let destination):
      switch destination {
      case .connection, .credentials: return .aiConnection
      case .writingStyle: return .aiWritingStyle
      }
    case .data(let destination):
      switch destination {
      case .drafts: return .dataDrafts
      case .backup: return .dataBackup
      case .migration: return .dataMigration
      }
    }
  }

  static func section(forSearchItemID id: String) -> SettingsSubsection? {
    switch id {
    case "status.repo", "status.health": return .configurationReadiness
    case "rules.site": return .rulesBasics
    case "rules.discovery": return .rulesDiscovery
    case "rules.frontMatter": return .rulesFrontMatter
    case "rules.paths": return .rulesPaths
    case "token.repository": return .tokenRepository
    case "token.deployment": return .tokenDeployment
    case "token.analytics": return .tokenAnalytics
    case "ai.provider", "ai.credentials": return .aiConnection
    case "ai.advanced": return .aiAdvanced
    case "ai.writingStyle": return .aiWritingStyle
    case "data.drafts": return .dataDrafts
    case "data.storage": return .dataStorage
    case "data.backup": return .dataBackup
    case "data.migration": return .dataMigration
    case "appearance.launch", "appearance.extension": return .appearanceBehavior
    case "appearance.theme": return .appearanceTheme
    case "appearance.language": return .appearanceLanguage
    case "appearance.defaults": return .appearanceDefaults
    case "editor.preview": return .editorPreview
    case "editor.typography": return .editorTypography
    case "editor.comfort": return .editorAssistance
    case "editor.tools": return .editorAutomation
    case "rss.refresh": return .rssRefresh
    case "rss.translation": return .rssReading
    case "rss.storage": return .rssOfflineNetwork
    case "rss.opml": return .rssMigration
    case "rss.maintenance": return .rssCleanup
    case "privacy.quickHide": return .privacyQuickHide
    case "privacy.masking": return .privacyMasking
    case "privacy.status": return .privacyStatus
    default: return nil
    }
  }
}

private struct SettingsSubsectionEnvironmentKey: EnvironmentKey {
  static let defaultValue = SettingsSubsection.configurationReadiness
}

extension EnvironmentValues {
  var settingsSubsection: SettingsSubsection {
    get { self[SettingsSubsectionEnvironmentKey.self] }
    set { self[SettingsSubsectionEnvironmentKey.self] = newValue }
  }
}
