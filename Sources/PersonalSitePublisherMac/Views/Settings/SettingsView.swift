import PublishingWorkbenchCore
import SwiftUI

struct SettingsView: View {
  let store: WorkbenchStore
  @ObservedObject private var settingsState: WorkbenchSettingsFeatureFacade
  @ObservedObject private var persistenceStatus: WorkbenchPersistenceFeatureFacade
  let rssStore: RSSReaderStore?
  @ObservedObject var launchCoordinator: WorkbenchLaunchCoordinator
  let closeWorkspace: (() -> Void)?
  let workspaceDestination: SettingsDestination?
  let workspaceSubsection: SettingsSubsection?
  let workspaceNavigationRequestID: UUID?
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  @AppStorage("scanRepositoryOnLaunch") private var scanRepositoryOnLaunch = false
  @AppStorage(WorkbenchInterfaceDensity.storageKey)
  private var interfaceDensityRawValue = WorkbenchInterfaceDensity.comfortable.rawValue
  // Compatibility bridge for callers that must request a destination before
  // the separate Settings scene exists. Every value is consumed and cleared.
  @AppStorage(SettingsNavigation.requestedTabStorageKey)
  private var requestedSettingsTabID = ""
  @AppStorage(SettingsNavigation.lastViewedTabStorageKey)
  private var lastViewedSettingsTabID = ""
  @State private var selectedRoute: SettingsRoute
  @State private var navigationDestination: SettingsDestination?
  @State private var navigationRequestID = UUID()
  @State private var healthDestination: SettingsConfigurationHealthDestination?
  @State private var healthNavigationRequestID = UUID()
  @State private var pendingSiteKind: SiteKind?
  @State private var searchText = ""
  @State private var detailScrollArrivalRequest: SettingsDetailScrollArrivalRequest?
  @State private var detailScrollHandoffGate = SettingsDetailScrollHandoffGate()
  @ScaledMetric(relativeTo: .body)
  private var scaledSidebarWidth = WorkbenchSettingsMetrics.sidebarWidth

  init(
    store: WorkbenchStore,
    rssStore: RSSReaderStore? = nil,
    launchCoordinator: WorkbenchLaunchCoordinator,
    closeWorkspace: (() -> Void)? = nil,
    workspaceDestination: SettingsDestination? = nil,
    workspaceSubsection: SettingsSubsection? = nil,
    workspaceNavigationRequestID: UUID? = nil
  ) {
    let initialRoute =
      SettingsRoute.workspace(
        destination: workspaceDestination,
        subsection: workspaceSubsection
      ) ?? Self.initialSettingsRoute()
    self.store = store
    _settingsState = ObservedObject(wrappedValue: store.settings)
    _persistenceStatus = ObservedObject(wrappedValue: store.persistenceStatus)
    self.rssStore = rssStore
    self.launchCoordinator = launchCoordinator
    self.closeWorkspace = closeWorkspace
    self.workspaceDestination = workspaceDestination
    self.workspaceSubsection = workspaceSubsection
    self.workspaceNavigationRequestID = workspaceNavigationRequestID
    _selectedRoute = State(initialValue: initialRoute)
    _navigationDestination = State(initialValue: workspaceDestination)
  }

