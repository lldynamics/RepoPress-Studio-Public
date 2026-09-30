import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

struct SettingsView: View {
  @WorkspaceModuleVisibilityStorage private var moduleVisibility
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let store: WorkbenchStore
  @ObservedObject private var settingsState: WorkbenchSettingsFeatureFacade
  @ObservedObject private var persistenceStatus: WorkbenchPersistenceFeatureFacade
  let rssStore: RSSReaderStore?
  @ObservedObject var launchCoordinator: WorkbenchLaunchCoordinator
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  @AppStorage("scanRepositoryOnLaunch") private var scanRepositoryOnLaunch = false
  @AppStorage(WorkbenchInterfaceDensity.storageKey)
  private var interfaceDensityRawValue = WorkbenchInterfaceDensity.comfortable.rawValue
  // One-shot requests can arrive before the native Settings scene exists.
  // Every value is consumed and cleared independently of tab restoration.
  @AppStorage(SettingsNavigation.requestedTabStorageKey)
  private var requestedSettingsTabID = ""
  @AppStorage(SettingsNavigation.lastViewedTabStorageKey)
  private var lastViewedSettingsTabID = ""
  @State private var navigationSession: SettingsNavigationSession
  @State private var pendingSiteKind: SiteKindChangeConfirmation?
  @State private var searchSession = SettingsSearchSession()
  @FocusState private var isSearchFocused: Bool
  @State private var subsectionAnchorFrames: [SettingsSubsection: CGRect] = [:]
  @State private var detailScrollObservation = 0
  @State private var detailScrollIsAtBottom = false
  @State private var appliedScrollRequestID: UUID?
  @ScaledMetric(relativeTo: .body)
  private var scaledSidebarWidth = WorkbenchSettingsMetrics.sidebarWidth

  init(
    store: WorkbenchStore,
    rssStore: RSSReaderStore? = nil,
    launchCoordinator: WorkbenchLaunchCoordinator
  ) {
    self.store = store
    _settingsState = ObservedObject(wrappedValue: store.settings)
    _persistenceStatus = ObservedObject(wrappedValue: store.persistenceStatus)
    self.rssStore = rssStore
    self.launchCoordinator = launchCoordinator
    _navigationSession = State(
      initialValue: SettingsNavigationSession(
        selectedRoute: Self.initialSettingsRoute()
      )
    )
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
        settingsColumns(presentation: presentation)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .navigationTitle("设置")
    .onAppear {
      applyRequestedSettingsTab(requestedSettingsTabID)
      lastViewedSettingsTabID = selectedSettingsTab.id
      store.setAutomaticallyRefreshPreflightOnEdit(autoRunPreflight)
      requestDetailScroll(to: selectedSubsection)
    }
    .onChange(of: requestedSettingsTabID) { _, requestedTabID in
      applyRequestedSettingsTab(requestedTabID)
    }
    .onChange(of: navigationSession.selectedRoute) { _, route in
      lastViewedSettingsTabID = route.tab.id
    }
    .onChange(of: moduleVisibility, initial: true) { _, visibility in
      let route = visibility.resolvedSettingsRoute(navigationSession.selectedRoute)
      if route != navigationSession.selectedRoute {
        apply(navigationSession.selectSidebarRoute(route))
      }
      if let rssStore {
        launchCoordinator.startBackgroundRefreshIfNeeded(for: rssStore)
      }
    }
    .onChange(of: autoRunPreflight) { _, newValue in
      store.setAutomaticallyRefreshPreflightOnEdit(newValue)
    }
    .onChange(of: store.activeProfile) {
      pendingSiteKind = nil
    }
    .task(id: searchSession.highlight?.id) {
      guard let highlightID = searchSession.highlight?.id else { return }
      do {
        try await Task.sleep(for: .seconds(3))
        searchSession.dismissHighlight(id: highlightID)
      } catch {
        // A newer search result or navigation cancels the old cue.
      }
    }
    .sheet(item: $pendingSiteKind) { confirmation in
      SiteKindChangeConfirmationView(
        confirmation: confirmation,
        cancelAction: { pendingSiteKind = nil },
        confirmAction: {
          store.applySiteKindDefaults(confirmation.siteKind, expectedTarget: confirmation.target)
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
          retry: {
            Task { await store.retryPendingProjectFileWrites() }
          }
        )
        ProjectFileSaveRecoveryBanner(
          summary: persistenceStatus.siteDraftFileSaveFailureSummary,
          isRetrying: persistenceStatus.isRetryingProjectFileWrites,
          recover: { ProjectFileSaveRecoveryPanel.present(for: store) }
        )
      }
      .background(Color(nsColor: .windowBackgroundColor))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("settings-content")
    }
  }

