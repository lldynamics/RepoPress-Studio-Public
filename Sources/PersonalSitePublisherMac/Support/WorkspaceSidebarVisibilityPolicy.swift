struct WorkspaceSidebarVisibilityPolicy {
  /// Resolves the rendered sidebar state without changing the user's preference.
  /// Focus mode is a temporary override and always hides the sidebar.
  static func shouldShowSidebar(userWantsVisible: Bool, isFocusMode: Bool) -> Bool {
    userWantsVisible && !isFocusMode
  }

  /// A compact Inspector temporarily yields the full sidebar, but it must not
  /// strand people from the primary workspaces. This is deliberately separate
  /// from focus mode: focus and an explicit sidebar hide remain authoritative.
  static func shouldShowCompactNavigationRail(
    userWantsVisible: Bool,
    isFocusMode: Bool,
    inspectorTemporarilyReplacesSidebar: Bool
  ) -> Bool {
    userWantsVisible && !isFocusMode && inspectorTemporarilyReplacesSidebar
  }
}
