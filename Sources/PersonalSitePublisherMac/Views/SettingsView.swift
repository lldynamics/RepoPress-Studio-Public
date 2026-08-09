import PublishingWorkbenchCore
import SwiftUI

struct SettingsView: View {
  let store: WorkbenchStore
  @ObservedObject private var settingsState: WorkbenchSettingsFeatureFacade
  @ObservedObject private var persistenceStatus: WorkbenchPersistenceFeatureFacade
  let rssStore: RSSReaderStore?
  @ObservedObject var launchCoordinator: WorkbenchLaunchCoordinator
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  @AppStorage("scanRepositoryOnLaunch") private var scanRepositoryOnLaunch = false
  // Compatibility bridge for callers that must request a destination before
  // the separate Settings scene exists. Every value is consumed and cleared.
  @AppStorage(SettingsNavigation.requestedTabStorageKey)
  private var requestedSettingsTabID = ""
  @AppStorage(SettingsNavigation.lastViewedTabStorageKey)
  private var lastViewedSettingsTabID = ""
  @State private var selectedSettingsTab: SettingsTab
  @State private var navigationDestination: SettingsDestination?
  @State private var navigationRequestID = UUID()
  @State private var healthDestination: SettingsConfigurationHealthDestination?
  @State private var healthNavigationRequestID = UUID()
  @State private var pendingSiteKind: SiteKind?
  @State private var searchText = ""
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
    _selectedSettingsTab = State(initialValue: Self.initialSettingsTab())
    _navigationDestination = State(initialValue: nil)
  }

  var body: some View {
    let _ = settingsState
    HStack(spacing: 0) {
      settingsSidebar
      Divider()

      VStack(spacing: 0) {
        settingsPageHeader

        Divider()

        settingsPageContent
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        Divider()

        SettingsSaveStatusBar(
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
    .workbenchSettingsWindowSize()
    .background(Color(nsColor: .windowBackgroundColor))
    .navigationTitle("设置")
    .onAppear {
      applyRequestedSettingsTab(requestedSettingsTabID)
      lastViewedSettingsTabID = selectedSettingsTab.id
      store.setAutomaticallyRefreshPreflightOnEdit(autoRunPreflight)
    }
    .onChange(of: requestedSettingsTabID) { _, requestedTabID in
      applyRequestedSettingsTab(requestedTabID)
    }
    .onChange(of: selectedSettingsTab) { _, selectedTab in
      lastViewedSettingsTabID = selectedTab.id
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

  private var settingsSidebar: some View {
    let visibleSiteSettings = filteredSettingsTabs(SettingsTab.siteSettings)
    let visibleApplicationSettings = filteredSettingsTabs(SettingsTab.applicationSettings)

    return VStack(alignment: .leading, spacing: 0) {
      List(selection: settingsSidebarSelection) {
        if visibleSiteSettings.isEmpty && visibleApplicationSettings.isEmpty {
          Text("没有匹配的设置")
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityLabel("没有匹配的设置")
        } else {
          if !visibleSiteSettings.isEmpty {
            Section("站点") {
              ForEach(visibleSiteSettings) { tab in
                settingsSidebarRow(tab)
              }
            }
          }

          if !visibleApplicationSettings.isEmpty {
            Section("应用设置") {
              ForEach(visibleApplicationSettings) { tab in
                settingsSidebarRow(tab)
              }
            }
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .padding(.top, WorkbenchSpacing.control)
      .searchable(text: $searchText, placement: .sidebar, prompt: Text("搜索设置"))
    }
    .frame(width: SettingsSidebarPresentation.clampedWidth(scaledSidebarWidth))
    .workbenchGlassContainer(material: .thinMaterial, drawsBorder: false)
    .accessibilityIdentifier("settings-sidebar")
  }

  private func settingsSidebarRow(_ tab: SettingsTab) -> some View {
    let needsAttention = tabNeedsAttention(tab)
    return HStack(alignment: .center, spacing: WorkbenchSpacing.control) {
      Label {
        Text(tab.title)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: tab.systemImage)
      }
      Spacer(minLength: 2)
      if needsAttention {
        Text(SettingsSidebarPresentation.attentionBadgeTitle)
          .font(.workbenchMetadata.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.warning)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(
            WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground),
            in: Capsule()
          )
          .fixedSize()
          .accessibilityHidden(true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .tag(tab)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tab.title)
    .accessibilityValue(
      needsAttention ? SettingsSidebarPresentation.attentionAccessibilityValue : ""
    )
    .accessibilityAddTraits(selectedSettingsTab == tab ? .isSelected : [])
    .accessibilityIdentifier("settings-sidebar-\(tab.id)")
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
      return store.ai.tokenAvailability.accessState == .accessFailed
    default:
      return false
    }
  }

  private var settingsPageHeader: some View {
    Group {
      if selectedSettingsTab.isSiteScoped {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: WorkbenchSpacing.section) {
            settingsPageIdentity
              .frame(minWidth: 250, alignment: .leading)

            Spacer(minLength: WorkbenchSpacing.content)

            profileBar
          }

          VStack(alignment: .leading, spacing: WorkbenchSpacing.card) {
            settingsPageIdentity

            profileBar
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
      } else {
        settingsPageIdentity
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, WorkbenchSpacing.page)
    .padding(.vertical, WorkbenchSpacing.card)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var settingsPageIdentity: some View {
    HStack(alignment: .center, spacing: WorkbenchSpacing.section) {
      Image(systemName: selectedSettingsTab.systemImage)
        .font(.title3.weight(.semibold))
        .foregroundStyle(WorkbenchTheme.brand)
        .frame(width: 36, height: 36)
        .background(
          WorkbenchTheme.brand.opacity(WorkbenchOpacity.selectionBackground),
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(selectedSettingsTab.title)
          .font(.workbenchPageTitle)
          .accessibilityAddTraits(.isHeader)
        Text(selectedSettingsTab.subtitle)
          .font(.workbenchPageSubtitle)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
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

  /// Each top-level page owns exactly one native vertical scroll container:
  /// Form-backed pages use their Form, while data management owns a ScrollView.
  @ViewBuilder
  private var settingsPageContent: some View {
    switch selectedSettingsTab.scrollOwnership {
    case .nativeForm, .nativeScrollView:
      selectedSettingsTab.makeContent(context: settingsContext)
        .settingsThinRedScroller()
    }
  }

  private var settingsSidebarSelection: Binding<SettingsTab> {
    Binding(
      get: { selectedSettingsTab },
      set: { selectTopLevelSettingsTab($0) }
    )
  }

  private func filteredSettingsTabs(_ tabs: [SettingsTab]) -> [SettingsTab] {
    tabs.filter { $0.matchesSearch(searchText) }
  }

  private static func initialSettingsTab() -> SettingsTab {
    SettingsNavigation.initialTab(
      lastViewedTabID: UserDefaults.standard.string(
        forKey: SettingsNavigation.lastViewedTabStorageKey
      )
    )
  }

  private var activeProfileBinding: Binding<SiteProfile> {
    Binding(
      get: { store.activeProfile },
      set: { profile in
        store.updateActiveProfile(profile)
        store.save()
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
    switch destination {
    case .repository:
      selectSettingsDestination(.token(.repository), healthDestination: destination)
    case .defaultRules:
      selectSettingsDestination(.rules(.paths), healthDestination: destination)
    case .repositoryToken:
      selectSettingsDestination(.token(.repository), healthDestination: destination)
    case .aiKey:
      selectSettingsDestination(.ai(.credentials), healthDestination: destination)
    }
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
    switch destination {
    case .rules(.paths):
      compatibilityHealthDestination = .defaultRules
    case .token(.repository):
      compatibilityHealthDestination = .repositoryToken
    case .ai(.credentials):
      compatibilityHealthDestination = .aiKey
    default:
      compatibilityHealthDestination = nil
    }
    selectSettingsDestination(
      destination,
      healthDestination: compatibilityHealthDestination
    )
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
    selectedSettingsTab = destination.tab
  }
}

enum SettingsSidebarPresentation {
  static let minimumWidth = WorkbenchSettingsMetrics.sidebarWidth
  static let maximumWidth: CGFloat = 244
  static var attentionBadgeTitle: String { String(localized: "需配置") }
  static var attentionAccessibilityValue: String { String(localized: "需要配置") }

  static func clampedWidth(_ scaledWidth: CGFloat) -> CGFloat {
    min(max(scaledWidth, minimumWidth), maximumWidth)
  }
}
