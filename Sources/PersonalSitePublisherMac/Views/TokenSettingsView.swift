import PublishingWorkbenchCore
import SwiftUI

struct TokenSettingsView<RepositoryPermissionContent: View>: View {
  let activeProfileBinding: Binding<SiteProfile>
  let readiness: DeploymentStatusProviderReadiness
  let repositoryTokenAvailability: KeychainTokenAvailability
  let deploymentTokenAvailability: KeychainTokenAvailability
  let siteAnalyticsTokenAvailability: KeychainTokenAvailability
  let publishActionMessage: String?
  let deploymentStatusMessage: String?
  let siteAnalyticsMessage: String?
  let shouldFocusRepositoryToken: Bool
  let navigationRequestID: UUID
  let setRepositoryProvider: (RepositoryProvider) -> Void
  let saveRepositoryAccessToken: (String) -> Bool
  let deleteRepositoryAccessToken: () -> Void
  let refreshRepositoryTokenAvailability: () -> Void
  let saveDeploymentAccessToken: (String) -> Bool
  let deleteDeploymentAccessToken: () -> Void
  let refreshDeploymentTokenAvailability: () -> Void
  let saveSiteAnalyticsAccessToken: (String) -> Bool
  let deleteSiteAnalyticsAccessToken: () -> Void
  let refreshSiteAnalyticsTokenAvailability: () -> Void
  let repositoryPermissionContent: (Binding<Bool>) -> RepositoryPermissionContent

  @State private var repositoryTokenInput = ""
  @State private var deploymentTokenInput = ""
  @State private var siteAnalyticsTokenInput = ""
  @State private var isRepositoryPermissionPresented = false
  @State private var selectedScope: ConnectionSettingsScope = .repository

