import Foundation

enum SettingsRulesDestination: String, Hashable, Sendable {
  case paths
}

enum SettingsTokenDestination: String, Hashable, Sendable {
  case repository
  case deployment
  case analytics
}

enum SettingsAIDestination: String, Hashable, Sendable {
  case connection
  case credentials
  case writingStyle
}

enum SettingsDataDestination: String, Hashable, Sendable {
  case drafts
  case backup
  case migration
}

/// A one-shot navigation target carried across the main and Settings scenes.
///
/// Top-level selection is persisted separately. Structured destinations are
/// intentionally consumed and cleared so a stale subsection request cannot
/// become the user's reopening preference.
enum SettingsDestination: Hashable, Identifiable, Sendable {
  case tab(SettingsTab)
  case rules(SettingsRulesDestination)
  case token(SettingsTokenDestination)
  case ai(SettingsAIDestination)
  case data(SettingsDataDestination)

  var id: String {
    switch self {
    case .tab(let tab):
      return tab.id
    case .rules(let destination):
      return "rules.\(destination.rawValue)"
    case .token(let destination):
      return "token.\(destination.rawValue)"
    case .ai(let destination):
      return "ai.\(destination.rawValue)"
    case .data(let destination):
      return "data.\(destination.rawValue)"
    }
  }

  var tab: SettingsTab {
    switch self {
    case .tab(let tab):
      return tab
    case .rules:
      return .defaultRules
    case .token:
      return .token
    case .ai(let destination):
      return destination == .writingStyle ? .siteAI : .ai
    case .data:
      return .dataManagement
    }
  }

  init?(requestedID: String) {
    switch requestedID {
    case "rules.paths":
      self = .rules(.paths)
    case "token.repository":
      self = .token(.repository)
    case "token.deployment":
      self = .token(.deployment)
    case "token.analytics":
      self = .token(.analytics)
    case "ai.connection":
      self = .ai(.connection)
    case "ai.credentials":
      self = .ai(.credentials)
    case "ai.writingStyle":
      self = .ai(.writingStyle)
    case "data.drafts":
      self = .data(.drafts)
    case "data.backup":
      self = .data(.backup)
    case "data.migration":
      self = .data(.migration)
    case "appearance.defaults":
      self = .tab(.editor)
    case "language":
      self = .tab(.appearance)
    case "storage", "data":
      self = .tab(.dataManagement)
    default:
      guard let tab = SettingsTab.allCases.first(where: { $0.id == requestedID }) else {
        return nil
      }
      self = .tab(tab)
    }
  }
}

enum SettingsNavigation {
  static let requestedTabStorageKey = "settingsRequestedTabID"
  static let lastViewedTabStorageKey = "settingsLastViewedTabID"

  static func initialTab(lastViewedTabID: String?) -> SettingsTab {
    SettingsTab.tab(forRequestedID: lastViewedTabID ?? "") ?? .configurationStatus
  }

  static func open(tab: SettingsTab? = nil, openSettings: () -> Void) {
    open(destination: tab.map(SettingsDestination.tab), openSettings: openSettings)
  }

  static func open(destination: SettingsDestination?, openSettings: () -> Void) {
    request(destination: destination)
    openSettings()
  }

  @MainActor
  static func present(
    destination: SettingsDestination?,
    workspaceAction: SettingsWorkspaceCommandAction?,
    openSettings: () -> Void
  ) {
    if let workspaceAction {
      workspaceAction.open(destination)
    } else {
      open(destination: destination, openSettings: openSettings)
    }
  }

  static func request(destination: SettingsDestination?) {
    UserDefaults.standard.set(destination?.id ?? "", forKey: requestedTabStorageKey)
  }

  /// Site configuration is shown in the main window. The Settings window hands
  /// such destinations over through this one-shot key; the main window
  /// consumes and clears it.
  static let requestedSiteDestinationStorageKey = "settingsRequestedSiteDestinationID"

  static func requestSiteSettings(_ destination: SettingsDestination) {
    UserDefaults.standard.set(destination.id, forKey: requestedSiteDestinationStorageKey)
  }

  static func consumeRequestedSiteSettings() -> SettingsDestination? {
    let defaults = UserDefaults.standard
    guard let id = defaults.string(forKey: requestedSiteDestinationStorageKey), !id.isEmpty
    else { return nil }
    defaults.set("", forKey: requestedSiteDestinationStorageKey)
    return SettingsDestination(requestedID: id)
  }

  /// App preferences belong to the standard Settings window; only site
  /// configuration is presented inside the main workspace.
  static func opensInSettingsWindow(_ destination: SettingsDestination?) -> Bool {
    guard let destination else { return true }
    return !destination.tab.isSiteScoped
  }
}
