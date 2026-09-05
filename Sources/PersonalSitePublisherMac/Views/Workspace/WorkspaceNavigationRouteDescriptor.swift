import PublishingWorkbenchCore
import SwiftUI

/// The five stable workspace routes shown in both the full and compact rails.
/// Keep this order independent from command shortcut order.
enum WorkspaceNavigationRouteDescriptor {
  static let primaryRows: [[WorkspaceSection]] = [
    [.rss, .library],
    [.sync, .contentHealth],
    [.writing],
  ]

  static let primarySections: [WorkspaceSection] = primaryRows.flatMap { $0 }

  static func title(for section: WorkspaceSection) -> String {
    workspaceNavigationLocalizedString(section.displayNameLocalizationKey)
  }

  static func accessibilityLabel(for section: WorkspaceSection) -> LocalizedStringKey {
    workspaceNavigationLocalizedKey(section.displayNameLocalizationKey)
  }
}