  var body: some View {
    VStack(spacing: 0) {
      connectionSettingsHeader

      Divider()

      Form {
        switch selectedScope {
        case .repository:
          repositorySections
        case .deployment:
          deploymentSections
        case .analytics:
          analyticsSections
        }
      }
      .formStyle(.grouped)
      .scrollIndicators(.automatic)
      .padding(WorkbenchSpacing.content)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .sheet(isPresented: $isRepositoryPermissionPresented) {
      repositoryPermissionContent($isRepositoryPermissionPresented)
    }
    .task(id: navigationRequestID) {
      guard shouldFocusRepositoryToken else { return }
      selectedScope = .repository
    }
    .onChange(of: activeProfile.repositoryProvider) { _, _ in
      repositoryTokenInput = ""
      refreshRepositoryTokenAvailability()
    }
    .onChange(of: activeDeploymentProvider) { _, _ in
      deploymentTokenInput = ""
      refreshDeploymentTokenAvailability()
    }
    .onChange(of: activeAnalyticsProvider) { _, _ in
      siteAnalyticsTokenInput = ""
      refreshSiteAnalyticsTokenAvailability()
    }
    .accessibilityIdentifier("token-settings")
  }

  private var connectionSettingsHeader: some View {
    SettingsScopeHeader {
      Label(selectedScope.title, systemImage: selectedScope.systemImage)
        .font(.workbenchItemTitle)
        .foregroundStyle(.secondary)
    } scopeControl: {
      connectionSettingsPicker
    }
  }

  private var connectionSettingsPicker: some View {
    Picker("仓库与部署设置分类", selection: $selectedScope) {
      ForEach(ConnectionSettingsScope.allCases) { scope in
        Text(scope.title).tag(scope)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .accessibilityLabel("仓库与部署设置分类")
    .accessibilityIdentifier("settings-connection-scope-picker")
  }

  @ViewBuilder
  private var repositorySections: some View {
    TokenRepositoryTokenSection(
      repositoryProvider: activeProfile.repositoryProvider,
      repositoryTokenInput: $repositoryTokenInput,
      shouldFocusInput: shouldFocusRepositoryToken,
      navigationRequestID: navigationRequestID,
      tokenAvailability: repositoryTokenAvailability,
      onSaveToken: {
        guard saveRepositoryAccessToken(repositoryTokenInput) else { return }
        repositoryTokenInput = ""
      },
      onDeleteToken: {
        deleteRepositoryAccessToken()
        repositoryTokenInput = ""
      },
      onRefreshTokenState: refreshRepositoryTokenAvailability,
      onOpenRepositoryPermission: {
        isRepositoryPermissionPresented = true
      }
    )

    TokenRepositoryDefaultsSection(
      repositoryProviderBinding: repositoryProviderBinding,
      repositoryProviderDisplayName: activeProfile.repositoryProvider.localizedDisplayName,
      repositoryBaseURL: activeProfileBinding.repositoryBaseURL,
      ownerOrNamespace: activeProfileBinding.repoOwner,
      ownerOrNamespaceDisplayValue: activeProfile.repoOwner.isEmpty ? "未填写" : activeProfile.repoOwner,
      repositoryRepoOrProject: activeProfileBinding.repoName,
      repositoryRepoOrProjectDisplayValue: activeProfile.repoName.isEmpty ? "未填写" : activeProfile.repoName,
      branch: activeProfileBinding.branch,
      branchDisplayValue: activeProfile.branch.isEmpty ? "未填写" : activeProfile.branch,
      publishStrategyBinding: activeProfileBinding.repositoryPublishStrategy,
      publishStrategyDisplayValue: activeProfile.repositoryPublishStrategy.localizedDisplayName,
      publishStrategyDetail: activeProfile.repositoryPublishStrategy.detail
    )

    if let publishActionMessage {
      Section("最近结果") {
        Text(publishActionMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var deploymentSections: some View {
    TokenDeploymentTokenSection(
      deploymentProvider: activeDeploymentProvider,
      deploymentTokenInput: $deploymentTokenInput,
      tokenAvailability: deploymentTokenAvailability,
      onSaveToken: {
        guard saveDeploymentAccessToken(deploymentTokenInput) else { return }
        deploymentTokenInput = ""
      },
      onDeleteToken: {
        deleteDeploymentAccessToken()
        deploymentTokenInput = ""
      },
      onRefreshTokenState: refreshDeploymentTokenAvailability
    )

    TokenDeploymentDefaultsSection(
      readiness: readiness,
      deploymentProviderBinding: deploymentProviderBinding,
      deploymentProviderDisplayName: activeDeploymentProvider.localizedDisplayName,
      deploymentSiteURL: optionalProfileStringBinding(\.deploymentSiteURL),
      deploymentSiteURLDisplayValue: activeProfile.deploymentSiteURL?.nilIfEmpty ?? "未填写",
      deploymentStatusEndpointURL: optionalProfileStringBinding(\.deploymentStatusEndpointURL),
      deploymentStatusEndpointURLDisplayValue: activeProfile.deploymentStatusEndpointURL?.nilIfEmpty ?? "未填写",
      deploymentStatusEndpointUsesTokenBinding: deploymentStatusEndpointUsesTokenBinding,
      deploymentProjectID: optionalProfileStringBinding(\.deploymentProjectID),
      deploymentProjectIDDisplayValue: activeProfile.deploymentProjectID?.nilIfEmpty ?? "未填写",
      deploymentAccountID: optionalProfileStringBinding(\.deploymentAccountID),
      deploymentAccountIDDisplayValue: activeProfile.deploymentAccountID?.nilIfEmpty ?? "未填写"
    )

    if let deploymentStatusMessage {
      Section("最近结果") {
        Text(deploymentStatusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var analyticsSections: some View {
    TokenAnalyticsSettingsSection(
      settings: analyticsSettingsBinding,
      tokenInput: $siteAnalyticsTokenInput,
      tokenAvailability: siteAnalyticsTokenAvailability,
      onSaveToken: {
        guard saveSiteAnalyticsAccessToken(siteAnalyticsTokenInput) else { return }
        siteAnalyticsTokenInput = ""
      },
      onDeleteToken: {
        deleteSiteAnalyticsAccessToken()
        siteAnalyticsTokenInput = ""
      },
      onRefreshTokenState: refreshSiteAnalyticsTokenAvailability
    )

    if let siteAnalyticsMessage {
      Section("最近结果") {
        Text(siteAnalyticsMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }

  private var activeDeploymentProvider: DeploymentProvider {
    activeProfile.deploymentProvider
      ?? (activeProfile.repositoryProvider == .github ? .githubPages : .gitlabPages)
  }

  private var activeAnalyticsProvider: SiteAnalyticsProvider {
    activeProfile.siteAnalytics?.provider ?? .plausible
  }

  private var analyticsSettingsBinding: Binding<SiteAnalyticsSettings> {
    Binding(
      get: { activeProfileBinding.wrappedValue.siteAnalytics ?? .default },
      set: { settings in
        var profile = activeProfileBinding.wrappedValue
        profile.siteAnalytics = settings
        activeProfileBinding.wrappedValue = profile
        refreshSiteAnalyticsTokenAvailability()
      }
    )
  }

  private var repositoryProviderBinding: Binding<RepositoryProvider> {
    Binding(
      get: { activeProfileBinding.wrappedValue.repositoryProvider },
      set: { provider in
        setRepositoryProvider(provider)
      }
    )
  }

  private var deploymentProviderBinding: Binding<DeploymentProvider> {
    Binding(
      get: { activeDeploymentProvider },
      set: { provider in
        var profile = activeProfileBinding.wrappedValue
        profile.deploymentProvider = provider
        activeProfileBinding.wrappedValue = profile
      }
    )
  }

  private var deploymentStatusEndpointUsesTokenBinding: Binding<Bool> {
    Binding(
      get: { activeProfileBinding.wrappedValue.deploymentStatusEndpointUsesToken == true },
      set: { value in
        var profile = activeProfileBinding.wrappedValue
        profile.deploymentStatusEndpointUsesToken = value
        activeProfileBinding.wrappedValue = profile
      }
    )
  }

  private func optionalProfileStringBinding(_ keyPath: WritableKeyPath<SiteProfile, String?>) -> Binding<String> {
    Binding(
      get: { activeProfileBinding.wrappedValue[keyPath: keyPath] ?? "" },
      set: { value in
        var profile = activeProfileBinding.wrappedValue
        profile[keyPath: keyPath] = value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        activeProfileBinding.wrappedValue = profile
      }
    )
  }
}

private enum ConnectionSettingsScope: String, CaseIterable, Identifiable {
  case repository
  case deployment
  case analytics

  var id: String { rawValue }

  var title: String {
    switch self {
    case .repository:
      return String(localized: "仓库")
    case .deployment:
      return String(localized: "部署")
    case .analytics:
      return String(localized: "阅读数据")
    }
  }

  var systemImage: String {
    switch self {
    case .repository:
      return "shippingbox"
    case .deployment:
      return "arrow.up.right.square"
    case .analytics:
      return "chart.bar.xaxis"
    }
  }
}
