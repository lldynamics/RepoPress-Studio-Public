import PublishingWorkbenchCore
import SwiftUI

/// Direct workspace routes shared by the full and compact navigators.
/// Keep visual order aligned with the command shortcut sequence.
enum WorkspaceNavigationRouteDescriptor {
  static let primarySections = WorkspaceVisibilityPolicy.commandMenuPrimarySections

  /// Contextual site tools keep their parent selected without becoming primary entries.
  static func primarySection(for section: WorkspaceSection) -> WorkspaceSection {
    section
  }

  static func title(for section: WorkspaceSection) -> String {
    workspaceNavigationLocalizedString(section.displayNameLocalizationKey)
  }

  static func accessibilityLabel(for section: WorkspaceSection) -> LocalizedStringKey {
    workspaceNavigationLocalizedKey(section.displayNameLocalizationKey)
  }
}
