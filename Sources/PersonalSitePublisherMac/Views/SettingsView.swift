import PublishingWorkbenchCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var store: WorkbenchStore
  let rssStore: RSSReaderStore?
  @ObservedObject var launchCoordinator: WorkbenchLaunchCoordinator
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  @AppStorage("scanRepositoryOnLaunch") private var scanRepositoryOnLaunch = false
  @AppStorage("settingsRequestedTabID") private var requestedSettingsTabID = ""
  @State private var selectedSettingsTab: SettingsTab
  @State private var healthDestination: SettingsConfigurationHealthDestination?
  @State private var healthNavigationRequestID = UUID()
  @State private var pendingSiteKind: SiteKind?

  init(
    store: WorkbenchStore,
    rssStore: RSSReaderStore? = nil,
    launchCoordinator: WorkbenchLaunchCoordinator
  ) {
    self.store = store
    self.rssStore = rssStore
    self.launchCoordinator = launchCoordinator
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
          .scrollIndicators(.hidden)
          .frame(maxWidth: selectedSettingsTab.contentMaxWidth)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
      .background(Color(nsColor: .windowBackgroundColor))
      .accessibilityIdentifier("settings-content")
    }
    .workbenchSettingsWindowSize()
    .background(Color(nsColor: .windowBackgroundColor))
    .navigationTitle("设置")
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

        Section("应用设置") {
          ForEach(SettingsTab.applicationSettings) { tab in
            settingsSidebarRow(tab)
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .padding(.top, WorkbenchSpacing.control)
    }
    .frame(width: WorkbenchSettingsMetrics.sidebarWidth)
    .workbenchGlassContainer(material: .thinMaterial, drawsBorder: false)
    .accessibilityIdentifier("settings-sidebar")
  }

  private func settingsSidebarRow(_ tab: SettingsTab) -> some View {
    Label(tab.title, systemImage: tab.systemImage)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .tag(tab)
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
      selectConfigurationHealthDestination: openConfigurationHealthDestination
    )
  }

  private static func initialSettingsTab() -> SettingsTab {
    .defaultRules
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
    }
  }

  private func applyRequestedSettingsTab(_ requestedTabID: String) {
    guard !requestedTabID.isEmpty else {
      return
    }
    guard let tab = SettingsTab.tab(forRequestedID: requestedTabID) else {
      requestedSettingsTabID = ""
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
