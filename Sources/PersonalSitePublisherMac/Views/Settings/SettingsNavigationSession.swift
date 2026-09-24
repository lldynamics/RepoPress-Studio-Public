import Foundation

/// Transient navigation state for one Settings workspace presentation.
///
/// Persisted tab restoration and search presentation deliberately remain
/// outside this value. This session only coordinates requests that detail
/// pages consume while the Settings view is on screen.
struct SettingsNavigationSession {
  struct RouteSelection: Equatable {
    /// The view must discard geometry recorded for the old page before the
    /// replacement page publishes its anchors.
    let clearsSubsectionAnchors: Bool

    /// Active navigation should remove a search cue. Native scrolling leaves
    /// the cue in place so it can remain visible while the result is shown.
    let dismissesSearchHighlight: Bool
  }

  private(set) var selectedRoute: SettingsRoute
  private(set) var navigationDestination: SettingsDestination?
  private(set) var navigationRequestID: UUID
  private(set) var healthDestination: SettingsConfigurationHealthDestination?
  private(set) var healthNavigationRequestID: UUID
  private(set) var detailScrollRequest: SettingsSubsectionScrollRequest?

  init(
    selectedRoute: SettingsRoute,
    navigationDestination: SettingsDestination? = nil
  ) {
    self.selectedRoute = selectedRoute
    self.navigationDestination = navigationDestination
    navigationRequestID = UUID()
    healthDestination = nil
    healthNavigationRequestID = UUID()
    detailScrollRequest = SettingsSubsectionScrollRequest(subsection: selectedRoute.subsection)
  }

  mutating func selectSidebarRoute(_ route: SettingsRoute) -> RouteSelection {
    clearFocusedDestination()
    return selectRoute(route)
  }

  mutating func selectDestination(
    _ destination: SettingsDestination,
    healthDestination: SettingsConfigurationHealthDestination?,
    targetRoute: SettingsRoute? = nil
  ) -> RouteSelection {
    self.healthDestination = healthDestination
    healthNavigationRequestID = UUID()
    navigationDestination = destination
    navigationRequestID = UUID()
    return selectRoute(targetRoute ?? .destination(destination))
  }

  mutating func applyWorkspaceNavigation(
    destination: SettingsDestination?,
    subsection: SettingsSubsection?
  ) -> RouteSelection? {
    healthDestination = nil
    healthNavigationRequestID = UUID()
    navigationDestination = destination
    navigationRequestID = UUID()
    guard let route = SettingsRoute.workspace(destination: destination, subsection: subsection)
    else {
      return nil
    }
    return selectRoute(route)
  }

  /// Invalidate detail-page focus requests after the sidebar takes control.
  /// New IDs ensure views can consume a cleared request even if a previous
  /// destination had the same payload.
  mutating func clearFocusedDestination() {
    healthDestination = nil
    healthNavigationRequestID = UUID()
    navigationDestination = nil
    navigationRequestID = UUID()
  }

  mutating func requestDetailScroll(to subsection: SettingsSubsection) {
    detailScrollRequest = SettingsSubsectionScrollRequest(subsection: subsection)
  }

  /// Records a native scroll observation without scheduling a compensating
  /// programmatic scroll.
  @discardableResult
  mutating func synchronizeManuallyScrolledSubsection(
    _ subsection: SettingsSubsection
  ) -> Bool {
    guard subsection.tab == selectedRoute.tab, subsection != selectedRoute.subsection else {
      return false
    }
    selectedRoute = .subsection(subsection)
    return true
  }

  private mutating func selectRoute(_ route: SettingsRoute) -> RouteSelection {
    let clearsSubsectionAnchors = selectedRoute.tab != route.tab
    selectedRoute = route
    requestDetailScroll(to: route.subsection)
    return RouteSelection(
      clearsSubsectionAnchors: clearsSubsectionAnchors,
      dismissesSearchHighlight: true
    )
  }
}