  private var matchingSearchItems: [SettingsSearchItem] {
    SettingsSearchIndex.search(query: searchSession.query)
      .filter { moduleVisibility.allowsSettingsTab($0.tab) }
  }

  private var shouldShowSaveStatusBar: Bool {
    persistenceStatus.hasUnsavedChanges
      || persistenceStatus.lastSaveError != nil
      || persistenceStatus.isRecoveryWriteProtected
  }

  private func settingsSidebar(
    presentation: SettingsWorkspaceLayout.Presentation
  ) -> some View {
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: WorkbenchSpacing.card) {
        settingsSidebarSearchField(minimumHeight: presentation.searchFieldHeight)
      }
      .padding(.horizontal, WorkbenchSpacing.content)
      .padding(.top, WorkbenchSpacing.content)
      .padding(.bottom, WorkbenchSpacing.card)

      if selectedSettingsTab.isSiteScoped {
        profileBar
          .padding(.horizontal, WorkbenchSpacing.content)
          .padding(.bottom, WorkbenchSpacing.card)
      }

      if searchSession.canReturnToResults {
        Button {
          searchSession.showResults()
          isSearchFocused = true
        } label: {
          Label("返回搜索结果", systemImage: "arrow.uturn.backward")
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(workbenchAccentColor)
        .padding(.horizontal, WorkbenchSpacing.content)
        .padding(.bottom, WorkbenchSpacing.card)
        .accessibilityIdentifier("settings-return-to-search-results")
      }

      Divider()
        .padding(.horizontal, WorkbenchSpacing.content)

      SettingsNavigationList(
        searchText: searchSession.sidebarQuery,
        searchItems: matchingSearchItems,
        groups: SettingsTaskGroup.allCases,
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

      TextField(
        "搜索所有设置",
        text: Binding(
          get: { searchSession.query },
          set: { searchSession.updateQuery($0) }
        )
      )
      .font(.callout)
      .textFieldStyle(.plain)
      .focused($isSearchFocused)
      .accessibilityLabel("搜索所有设置")
      .accessibilityIdentifier("settings-search-field")

      if !searchSession.query.isEmpty {
        Button {
          searchSession.updateQuery("")
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("清除搜索")
        .accessibilityLabel("清除设置搜索")
        .accessibilityIdentifier("settings-clear-search")
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
    let target = SettingsNavigationTarget.searchItem(item)
    selectSettingsDestination(
      target.destination,
      healthDestination: target.healthDestination,
      targetRoute: target.route
    )
    searchSession.open(item)
    isSearchFocused = false
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
      healthDestination: navigationSession.healthDestination,
      healthNavigationRequestID: navigationSession.healthNavigationRequestID,
      navigationDestination: navigationSession.navigationDestination,
      navigationRequestID: navigationSession.navigationRequestID,
      selectedSubsection: selectedSubsection,
      selectConfigurationHealthDestination: openConfigurationHealthDestination,
      selectSettingsDestination: openSettingsDestination
    )
  }

  private var selectedSettingsTab: SettingsTab {
    navigationSession.selectedRoute.tab
  }

  private var selectedSubsection: SettingsSubsection {
    navigationSession.selectedRoute.subsection
  }

  /// Each top-level page owns one native scroll container: its Form, or a
  /// ScrollView for site overview and data management.
  @ViewBuilder
  private var settingsPageContent: some View {
    ScrollViewReader { proxy in
      selectedSettingsTab.makeContent(context: settingsContext)
        // Child pages render every subsection for their selected tab. Keep the
        // legacy environment value stable within that tab so a manual sidebar
        // sync cannot rebuild page content.
        .environment(
          \.settingsSubsection,
          SettingsSubsection.defaultSection(for: selectedSettingsTab)
        )
        .frame(maxWidth: selectedSettingsTab.contentMaxWidth, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: SettingsSubsectionAnchor.coordinateSpaceName)
        .overlay {
          SettingsSearchHighlightOverlay(
            highlight: searchSession.highlight,
            anchorFrames: subsectionAnchorFrames
          )
        }
        .onPreferenceChange(SettingsSubsectionAnchorFramePreferenceKey.self) { frames in
          subsectionAnchorFrames = frames
          if let request = navigationSession.detailScrollRequest,
            appliedScrollRequestID != request.id
          {
            scroll(proxy, to: request)
          } else {
            synchronizeVisibleSubsection()
          }
        }
        .onChange(of: detailScrollObservation) { _, _ in
          synchronizeVisibleSubsection()
        }
        .onChange(of: navigationSession.detailScrollRequest) { _, request in
          guard let request else { return }
          scroll(proxy, to: request)
        }
        .onAppear {
          if let detailScrollRequest = navigationSession.detailScrollRequest {
            scroll(proxy, to: detailScrollRequest)
          }
        }
        .overlay(alignment: .top) {
          SettingsDetailScrollBridge { position in
            detailScrollIsAtBottom = position.isAtBottom
            detailScrollObservation &+= 1
          }
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
    }
    // The identity belongs to the top-level tab only. Subsection selection is
    // an in-page scroll request, never a replacement of the detail content.
    .id(selectedSettingsTab.id)
  }

  private var settingsRouteSelection: Binding<SettingsRoute> {
    Binding(
      get: { navigationSession.selectedRoute },
      set: { route in
        apply(navigationSession.selectSidebarRoute(moduleVisibility.resolvedSettingsRoute(route)))
      }
    )
  }

  private static func initialSettingsRoute() -> SettingsRoute {
    WorkspaceModuleVisibility.load(defaults: .standard).resolvedSettingsRoute(
      SettingsRoute.restored(
        lastViewedID: UserDefaults.standard.string(
          forKey: SettingsNavigation.lastViewedTabStorageKey
        )
      )
    )
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
        pendingSiteKind = SiteKindChangeConfirmation(profile: store.activeProfile, siteKind: kind)
      }
    )
  }

  private func openConfigurationHealthDestination(
    _ destination: SettingsConfigurationHealthDestination
  ) {
    selectSettingsDestination(
      Self.settingsDestination(for: destination),
      healthDestination: destination
    )
  }

  private func openSettingsDestination(_ destination: SettingsDestination) {
    selectSettingsDestination(destination, healthDestination: nil)
  }

  private func applyRequestedSettingsTab(_ requestedTabID: String) {
    guard !requestedTabID.isEmpty else {
      return
    }
    guard
      let target = SettingsNavigationTarget.requestedID(
        requestedTabID,
        shouldOpenAIKeyConnection: {
          let config = store.aiProviderConfig(for: store.activeProfile)
          return Self.shouldOpenAIKeyConnection(
            for: config,
            tokenAvailability: store.ai.tokenAvailability
          )
        }
      )
    else {
      requestedSettingsTabID = ""
      return
    }
    selectSettingsDestination(
      target.destination,
      healthDestination: target.healthDestination,
      targetRoute: target.route
    )
    requestedSettingsTabID = ""
  }

  private func selectSettingsDestination(
    _ destination: SettingsDestination,
    healthDestination: SettingsConfigurationHealthDestination?,
    targetRoute: SettingsRoute? = nil
  ) {
    guard moduleVisibility.allowsSettingsTab(destination.tab) else {
      apply(navigationSession.selectSidebarRoute(.subsection(.appearanceModules)))
      return
    }
    apply(
      navigationSession.selectDestination(
        destination,
        healthDestination: healthDestination,
        targetRoute: targetRoute
      )
    )
  }

  private func requestDetailScroll(to subsection: SettingsSubsection) {
    navigationSession.requestDetailScroll(to: subsection)
  }

  private func apply(_ selection: SettingsNavigationSession.RouteSelection) {
    if selection.dismissesSearchHighlight {
      searchSession.dismissHighlight()
    }
    if selection.clearsSubsectionAnchors {
      subsectionAnchorFrames = [:]
    }
  }

  private func scroll(
    _ proxy: ScrollViewProxy,
    to request: SettingsSubsectionScrollRequest
  ) {
    guard request.subsection.tab == selectedSettingsTab,
      subsectionAnchorFrames.keys.contains(where: { $0.tab == selectedSettingsTab }),
      appliedScrollRequestID != request.id
    else { return }
    DispatchQueue.main.async {
      guard navigationSession.detailScrollRequest?.id == request.id,
        appliedScrollRequestID != request.id
      else { return }
      appliedScrollRequestID = request.id
      let performScroll = {
        proxy.scrollTo(request.subsection.id, anchor: .top)
      }
      if reduceMotion {
        performScroll()
      } else {
        withAnimation(.easeInOut(duration: 0.2)) {
          performScroll()
        }
      }
    }
  }

  private func synchronizeVisibleSubsection() {
    // Initial/deep-link scrolling waits for the page's first layout. The
    // destination itself may be outside a lazily realized Form viewport.
    // Observations from the old viewport must not replace that selection.
    guard navigationSession.detailScrollRequest?.id == appliedScrollRequestID else { return }
    guard
      let visibleSubsection = SettingsSubsectionVisibilityPolicy.visibleSubsection(
        in: selectedSettingsTab,
        anchorFrames: subsectionAnchorFrames,
        isAtBottom: detailScrollIsAtBottom
      ),
      visibleSubsection != selectedSubsection
    else {
      return
    }

    // Do not call `selectRoute` here: this state change comes from native
    // scrolling and must never produce a compensating scrollTo feedback loop.
    _ = navigationSession.synchronizeManuallyScrolledSubsection(visibleSubsection)
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
  static let maximumWidth: CGFloat = 320
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
    let searchFieldHeight: CGFloat
    let pageHeaderHeight: CGFloat
    let sidebarRowVerticalPadding: CGFloat
    let subsectionRowVerticalPadding: CGFloat
  }

  static let compactHeightThreshold: CGFloat = 720
  static let minimumDetailWidth: CGFloat = 560

  static func presentation(
    width: CGFloat,
    height: CGFloat = WorkbenchSettingsMetrics.idealHeight,
    scaledSidebarWidth: CGFloat,
    density: WorkbenchInterfaceDensity = .comfortable
  ) -> Presentation {
    let preferredSidebarWidth = SettingsSidebarPresentation.clampedWidth(scaledSidebarWidth)
    let availableSidebarWidth = max(
      SettingsSidebarPresentation.minimumWidth,
      width - minimumDetailWidth
    )
    let compactPrimaryWidth = min(preferredSidebarWidth, availableSidebarWidth)
    let usesCompactVerticalMetrics =
      density == .compact || height < compactHeightThreshold

    return Presentation(
      usesCompactVerticalMetrics: usesCompactVerticalMetrics,
      primarySidebarWidth: compactPrimaryWidth,
      searchFieldHeight: usesCompactVerticalMetrics ? 32 : 36,
      pageHeaderHeight: usesCompactVerticalMetrics ? 68 : 76,
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
