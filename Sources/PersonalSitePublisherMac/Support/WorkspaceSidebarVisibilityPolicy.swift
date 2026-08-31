struct WorkspaceSidebarVisibilityPolicy {
  /// Resolves the rendered sidebar state without changing the user's preference.
  /// Focus mode is a temporary override and always hides the sidebar.
  static func shouldShowSidebar(userWantsVisible: Bool, isFocusMode: Bool) -> Bool {
    userWantsVisible && !isFocusMode
  }
}
