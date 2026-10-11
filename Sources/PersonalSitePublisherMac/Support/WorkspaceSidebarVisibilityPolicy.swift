struct WorkspaceSidebarVisibilityPolicy {
  /// Primary routes keep one stable rail across responsive widths. Focus mode
  /// remains the only temporary mode that removes all workspace navigation.
  static func shouldShowNavigationRail(isFocusMode: Bool) -> Bool {
    !isFocusMode
  }

  /// Resolves the rendered sidebar state without changing the user's preference.
  /// Focus mode is a temporary override and always hides the sidebar.
  static func shouldShowSidebar(userWantsVisible: Bool, isFocusMode: Bool) -> Bool {
    userWantsVisible && !isFocusMode
  }

  /// The narrowest windows start rail-only, after the Inspector has already
  /// yielded at a wider threshold. Revealing the contextual list is a
  /// window-lifetime override, so the existing persisted preference and key
  /// keep their meaning when the window returns to a wider layout.
  static func shouldShowContextSidebar(
    userWantsVisible: Bool,
    isCompact: Bool,
    userRevealedInCompact: Bool,
    isFocusMode: Bool,
    inspectorTemporarilyReplacesSidebar: Bool
  ) -> Bool {
    userWantsVisible
      && (!isCompact || userRevealedInCompact)
      && !isFocusMode
      && !inspectorTemporarilyReplacesSidebar
  }
}
