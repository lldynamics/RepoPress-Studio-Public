import Foundation

/// Presentation groups follow the actual scope of the settings they contain.
/// Stable tab IDs still own restoration and compatibility with existing entry points.
enum SettingsTaskGroup: String, CaseIterable, Identifiable, Sendable {
  case application
  case currentSite

  var id: String { rawValue }

  var title: String {
    switch self {
    case .application:
      return String(localized: "应用设置")
    case .currentSite:
      return String(localized: "当前站点设置")
    }
  }

  var tabs: [SettingsTab] {
    switch self {
    case .application:
      return SettingsTab.applicationSettings
    case .currentSite:
      return SettingsTab.siteSettings
    }
  }

  static func group(for tab: SettingsTab) -> SettingsTaskGroup {
    tab.isSiteScoped ? .currentSite : .application
  }
}
