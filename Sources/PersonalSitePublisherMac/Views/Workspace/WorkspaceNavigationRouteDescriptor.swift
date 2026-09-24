import PublishingWorkbenchCore
import SwiftUI

/// The five direct workspace routes shared by the full and compact navigators.
/// Keep the established visual order independent from command shortcut order.
enum WorkspaceNavigationRouteDescriptor {
  static let primaryRows: [[WorkspaceSection]] = [
    [.rss, .library],
    [.sync, .contentHealth],
    [.writing],
  ]

  static let primarySections: [WorkspaceSection] = primaryRows.flatMap { $0 }

  /// Contextual site tools keep their parent selected without becoming primary entries.
  static func primarySection(for section: WorkspaceSection) -> WorkspaceSection {
    switch section {
    case .images:
      return .sync
    case .writing, .library, .rss, .sync, .contentHealth:
      return section
    }
  }

  static func title(for section: WorkspaceSection) -> String {
    workspaceNavigationLocalizedString(section.displayNameLocalizationKey)
  }

  static func accessibilityLabel(for section: WorkspaceSection) -> LocalizedStringKey {
    workspaceNavigationLocalizedKey(section.displayNameLocalizationKey)
  }
}