  var body: some View {
    let _ = settingsState
    GeometryReader { geometry in
      let presentation = SettingsWorkspaceLayout.presentation(
        width: geometry.size.width,
        height: geometry.size.height,
        scaledSidebarWidth: scaledSidebarWidth,
        density: selectedInterfaceDensity
      )

      VStack(spacing: 0) {
        settingsWorkspaceHeader(presentation: presentation)
        Divider()

        settingsColumns(presentation: presentation)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .navigationTitle("设置")
    .onAppear {
      if closeWorkspace != nil || workspaceDestination != nil || workspaceSubsection != nil {
        applyWorkspaceNavigation()
      } else {
        applyRequestedSettingsTab(requestedSettingsTabID)
      }
      lastViewedSettingsTabID = selectedSettingsTab.id
      store.setAutomaticallyRefreshPreflightOnEdit(autoRunPreflight)
    }
    .onChange(of: requestedSettingsTabID) { _, requestedTabID in
      guard closeWorkspace == nil else { return }
      applyRequestedSettingsTab(requestedTabID)
    }
    .onChange(of: workspaceNavigationRequestID) { _, _ in
      applyWorkspaceNavigation()
    }
    .onChange(of: selectedRoute) { _, route in
      lastViewedSettingsTabID = route.tab.id
    }
    .onChange(of: autoRunPreflight) { _, newValue in
      store.setAutomaticallyRefreshPreflightOnEdit(newValue)
    }
    .sheet(item: $pendingSiteKind) { siteKind in
      SiteKindChangeConfirmationView(
        currentProfile: store.activeProfile,
        targetKind: siteKind,
        cancelAction: {
          pendingSiteKind = nil
        },
        confirmAction: {
          store.applySiteKindDefaults(siteKind)
          pendingSiteKind = nil
        }
      )
    }
  }

  private func settingsColumns(
    presentation: SettingsWorkspaceLayout.Presentation
  ) -> some View {
    HStack(spacing: 0) {
      settingsSidebar(presentation: presentation)
      Divider()

      VStack(spacing: 0) {
        SettingsDetailHeader(
          tab: selectedSettingsTab,
          subsection: selectedSubsection,
          minimumHeight: presentation.pageHeaderHeight
        )

        Divider()

        settingsPageContent
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        SettingsSaveStatusBarOverlay(
          isPresented: shouldShowSaveStatusBar,
          hasUnsavedChanges: persistenceStatus.hasUnsavedChanges,
          lastSaveError: persistenceStatus.lastSaveError,
          isRecoveryWriteProtected: persistenceStatus.isRecoveryWriteProtected,
          recoveryMessage: persistenceStatus.recoveryMessage,
          retry: store.save
        )
      }
      .background(Color(nsColor: .windowBackgroundColor))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("settings-content")
    }
  }

  private var matchingSearchItems: [SettingsSearchItem] {
    SettingsSearchIndex.search(query: searchText)
  }

  private var shouldShowSaveStatusBar: Bool {
    persistenceStatus.hasUnsavedChanges
      || persistenceStatus.lastSaveError != nil
      || persistenceStatus.isRecoveryWriteProtected
  }

  private func settingsWorkspaceHeader(
    presentation: SettingsWorkspaceLayout.Presentation
  ) -> some View {
    HStack(spacing: WorkbenchSpacing.section) {
      if let closeWorkspace {
        Button(action: closeWorkspace) {
          Label("返回工作台", systemImage: "chevron.left")
            .font(.callout.weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .keyboardShortcut(.cancelAction)
        .help("返回之前的工作区和文章")
        .accessibilityIdentifier("settings-return-to-workbench")
      } else {
        Label("设置", systemImage: "gearshape")
          .font(.headline)
      }

      Spacer(minLength: WorkbenchSpacing.content)
    }
    .padding(.horizontal, WorkbenchSpacing.content)
    .padding(.vertical, WorkbenchSpacing.card)
    .frame(minHeight: presentation.workspaceHeaderHeight)
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-workspace-header")
  }

  private func settingsSidebar(
    presentation: SettingsWorkspaceLayout.Presentation
  ) -> some View {
    return VStack(alignment: .leading, spacing: 0) {
      profileBar
        .padding(.horizontal, WorkbenchSpacing.content)
        .padding(.top, WorkbenchSpacing.content)
        .padding(.bottom, WorkbenchSpacing.card)

      settingsSidebarSearchField(minimumHeight: presentation.searchFieldHeight)
        .padding(.horizontal, WorkbenchSpacing.content)
        .padding(.bottom, WorkbenchSpacing.card)

      Divider()
        .padding(.horizontal, WorkbenchSpacing.content)

      SettingsNavigationList(
        searchText: searchText,
        searchItems: matchingSearchItems,
        selection: settingsRouteSelection,
        tabsNeedingAttention: tabsNeedingAttention,
        rowVerticalPadding: presentation.sidebarRowVerticalPadding,
        subsectionVerticalPadding: presentation.subsectionRowVerticalPadding,
        selectSearchItem: selectSettingsSearchItem
      )
    }
    .frame(width: presentation.primarySidebarWidth)
    .workbenchGlassContainer(material: .thinMaterial, drawsBorder: false)
  }

  private func settingsSidebarSearchField(minimumHeight: CGFloat) -> some View {
    HStack(spacing: WorkbenchSpacing.control) {
      Image(systemName: "magnifyingglass")
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      TextField("搜索所有设置", text: $searchText)
        .font(.callout)
        .textFieldStyle(.plain)
        .accessibilityLabel("搜索所有设置")
        .accessibilityIdentifier("settings-search-field")

      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("清除搜索")
        .accessibilityLabel("清除设置搜索")
      }
    }
    .padding(.horizontal, WorkbenchSpacing.card)
    .frame(minHeight: minimumHeight)
    .background(
      Color.primary.opacity(0.055),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
    }
  }

  private func selectSettingsSearchItem(_ item: SettingsSearchItem) {
    if let destination = item.destination {
      selectSettingsDestination(destination, healthDestination: nil)
    } else {
      selectTopLevelSettingsTab(item.tab)
    }
    if let subsection = SettingsSubsection.section(forSearchItemID: item.id),
      subsection.tab == item.tab
    {
      selectedRoute = .subsection(subsection)
    }
    searchText = ""
  }

  private var tabsNeedingAttention: Set<SettingsTab> {
    Set(SettingsTab.allCases.filter(tabNeedsAttention))
  }

  private func tabNeedsAttention(_ tab: SettingsTab) -> Bool {
    switch tab {
    case .configurationStatus:
      let profile = store.activeProfile
      let isRepoReady = profile.localRepositoryRootURL != nil
      let isRulesReady =
        !profile.markdownPathPattern.trimmedForPublishing.isEmpty
        && !profile.imagePathPattern.trimmedForPublishing.isEmpty
        && !profile.publicImagePathPattern.trimmedForPublishing.isEmpty
        && !profile.dateFormat.trimmedForPublishing.isEmpty
      return !isRepoReady || !isRulesReady
    case .token:
      let accessState = store.repositoryTokenAvailability.accessState
      let hasRemoteTarget =
        !store.activeProfile.repoOwner.trimmedForPublishing.isEmpty
        && !store.activeProfile.repoName.trimmedForPublishing.isEmpty
      return accessState == .accessFailed || (hasRemoteTarget && accessState != .available)
    case .ai:
      let config = store.aiProviderConfig(for: store.activeProfile)
      // Codex account/login state is fetched by the account section itself;
      // the sidebar cannot safely infer a live account from Keychain state.
      guard !config.usesCodexAppServer else { return false }
      let missingConnectionValue =
        config.normalizedBaseURL.isEmpty || config.normalizedModel.isEmpty
      let missingAPIKey = Self.shouldOpenAIKeyConnection(
        for: config,
        tokenAvailability: store.ai.tokenAvailability
      )
      return missingConnectionValue || missingAPIKey
    default:
      return false
    }
  }

  private var profileBar: some View {
    SettingsProfileBar(
      profiles: store.publishingProfiles,
      activeProfile: store.activeProfile,
      activeProfileIDBinding: activeProfileIDBinding,
      activeProfileBinding: activeProfileBinding,
      createProfile: {
        _ = store.createProfile()
      },
      duplicateActiveProfile: {
        _ = store.duplicateActiveProfile()
      },
      deleteActiveProfile: {
        _ = store.deleteActiveProfile()
      },
      activeProfileDraftCount: store.activeProfileDraftCount,
      recentlyDeletedProfile: store.recentlyDeletedProfile,
      restoreRecentlyDeletedProfile: {
        _ = store.restoreRecentlyDeletedProfile()
      }
    )
  }

  private var settingsContext: SettingsContext {
    SettingsContext(
      store: store,
      rssStore: rssStore,
      launchCoordinator: launchCoordinator,
      activeProfileBinding: activeProfileBinding,
      autoRunPreflightBinding: autoRunPreflightBinding,
      scanRepositoryOnLaunch: $scanRepositoryOnLaunch,
      siteKindBinding: siteKindBinding,
      healthDestination: healthDestination,
      healthNavigationRequestID: healthNavigationRequestID,
      navigationDestination: navigationDestination,
      navigationRequestID: navigationRequestID,
      selectConfigurationHealthDestination: openConfigurationHealthDestination
    )
  }

  private var selectedSettingsTab: SettingsTab {
    selectedRoute.tab
  }

  private var selectedSubsection: SettingsSubsection {
    selectedRoute.subsection
  }

  /// Each top-level page owns exactly one native vertical scroll container:
  /// Form-backed pages use their Form, while data management owns a ScrollView.
  @ViewBuilder
  private var settingsPageContent: some View {
    switch selectedSettingsTab.scrollOwnership {
    case .nativeForm, .nativeScrollView:
      selectedSettingsTab.makeContent(context: settingsContext)
        .environment(\.settingsSubsection, selectedSubsection)
        .frame(maxWidth: selectedSettingsTab.contentMaxWidth, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
          SettingsDetailScrollBridge(
            arrivalRequest: detailScrollArrivalRequest,
            handoffGate: detailScrollHandoffGate,
            onBoundaryCrossing: handleDetailScrollBoundaryCrossing
          )
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
        .id(selectedSubsection.id)
    }
  }

  private var settingsRouteSelection: Binding<SettingsRoute> {
    Binding(
      get: { selectedRoute },
      set: { route in
        clearFocusedSettingsDestination()
        detailScrollArrivalRequest = SettingsDetailScrollArrivalRequest(edge: .top)
        selectedRoute = route
      }
    )
  }

  private static func initialSettingsRoute() -> SettingsRoute {
    SettingsRoute.restored(
      lastViewedID: UserDefaults.standard.string(
        forKey: SettingsNavigation.lastViewedTabStorageKey
      )
    )
  }

  private func applyWorkspaceNavigation() {
    healthDestination = nil
    healthNavigationRequestID = UUID()
    navigationDestination = workspaceDestination
    navigationRequestID = UUID()
    if let route = SettingsRoute.workspace(
      destination: workspaceDestination,
      subsection: workspaceSubsection
    ) {
      detailScrollArrivalRequest = SettingsDetailScrollArrivalRequest(edge: .top)
      selectedRoute = route
    }
  }

  private func handleDetailScrollBoundaryCrossing(
    _ direction: SettingsDetailScrollBoundaryDirection
  ) {
    let target: SettingsSubsection?
    switch direction {
    case .previous:
      target = selectedSubsection.previous
    case .next:
      target = selectedSubsection.next
    }
    guard let target else { return }

    clearFocusedSettingsDestination()
    detailScrollArrivalRequest = SettingsDetailScrollArrivalRequest(edge: direction.arrival)
    selectedRoute = .subsection(target)
  }

  private func clearFocusedSettingsDestination() {
    healthDestination = nil
    healthNavigationRequestID = UUID()
    navigationDestination = nil
    navigationRequestID = UUID()
  }

  private var selectedInterfaceDensity: WorkbenchInterfaceDensity {
    WorkbenchInterfaceDensity.resolved(rawValue: interfaceDensityRawValue)
  }

  private var activeProfileBinding: Binding<SiteProfile> {
    Binding(
      get: { store.activeProfile },
      set: { profile in
        store.updateActiveProfile(profile)
        store.scheduleAutosave()
      }
    )
  }

  private var activeProfileIDBinding: Binding<UUID> {
    Binding(
      get: { store.activeProfileID },
      set: { store.selectProfile($0) }
    )
  }

  private var autoRunPreflightBinding: Binding<Bool> {
    Binding(
      get: { store.automaticallyRefreshPreflightOnEdit },
      set: { value in
        autoRunPreflight = value
        store.setAutomaticallyRefreshPreflightOnEdit(value)
      }
    )
  }

  private var siteKindBinding: Binding<SiteKind> {
    Binding(
      get: { store.activeProfile.siteKind },
      set: { kind in
        guard kind != store.activeProfile.siteKind else { return }
        pendingSiteKind = kind
      }
    )
  }

  private func openConfigurationHealthDestination(
    _ destination: SettingsConfigurationHealthDestination
  ) {
    healthDestination = destination
    healthNavigationRequestID = UUID()
    selectSettingsDestination(
      Self.settingsDestination(for: destination),
      healthDestination: destination
    )
  }

  private func applyRequestedSettingsTab(_ requestedTabID: String) {
    guard !requestedTabID.isEmpty else {
      return
    }
    guard let destination = SettingsDestination(requestedID: requestedTabID) else {
      requestedSettingsTabID = ""
      return
    }

    let compatibilityHealthDestination: SettingsConfigurationHealthDestination?
    var resolvedDestination = destination
    switch destination {
    case .rules(.paths):
      compatibilityHealthDestination = .defaultRules
    case .token(.repository):
      compatibilityHealthDestination = .repositoryToken
    case .ai(.credentials):
      let config = store.aiProviderConfig(for: store.activeProfile)
      if Self.shouldOpenAIKeyConnection(
        for: config,
        tokenAvailability: store.ai.tokenAvailability
      ) {
        compatibilityHealthDestination = .aiKey
        resolvedDestination = .ai(.connection)
      } else {
        compatibilityHealthDestination = nil
      }
    default:
      compatibilityHealthDestination = nil
    }
    selectSettingsDestination(
      resolvedDestination,
      healthDestination: compatibilityHealthDestination
    )
    if let requestedRoute = SettingsRoute.requestedID(requestedTabID),
      requestedRoute.tab == resolvedDestination.tab
    {
      selectedRoute = requestedRoute
    }
    requestedSettingsTabID = ""
  }

  private func selectTopLevelSettingsTab(_ tab: SettingsTab) {
    selectSettingsDestination(.tab(tab), healthDestination: nil)
  }

  private func selectSettingsDestination(
    _ destination: SettingsDestination,
    healthDestination: SettingsConfigurationHealthDestination?
  ) {
    self.healthDestination = healthDestination
    healthNavigationRequestID = UUID()
    navigationDestination = destination
    navigationRequestID = UUID()
    detailScrollArrivalRequest = SettingsDetailScrollArrivalRequest(edge: .top)
    selectedRoute = .destination(destination)
  }

  static func settingsDestination(
    for healthDestination: SettingsConfigurationHealthDestination
  ) -> SettingsDestination {
    switch healthDestination {
    case .repository:
      return .token(.repository)
    case .defaultRules:
      return .rules(.paths)
    case .repositoryToken:
      return .token(.repository)
    case .aiKey:
      return .ai(.connection)
    }
  }

  static func shouldOpenAIKeyConnection(
    for config: AIProviderConfig,
    tokenAvailability: KeychainTokenAvailability
  ) -> Bool {
    !config.usesCodexAppServer
      && config.requiresAPIKey
      && !tokenAvailability.hasToken
  }
}

private struct SettingsSaveStatusBarOverlay: View {
  let isPresented: Bool
  let hasUnsavedChanges: Bool
  let lastSaveError: String?
  let isRecoveryWriteProtected: Bool
  let recoveryMessage: String?
  let retry: () -> Void

  var body: some View {
    if isPresented {
      VStack(spacing: 0) {
        Divider()
        SettingsSaveStatusBar(
          hasUnsavedChanges: hasUnsavedChanges,
          lastSaveError: lastSaveError,
          isRecoveryWriteProtected: isRecoveryWriteProtected,
          recoveryMessage: recoveryMessage,
          retry: retry
        )
      }
    }
  }
}

enum SettingsSidebarPresentation {
  static let minimumWidth: CGFloat = 232
  static let maximumWidth: CGFloat = 272
  static var attentionBadgeTitle: String { String(localized: "需配置") }
  static var attentionAccessibilityValue: String { String(localized: "需要配置") }

  static func clampedWidth(_ scaledWidth: CGFloat) -> CGFloat {
    min(max(scaledWidth, minimumWidth), maximumWidth)
  }
}

enum SettingsWorkspaceLayout {
  struct Presentation {
    let usesCompactVerticalMetrics: Bool
    let primarySidebarWidth: CGFloat
    let workspaceHeaderHeight: CGFloat
    let searchFieldHeight: CGFloat
    let pageHeaderHeight: CGFloat
    let sidebarRowVerticalPadding: CGFloat
    let subsectionRowVerticalPadding: CGFloat
  }

  static let compactHeightThreshold: CGFloat = 720

  static func presentation(
    width: CGFloat,
    height: CGFloat = WorkbenchSettingsMetrics.idealHeight,
    scaledSidebarWidth: CGFloat,
    density: WorkbenchInterfaceDensity = .comfortable
  ) -> Presentation {
    let compactPrimaryWidth = SettingsSidebarPresentation.clampedWidth(scaledSidebarWidth)
    let usesCompactVerticalMetrics =
      density == .compact || height < compactHeightThreshold

    return Presentation(
      usesCompactVerticalMetrics: usesCompactVerticalMetrics,
      primarySidebarWidth: compactPrimaryWidth,
      workspaceHeaderHeight: usesCompactVerticalMetrics ? 48 : 52,
      searchFieldHeight: usesCompactVerticalMetrics ? 32 : 36,
      pageHeaderHeight: usesCompactVerticalMetrics ? 88 : 96,
      sidebarRowVerticalPadding: usesCompactVerticalMetrics ? 4 : 6,
      subsectionRowVerticalPadding: usesCompactVerticalMetrics ? 3 : 5
    )
  }

  static func availableDetailWidth(
    totalWidth: CGFloat,
    presentation: Presentation
  ) -> CGFloat {
    totalWidth - presentation.primarySidebarWidth
  }
}
