import PublishingWorkbenchCore
import SwiftUI

/// The five direct workspace routes shared by the full and compact navigators.
/// Keep visual order aligned with the command shortcut sequence.
enum WorkspaceNavigationRouteDescriptor {
  static let primaryRows: [[WorkspaceSection]] = [
    [.writing, .library],
    [.rss, .sync],
    [.contentHealth],
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
