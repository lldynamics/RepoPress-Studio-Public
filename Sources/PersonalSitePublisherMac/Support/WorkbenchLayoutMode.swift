import Foundation

public enum WorkbenchLayoutMode {
  /// The compact layout can hide the sidebar/inspector, so the window does
  /// not need the old wide-workspace minimum to remain usable.
  public static let minimumWindowWidth: CGFloat = 900
  public static let minimumWindowHeight: CGFloat = 620
  public static let defaultWindowWidth: CGFloat = 1473
  public static let defaultWindowHeight: CGFloat = 768
  public static let defaultSidebarWidth: CGFloat = 300
  public static let primaryNavigationRailWidth: CGFloat = 62
  public static let workspaceSplitDividerBudget: CGFloat = 2
  /// Every Inspector tab shares this user-resizable range so switching tabs
  /// never resizes the list; the ideal width is what a new window opens with.
  public static let inspectorMinimumWidth: CGFloat = 280
  public static let inspectorIdealWidth: CGFloat = 320
  public static let inspectorMaximumWidth: CGFloat = 560
  /// Rail + dividers + default contextual sidebar + editor minimum + the
  /// Inspector at its ideal width. The sidebar yields down to its 240 pt
  /// minimum when the user widens the Inspector. Below this width the
  /// contextual column and Inspector remain on-demand so the editor is never
  /// squeezed below 560 pt.
  public static let expandedWorkspaceWidth: CGFloat =
    primaryNavigationRailWidth + workspaceSplitDividerBudget + defaultSidebarWidth + 560
    + inspectorIdealWidth
  public static let minimumCompactInspectorWorkspaceWidth: CGFloat = 960
  public static let minimumRSSReaderSplitWidth: CGFloat = 900
  public static let minimumInspectorWorkspaceWidth: CGFloat = expandedWorkspaceWidth

  public static func isCompact(width: CGFloat) -> Bool {
    width < expandedWorkspaceWidth
  }

  public static func isCompactRSSReader(width: CGFloat) -> Bool {
    width < minimumRSSReaderSplitWidth
  }

  public static func allowsInspector(width: CGFloat) -> Bool {
    width >= minimumInspectorWorkspaceWidth
  }

  /// A compact writing window can still reveal the Inspector on demand by
  /// temporarily yielding the primary sidebar.
  public static func canManuallyRevealInspector(width: CGFloat) -> Bool {
    guard !allowsInspector(width: width) else {
      return false
    }
    return width >= minimumCompactInspectorWorkspaceWidth
  }

  /// Without the Inspector, the sidebar may claim at most this share of the
  /// workspace, so a narrow window gives its width to the editor instead of
  /// keeping a fixed 300 pt.
  public static let sidebarMaximumWorkspaceFraction: CGFloat = 0.26

  public static func sidebarWidth(
    storedWidth: CGFloat,
    workspaceWidth: CGFloat,
    centerMinimumWidth: CGFloat,
    inspectorPresented: Bool,
    minimumWidth: CGFloat = 240,
    maximumWidth: CGFloat = 380,
    inspectorMinimumWidth: CGFloat = 320
  ) -> CGFloat {
    // With the Inspector open, the center and Inspector minimums already bound
    // the sidebar; the proportional cap only applies to the two-column layout.
    let workspaceContentWidth = max(
      0,
      workspaceWidth - primaryNavigationRailWidth - workspaceSplitDividerBudget
    )
    let availableMaximum =
      inspectorPresented
      ? workspaceContentWidth - centerMinimumWidth - inspectorMinimumWidth
      : min(maximumWidth, workspaceContentWidth * sidebarMaximumWorkspaceFraction)
    let responsiveMaximum = max(minimumWidth, min(maximumWidth, availableMaximum))
    return min(max(storedWidth, minimumWidth), responsiveMaximum)
  }
}
