import Foundation

/// Scene-scoped expansion state for the settings sidebar.
///
/// The route controls the detail pane independently. Persisting only explicit
/// disclosure actions keeps the sidebar tree stable while selection follows
/// search results, deep links, and manual detail scrolling.
struct SettingsNavigationExpansionState: Equatable, Sendable {
  static let sceneStorageKey = "settings.navigation.expanded-tab-ids"

  /// Keep the first visit scannable; users opt into each subtree explicitly.
  static let defaultRawValue = ""

  private static let validTabIDs = Set(SettingsTab.allCases.map(\.id))

  private var expandedTabIDs: Set<String>

  init(rawValue: String) {
    expandedTabIDs = Set(
      rawValue
        .split(separator: ",")
        .map(String.init)
        .filter { Self.validTabIDs.contains($0) }
    )
  }

  init(expandedTabs: Set<SettingsTab>) {
    expandedTabIDs = Set(expandedTabs.map(\.id))
  }

  var rawValue: String {
    expandedTabIDs.sorted().joined(separator: ",")
  }

  func contains(_ tab: SettingsTab) -> Bool {
    expandedTabIDs.contains(tab.id)
  }

  func visibleSelection(for route: SettingsRoute) -> SettingsRoute {
    contains(route.tab) ? route : .tab(route.tab)
  }

  mutating func setExpanded(_ isExpanded: Bool, for tab: SettingsTab) {
    if isExpanded {
      expandedTabIDs.insert(tab.id)
    } else {
      expandedTabIDs.remove(tab.id)
    }
  }
}
