import Foundation

public enum WorkbenchLayoutMode {
  /// The compact layout can hide the sidebar/inspector, so the window does
  /// not need the old wide-workspace minimum to remain usable.
  public static let minimumWindowWidth: CGFloat = 900
  public static let minimumWindowHeight: CGFloat = 620
  public static let defaultWindowWidth: CGFloat = 1473
  public static let defaultWindowHeight: CGFloat = 768
  public static let defaultSidebarWidth: CGFloat = 300
  public static let expandedWorkspaceWidth: CGFloat = 1180
  public static let minimumRSSReaderSplitWidth: CGFloat = 900
  public static let minimumInspectorWorkspaceWidth: CGFloat = 1180
  public static let minimumHTMLSourceInspectorWorkspaceWidth: CGFloat = 1240
  public static let minimumSplitInspectorWorkspaceWidth: CGFloat = 1580
  public static let minimumSplitSidebarWorkspaceWidth: CGFloat = 1100

  public static func isCompact(width: CGFloat) -> Bool {
    width < expandedWorkspaceWidth
  }

  public static func isCompactRSSReader(width: CGFloat) -> Bool {
    width < minimumRSSReaderSplitWidth
  }

  public static func allowsInspector(
    width: CGFloat,
    editorDisplayMode: EditorDisplayMode? = nil
  ) -> Bool {
    let minimumWidth = editorDisplayMode == .split
      ? minimumSplitInspectorWorkspaceWidth
      : minimumInspectorWorkspaceWidth
    return width >= minimumWidth
  }

  public static func prefersFocusedWriting(
    width: CGFloat,
    editorDisplayMode: EditorDisplayMode
  ) -> Bool {
    editorDisplayMode == .split && width < minimumSplitSidebarWorkspaceWidth
  }

  public static func sidebarWidth(
    storedWidth: CGFloat,
    workspaceWidth: CGFloat,
    centerMinimumWidth: CGFloat,
    inspectorPresented: Bool,
    minimumWidth: CGFloat = 240,
    maximumWidth: CGFloat = 380,
    inspectorMinimumWidth: CGFloat = 320
  ) -> CGFloat {
    let availableMaximum = inspectorPresented
      ? workspaceWidth - centerMinimumWidth - inspectorMinimumWidth
      : maximumWidth
    let responsiveMaximum = max(minimumWidth, min(maximumWidth, availableMaximum))
    return min(max(storedWidth, minimumWidth), responsiveMaximum)
  }
}
