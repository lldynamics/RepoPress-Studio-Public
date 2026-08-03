import PublishingWorkbenchCore
import SwiftUI

enum ContentHealthContextFilter: String, CaseIterable, Identifiable {
  case overview
  case publicRisks
  case aiFixes
  case siteIssues
  case maintenance

  var id: String { rawValue }

  static var navigationFilters: [Self] {
    var filters: [Self] = [.overview, .publicRisks]
    if DistributionFeaturePolicy.allowsExternalAIProviders {
      filters.append(.aiFixes)
    }
    filters.append(contentsOf: [.siteIssues, .maintenance])
    return filters
  }

  var title: LocalizedStringKey {
    switch self {
    case .overview:
      return "行动队列"
    case .publicRisks:
      return "公开风险"
    case .aiFixes:
      return "AI 可修复"
    case .siteIssues:
      return "站点问题"
    case .maintenance:
      return "站点维护"
    }
  }

  var accessibilityTitle: String {
    switch self {
    case .overview:
      return String(localized: "行动队列")
    case .publicRisks:
      return String(localized: "公开风险")
    case .aiFixes:
      return String(localized: "AI 可修复")
    case .siteIssues:
      return String(localized: "站点问题")
    case .maintenance:
      return String(localized: "站点维护")
    }
  }

  var systemImage: String {
    switch self {
    case .overview:
      return "list.bullet.clipboard"
    case .publicRisks:
      return "exclamationmark.shield"
    case .aiFixes:
      return "sparkles"
    case .siteIssues:
      return "globe.badge.chevron.backward"
    case .maintenance:
      return "wrench.and.screwdriver"
    }
  }
}

enum ImageWorkbenchContextStage: String, Identifiable, Hashable {
  case overview
  case repository
  case manager

  var id: String { rawValue }

  static let navigationStages: [Self] = [
    .overview,
    .repository,
    .manager,
  ]

  var title: LocalizedStringKey {
    switch self {
    case .overview:
      return "概览与批量处理"
    case .repository:
      return "仓库图片"
    case .manager:
      return "资源管理"
    }
  }

  var accessibilityTitle: String {
    switch self {
    case .overview:
      return String(localized: "概览与批量处理")
    case .repository:
      return String(localized: "仓库图片")
    case .manager:
      return String(localized: "资源管理")
    }
  }

  var systemImage: String {
    switch self {
    case .overview:
      return "rectangle.grid.2x2"
    case .repository:
      return "photo.stack"
    case .manager:
      return "archivebox"
    }
  }
}

enum RepositoryContextStage: String, Identifiable {
  case overview
  case changes
  case source
  case history

  var id: String { rawValue }

  static let navigationStages: [Self] = [
    .overview,
    .changes,
    .history,
  ]

  var primaryNavigationStage: Self {
    switch self {
    case .source:
      return .changes
    case .overview, .changes, .history:
      return self
    }
  }

  var title: LocalizedStringKey {
    switch self {
    case .overview:
      return "概览"
    case .changes:
      return "文件变更"
    case .source:
      return "源码"
    case .history:
      return "发布记录"
    }
  }

  var accessibilityTitle: String {
    switch self {
    case .overview:
      return String(localized: "概览")
    case .changes:
      return String(localized: "文件变更")
    case .source:
      return String(localized: "源码")
    case .history:
      return String(localized: "发布记录")
    }
  }

  var requiresRepository: Bool {
    switch self {
    case .overview, .history:
      return false
    case .changes, .source:
      return true
    }
  }
}
