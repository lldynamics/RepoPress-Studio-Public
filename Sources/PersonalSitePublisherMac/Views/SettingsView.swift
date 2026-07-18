import PublishingWorkbenchCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var storeKitProEntitlementCoordinator: StoreKitProEntitlementCoordinator
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  @AppStorage("scanRepositoryOnLaunch") private var scanRepositoryOnLaunch = false
  @AppStorage("settingsRequestedTabID") private var requestedSettingsTabID = ""
  @State private var selectedSettingsTab: SettingsTab
  @State private var healthDestination: SettingsConfigurationHealthDestination?
  @State private var healthNavigationRequestID = UUID()
  @State private var pendingSiteKind: SiteKind?

  init(
    store: WorkbenchStore,
    storeKitProEntitlementCoordinator: StoreKitProEntitlementCoordinator
  ) {
    self.store = store
    self.storeKitProEntitlementCoordinator = storeKitProEntitlementCoordinator
    _selectedSettingsTab = State(initialValue: Self.initialSettingsTab())
  }

  var body: some View {
    HStack(spacing: 0) {
      settingsSidebar
      Divider()

      VStack(spacing: 0) {
        settingsPageHeader

        Divider()

        selectedSettingsTab.makeContent(context: settingsContext)
          .frame(maxWidth: selectedSettingsTab.contentMaxWidth)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
    }
    .frame(minWidth: 820, idealWidth: 940, minHeight: 580, idealHeight: 700)
    .background(Color(nsColor: .windowBackgroundColor))
    .navigationTitle("设置")
    .tint(WorkbenchTheme.navigationSelection)
    .onAppear {
      applyRequestedSettingsTab(requestedSettingsTabID)
      store.setAutomaticallyRefreshPreflightOnEdit(autoRunPreflight)
    }
    .onChange(of: requestedSettingsTabID) { _, requestedTabID in
      applyRequestedSettingsTab(requestedTabID)
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
    VStack(alignment: .leading, spacing: 0) {
      List(selection: $selectedSettingsTab) {
        Section("站点") {
          ForEach(SettingsTab.siteSettings) { tab in
            settingsSidebarRow(tab)
          }
        }

        Section("应用") {
          ForEach(SettingsTab.applicationSettings) { tab in
            settingsSidebarRow(tab)
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .padding(.top, 8)
    }
    .frame(width: 208)
    .background(.thinMaterial)
  }

  private func settingsSidebarRow(_ tab: SettingsTab) -> some View {
    Label(tab.title, systemImage: tab.systemImage)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .tag(tab)
  }

  private var settingsPageHeader: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: selectedSettingsTab.systemImage)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(WorkbenchTheme.navigationSelection)
        .frame(width: 38, height: 38)
        .background(
          WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.selectionBackground),
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(selectedSettingsTab.title)
          .font(.title2.weight(.semibold))
        Text(selectedSettingsTab.subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 12)

      if selectedSettingsTab.isSiteScoped {
        profileBar
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 15)
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
      storeKitProEntitlementCoordinator: storeKitProEntitlementCoordinator,
      activeProfileBinding: activeProfileBinding,
      autoRunPreflightBinding: autoRunPreflightBinding,
      scanRepositoryOnLaunch: $scanRepositoryOnLaunch,
      siteKindBinding: siteKindBinding,
      healthDestination: healthDestination,
      healthNavigationRequestID: healthNavigationRequestID,
      selectConfigurationHealthDestination: openConfigurationHealthDestination
    )
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
        guard kind != store.activeProfile.siteKind else { return }
        pendingSiteKind = kind
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

  private func applyRequestedSettingsTab(_ requestedTabID: String) {
    guard !requestedTabID.isEmpty,
          let tab = SettingsTab.allCases.first(where: { $0.id == requestedTabID }) else {
      return
    }

    selectedSettingsTab = tab
    if tab == .ai {
      healthDestination = .aiKey
      healthNavigationRequestID = UUID()
    }
    self.requestedSettingsTabID = ""
  }
}
