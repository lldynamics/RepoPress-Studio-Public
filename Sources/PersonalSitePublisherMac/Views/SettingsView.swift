import PublishingWorkbenchCore
import SwiftUI
#if DEBUG
import PublishingWorkbenchScreenshotSupport
#endif

struct SettingsView: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var storeKitProEntitlementCoordinator: StoreKitProEntitlementCoordinator
  @AppStorage("defaultShowsInspector") private var defaultShowsInspector = true
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  @AppStorage("scanRepositoryOnLaunch") private var scanRepositoryOnLaunch = false
  @State private var selectedSettingsTab: SettingsTab
  @State private var healthDestination: SettingsConfigurationHealthDestination?
  @State private var healthNavigationRequestID = UUID()

  init(
    store: WorkbenchStore,
    storeKitProEntitlementCoordinator: StoreKitProEntitlementCoordinator
  ) {
    self.store = store
    self.storeKitProEntitlementCoordinator = storeKitProEntitlementCoordinator
    _selectedSettingsTab = State(initialValue: Self.initialSettingsTab())
  }

  var body: some View {
    VStack(spacing: 0) {
      SettingsProfileBar(
        profiles: store.profiles,
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
      .padding(.horizontal, 18)
      .padding(.top, 12)
      .padding(.bottom, 8)

      SettingsConfigurationHealthCard(
        profile: store.activeProfile,
        repositoryTokenAvailability: store.repositoryTokenAvailability,
        aiTokenAvailability: store.ai.tokenAvailability,
        privacySettings: store.privacySettings,
        isProUnlocked: store.monetizationState.entitlement.isUnlocked,
        proSource: store.monetizationState.entitlement.source.localizedDisplayName,
        selectDestination: openConfigurationHealthDestination
      )
      .padding(.horizontal, 18)
      .padding(.bottom, 10)

      Divider()

      TabView(selection: $selectedSettingsTab) {
        ForEach(SettingsTab.allCases) { tab in
          tab.makeContent(
            context: SettingsContext(
              store: store,
              storeKitProEntitlementCoordinator: storeKitProEntitlementCoordinator,
              activeProfileBinding: activeProfileBinding,
              defaultShowsInspector: $defaultShowsInspector,
              autoRunPreflightBinding: autoRunPreflightBinding,
              scanRepositoryOnLaunch: $scanRepositoryOnLaunch,
              siteKindBinding: siteKindBinding,
              healthDestination: healthDestination,
              healthNavigationRequestID: healthNavigationRequestID
            )
          )
          .tag(tab)
          .tabItem {
            Label(tab.title, systemImage: tab.systemImage)
          }
        }
      }
    }
    .frame(minWidth: 620, idealWidth: 760, minHeight: 520, idealHeight: 680)
    .scenePadding()
    .onAppear {
      store.setAutomaticallyRefreshPreflightOnEdit(autoRunPreflight)
    }
    .onChange(of: autoRunPreflight) { _, newValue in
      store.setAutomaticallyRefreshPreflightOnEdit(newValue)
    }
  }

  private static func initialSettingsTab() -> SettingsTab {
#if DEBUG
    ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .proSettings ? .pro : .defaultRules
#else
    .defaultRules
#endif
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
        store.applySiteKindDefaults(kind)
      }
    )
  }

  private func openConfigurationHealthDestination(_ destination: SettingsConfigurationHealthDestination) {
    healthDestination = destination
    healthNavigationRequestID = UUID()
    switch destination {
    case .repository:
      guard let url = RepositorySelectionPanel.chooseDirectory() else { return }
      Task {
        await store.repository.rememberRootAsync(url)
      }
    case .defaultRules:
      selectedSettingsTab = .defaultRules
    case .repositoryToken:
      selectedSettingsTab = .token
    case .aiKey:
      selectedSettingsTab = .ai
    case .privacy:
      selectedSettingsTab = .privacy
    case .pro:
      selectedSettingsTab = .pro
    }
  }
}
