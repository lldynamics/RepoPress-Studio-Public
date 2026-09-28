import PublishingWorkbenchCore
import SwiftUI

/// Visible workspaces shared by the full and compact navigators.
/// Command routes keep their existing shortcuts independently of visual order.
enum WorkspaceNavigationRouteDescriptor {
  static let primarySections: [WorkspaceSection] = [
    .writing, .library, .rss, .images, .sync,
  ]

  /// Contextual site tools keep their parent selected without becoming primary entries.
  static func primarySection(for section: WorkspaceSection) -> WorkspaceSection {
    section == .contentHealth ? .sync : section
  }

  static func title(for section: WorkspaceSection) -> String {
    workspaceNavigationLocalizedString(section.displayNameLocalizationKey)
  }

  static func accessibilityLabel(for section: WorkspaceSection) -> LocalizedStringKey {
    workspaceNavigationLocalizedKey(section.displayNameLocalizationKey)
  }

  static func checksHint(for section: WorkspaceSection, issueCount: Int?) -> String {
    guard section == .sync, let issueCount, issueCount > 0 else { return "" }
    return String(localized: "上次站点检查发现 \(issueCount) 个问题")
  }
}
