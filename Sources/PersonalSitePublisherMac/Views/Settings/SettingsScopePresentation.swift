import Foundation
import PublishingWorkbenchCore

enum SettingsScopePresentation: Equatable, Sendable {
  case currentSite
  case shared
  case mixed

  var badgeTitle: String {
    switch self {
    case .currentSite:
      return String(localized: "当前站点")
    case .shared:
      return String(localized: "全局共享")
    case .mixed:
      return String(localized: "混合作用范围")
    }
  }

  var systemImage: String {
    switch self {
    case .currentSite:
      return "globe.asia.australia"
    case .shared:
      return "globe"
    case .mixed:
      return "rectangle.3.group"
    }
  }

  var accessibilityDescription: String {
    switch self {
    case .currentSite:
      return String(localized: "当前站点，切换站点后可分别配置")
    case .shared:
      return String(localized: "全局共享，适用于所有站点")
    case .mixed:
      return String(localized: "混合作用范围，连接档案共享，写作偏好仅当前站点")
    }
  }
}

struct AIConnectionUsagePresentation: Equatable, Sendable {
  let referencedSiteNames: [String]

  init(connectionProfileID: UUID, siteProfiles: [SiteProfile]) {
    var names: [String] = []
    var seenProfileIDs = Set<UUID>()
    for profile in siteProfiles where profile.aiConnectionProfileID == connectionProfileID {
      let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, seenProfileIDs.insert(profile.id).inserted else { continue }
      names.append(name)
    }
    referencedSiteNames = names
  }

  var referencedSitesDescription: String {
    guard !referencedSiteNames.isEmpty else {
      return String(localized: "当前没有站点引用此档案。")
    }
    return String(
      localized: "引用站点：\(referencedSiteNames.joined(separator: "、"))"
    )
  }
}
