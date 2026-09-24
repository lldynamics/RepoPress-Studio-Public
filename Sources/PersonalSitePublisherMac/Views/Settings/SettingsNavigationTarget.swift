/// Resolves transient Settings entry points without changing the persisted tab IDs.
/// The view owns mutations and scrolling; this value keeps route decisions together.
struct SettingsNavigationTarget {
  let destination: SettingsDestination
  let route: SettingsRoute
  let healthDestination: SettingsConfigurationHealthDestination?

  static func searchItem(_ item: SettingsSearchItem) -> Self {
    let subsection = SettingsSubsection.section(forSearchItemID: item.id)
    let destination = item.destination ?? .tab(item.tab)
    return Self(
      destination: destination,
      route: subsection.map(SettingsRoute.subsection)
        ?? item.destination.map(SettingsRoute.destination)
        ?? .tab(item.tab),
      healthDestination: nil
    )
  }

  static func requestedID(
    _ requestedID: String,
    shouldOpenAIKeyConnection: () -> Bool
  ) -> Self? {
    guard let requestedDestination = SettingsDestination(requestedID: requestedID) else {
      return nil
    }

    let healthDestination: SettingsConfigurationHealthDestination?
    let destination: SettingsDestination
    switch requestedDestination {
    case .rules(.paths):
      destination = requestedDestination
      healthDestination = .defaultRules
    case .token(.repository):
      destination = requestedDestination
      healthDestination = .repositoryToken
    case .ai(.credentials) where shouldOpenAIKeyConnection():
      destination = .ai(.connection)
      healthDestination = .aiKey
    default:
      destination = requestedDestination
      healthDestination = nil
    }

    let requestedRoute = SettingsRoute.requestedID(requestedID)
    let route =
      requestedRoute.flatMap { requestedRoute in
        requestedRoute.tab == destination.tab ? requestedRoute : nil
      } ?? .destination(destination)
    return Self(
      destination: destination,
      route: route,
      healthDestination: healthDestination
    )
  }
}
