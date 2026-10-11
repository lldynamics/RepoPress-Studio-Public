import Foundation
import PublishingWorkbenchCore

struct WorkspaceResponsiveLayoutSnapshot: Equatable, Sendable {
  enum Band: Equatable, Sendable {
    case constrained
    case compactInspector
    case standardInspector
  }

  let band: Band

  static let initial = WorkspaceResponsiveLayoutSnapshot(
    // The native inspector must wait for the first measured window width;
    // presenting it earlier can force a restored narrow window to grow.
    width: WorkbenchLayoutMode.minimumWindowWidth
  )

  init(width: CGFloat) {
    if WorkbenchLayoutMode.allowsInspector(width: width) {
      band = .standardInspector
    } else if WorkbenchLayoutMode.canManuallyRevealInspector(width: width) {
      band = .compactInspector
    } else {
      band = .constrained
    }
  }

  var isCompact: Bool {
    band == .constrained || band == .compactInspector
  }

  /// Hide the Inspector before the contextual article list. The list only
  /// starts collapsed in the narrowest band, and can still be opened there.
  var collapsesContextSidebar: Bool { band == .constrained }

  var allowsStandardInspector: Bool {
    band == .standardInspector
  }

  var canManuallyRevealInspector: Bool { band == .compactInspector }

  func canManuallyRevealInspector(for section: WorkspaceSection) -> Bool {
    canManuallyRevealInspector
  }
}
