import Foundation
import PublishingWorkbenchCore

struct WorkspaceResponsiveLayoutSnapshot: Equatable {
  enum Band: Equatable {
    case constrained
    case compactInspector
    case standardInspector
    case htmlSourceInspector
  }

  let band: Band

  static let initial = WorkspaceResponsiveLayoutSnapshot(
    width: WorkbenchLayoutMode.expandedWorkspaceWidth
  )

  init(width: CGFloat) {
    if width >= WorkbenchLayoutMode.minimumHTMLSourceInspectorWorkspaceWidth {
      band = .htmlSourceInspector
    } else if WorkbenchLayoutMode.allowsInspector(width: width) {
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
    band == .standardInspector || band == .htmlSourceInspector
  }

  var allowsHTMLSourceInspector: Bool { band == .htmlSourceInspector }
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
