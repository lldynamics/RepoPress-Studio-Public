import Foundation

/// The single navigation value shared by the settings sidebar and detail pane.
///
/// Page identifiers remain the persisted compatibility boundary. Subsections
/// are transient anchors used by deep links and search results.
enum SettingsRoute: Hashable, Sendable {
  case tab(SettingsTab)
  case subsection(SettingsSubsection)

  var tab: SettingsTab {
    switch self {
    case .tab(let tab):
      return tab
    case .subsection(let subsection):
      return subsection.tab
    }
  }

  var subsection: SettingsSubsection {
    switch self {
    case .tab(let tab):
      return SettingsSubsection.defaultSection(for: tab)
    case .subsection(let subsection):
      return subsection
    }
  }

  static func destination(_ destination: SettingsDestination) -> SettingsRoute {
    let subsection = SettingsSubsection.section(for: destination)
    if case .tab = destination {
      return .tab(destination.tab)
    }
    return .subsection(subsection)
  }

  static func requestedID(_ requestedID: String) -> SettingsRoute? {
    switch requestedID {
    case "appearance.defaults":
      return .subsection(.appearanceDefaults)
    case "storage":
      return .subsection(.dataStorage)
    default:
      guard let destination = SettingsDestination(requestedID: requestedID) else {
        return nil
      }
      return .destination(destination)
    }
  }

  static func restored(lastViewedID: String?) -> SettingsRoute {
    guard let lastViewedID, !lastViewedID.isEmpty else {
      return .tab(.configurationStatus)
    }
    return requestedID(lastViewedID) ?? .tab(.configurationStatus)
  }
}
