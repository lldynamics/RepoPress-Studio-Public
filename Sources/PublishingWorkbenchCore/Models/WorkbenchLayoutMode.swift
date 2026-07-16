import Foundation

public enum WorkbenchLayoutMode {
  public static let minimumWindowWidth: CGFloat = 980
  public static let expandedWorkspaceWidth: CGFloat = 1180
  public static let minimumAuxiliaryPanelWorkspaceWidth: CGFloat = 1040
  public static let comfortableSplitWorkspaceWidth: CGFloat = 2100

  public static func isCompact(width: CGFloat) -> Bool {
    width < expandedWorkspaceWidth
  }

  public static func shouldAutoHideAuxiliaryPanels(
    editorDisplayMode: EditorDisplayMode,
    width: CGFloat
  ) -> Bool {
    width < minimumAuxiliaryPanelWorkspaceWidth ||
      (editorDisplayMode == .split && width < comfortableSplitWorkspaceWidth)
  }
}
