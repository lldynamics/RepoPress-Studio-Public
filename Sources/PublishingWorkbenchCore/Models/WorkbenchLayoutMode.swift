import Foundation

public enum WorkbenchLayoutMode {
  public static let minimumWindowWidth: CGFloat = 980
  public static let defaultWindowWidth: CGFloat = 1440
  public static let defaultWindowHeight: CGFloat = 900
  public static let expandedWorkspaceWidth: CGFloat = 1180
  public static let minimumInspectorWorkspaceWidth: CGFloat = 1180
  public static let minimumSplitInspectorWorkspaceWidth: CGFloat = 1580
  public static let minimumSplitSidebarWorkspaceWidth: CGFloat = 1100

  public static func isCompact(width: CGFloat) -> Bool {
    width < expandedWorkspaceWidth
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
}
