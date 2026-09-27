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
    width: WorkbenchLayoutMode.expandedWorkspaceWidth
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

  var allowsStandardInspector: Bool {
    band == .standardInspector
  }

  var canManuallyRevealInspector: Bool { band == .compactInspector }

  func canManuallyRevealInspector(for section: WorkspaceSection) -> Bool {
    canManuallyRevealInspector && [.writing, .library, .rss].contains(section)
  }
}

/// A single value keeps the inspector's min/ideal/max constraints coherent while
/// moving between article and AI collaboration surfaces.
struct WorkspaceInspectorWidthState: Equatable {
  let constraints: WorkspaceInspectorColumnWidths
  let preferredWidth: CGFloat

  init(isAIAssistantPresented: Bool) {
    constraints = WorkspaceInspectorColumnWidthPolicy.widths(
      isAIAssistantPresented: isAIAssistantPresented
    )
    preferredWidth =
      isAIAssistantPresented
      ? constraints.ideal
      : constraints.minimum
  }
}

/// The reset command only earns space in the Inspector once the user has
/// actually resized the column; at the default width it would just crowd the
/// panel header.
enum WorkspaceInspectorWidthResetPolicy {
  static let tolerance: CGFloat = 8

  static func showsResetControl(measuredWidth: CGFloat?, defaultWidth: CGFloat?) -> Bool {
    guard let measuredWidth, let defaultWidth, measuredWidth > 0 else { return false }
    return abs(measuredWidth - defaultWidth) > tolerance
  }
}
