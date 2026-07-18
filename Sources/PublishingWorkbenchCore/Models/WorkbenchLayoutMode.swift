import Foundation

public enum WorkbenchLayoutMode {
  public static let minimumWindowWidth: CGFloat = 980
  public static let expandedWorkspaceWidth: CGFloat = 1180
  public static let minimumInspectorWorkspaceWidth: CGFloat = 1180

  public static func isCompact(width: CGFloat) -> Bool {
    width < expandedWorkspaceWidth
  }

  public static func allowsInspector(width: CGFloat) -> Bool {
    width >= minimumInspectorWorkspaceWidth
  }
}
