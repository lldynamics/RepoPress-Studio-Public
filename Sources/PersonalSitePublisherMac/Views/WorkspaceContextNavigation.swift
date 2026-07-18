import SwiftUI

enum ContentHealthContextFilter: String, CaseIterable, Identifiable {
  case overview
  case publicRisks
  case aiFixes
  case siteIssues
  case maintenance

  var id: String { rawValue }
}

enum RepositoryContextStage: String, CaseIterable, Identifiable {
  case overview
  case changes
  case automation
  case preview
  case history

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .overview:
      return "概览"
    case .changes:
      return "变更"
    case .automation:
      return "自动检查"
    case .preview:
      return "本地预览"
    case .history:
      return "发布台账"
    }
  }

  var accessibilityTitle: String {
    switch self {
    case .overview:
      return String(localized: "概览")
    case .changes:
      return String(localized: "变更")
    case .automation:
      return String(localized: "自动检查")
    case .preview:
      return String(localized: "本地预览")
    case .history:
      return String(localized: "发布台账")
    }
  }

  var requiresRepository: Bool {
    switch self {
    case .overview, .history:
      return false
    case .changes, .automation, .preview:
      return true
    }
  }
}
