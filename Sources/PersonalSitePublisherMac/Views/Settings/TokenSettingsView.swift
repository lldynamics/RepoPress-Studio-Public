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
  let navigationDestination: SettingsDestination?
  let navigationRequestID: UUID
  let shouldFocusRepositoryToken: Bool
  let repositoryTokenFocusRequestID: UUID
  let localRepositoryPath: String
  let chooseLocalRepository: () -> Void
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

  @StateObject private var automationSettings: WorkbenchAutomationSettingsFeatureFacade
  @State private var credentialDrafts = TokenCredentialDrafts()
  @State private var isRepositoryPermissionPresented = false

  init(
    store: WorkbenchStore,
    activeProfileBinding: Binding<SiteProfile>,
    readiness: DeploymentStatusProviderReadiness,
    repositoryTokenAvailability: KeychainTokenAvailability,
    deploymentTokenAvailability: KeychainTokenAvailability,
    siteAnalyticsTokenAvailability: KeychainTokenAvailability,
    publishActionMessage: String?,
    deploymentStatusMessage: String?,
    siteAnalyticsMessage: String?,
    navigationDestination: SettingsDestination?,
    navigationRequestID: UUID,
    shouldFocusRepositoryToken: Bool,
    repositoryTokenFocusRequestID: UUID,
    localRepositoryPath: String,
    chooseLocalRepository: @escaping () -> Void,
    setRepositoryProvider: @escaping (RepositoryProvider) -> Void,
    saveRepositoryAccessToken: @escaping (String) -> Bool,
    deleteRepositoryAccessToken: @escaping () -> Void,
    refreshRepositoryTokenAvailability: @escaping () -> Void,
    saveDeploymentAccessToken: @escaping (String) -> Bool,
    deleteDeploymentAccessToken: @escaping () -> Void,
    refreshDeploymentTokenAvailability: @escaping () -> Void,
    saveSiteAnalyticsAccessToken: @escaping (String) -> Bool,
    deleteSiteAnalyticsAccessToken: @escaping () -> Void,
    refreshSiteAnalyticsTokenAvailability: @escaping () -> Void,
    @ViewBuilder repositoryPermissionContent:
      @escaping (Binding<Bool>) -> RepositoryPermissionContent
  ) {
    _automationSettings = StateObject(
      wrappedValue: WorkbenchAutomationSettingsFeatureFacade(store: store)
    )
    self.activeProfileBinding = activeProfileBinding
    self.readiness = readiness
    self.repositoryTokenAvailability = repositoryTokenAvailability
    self.deploymentTokenAvailability = deploymentTokenAvailability
    self.siteAnalyticsTokenAvailability = siteAnalyticsTokenAvailability
    self.publishActionMessage = publishActionMessage
    self.deploymentStatusMessage = deploymentStatusMessage
    self.siteAnalyticsMessage = siteAnalyticsMessage
    self.navigationDestination = navigationDestination
    self.navigationRequestID = navigationRequestID
    self.shouldFocusRepositoryToken = shouldFocusRepositoryToken
    self.repositoryTokenFocusRequestID = repositoryTokenFocusRequestID
    self.localRepositoryPath = localRepositoryPath
    self.chooseLocalRepository = chooseLocalRepository
    self.setRepositoryProvider = setRepositoryProvider
    self.saveRepositoryAccessToken = saveRepositoryAccessToken
    self.deleteRepositoryAccessToken = deleteRepositoryAccessToken
    self.refreshRepositoryTokenAvailability = refreshRepositoryTokenAvailability
    self.saveDeploymentAccessToken = saveDeploymentAccessToken
    self.deleteDeploymentAccessToken = deleteDeploymentAccessToken
    self.refreshDeploymentTokenAvailability = refreshDeploymentTokenAvailability
    self.saveSiteAnalyticsAccessToken = saveSiteAnalyticsAccessToken
    self.deleteSiteAnalyticsAccessToken = deleteSiteAnalyticsAccessToken
    self.refreshSiteAnalyticsTokenAvailability = refreshSiteAnalyticsTokenAvailability
    self.repositoryPermissionContent = repositoryPermissionContent
  }

  var body: some View {
    Form {
      SettingsSubsectionAnchor(subsection: .tokenRepository)
      repositorySections
      SettingsSubsectionAnchor(subsection: .tokenDeployment)
      deploymentSections
      SettingsSubsectionAnchor(subsection: .tokenAnalytics)
      analyticsSections
    }
    .formStyle(.grouped)
    .scrollIndicators(.hidden)
    .padding(WorkbenchSpacing.content)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(isPresented: $isRepositoryPermissionPresented) {
      repositoryPermissionContent($isRepositoryPermissionPresented)
    }
    .onChange(of: activeProfile.id) { _, _ in
      credentialDrafts.clearAll()
    }
    .onChange(of: activeProfile.repositoryProvider) { _, _ in
      credentialDrafts.repository = ""
      refreshRepositoryTokenAvailability()
    }
    .onChange(of: activeDeploymentProvider) { _, _ in
      credentialDrafts.deployment = ""
      refreshDeploymentTokenAvailability()
    }
    .onChange(of: activeAnalyticsProvider) { _, _ in
      credentialDrafts.analytics = ""
      refreshSiteAnalyticsTokenAvailability()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("token-settings")
  }

  @ViewBuilder
  private var repositorySections: some View {
    TokenConnectionStatusSummary(
      presentation: .repository(
        profile: activeProfile,
        tokenAvailability: repositoryTokenAvailability
      )
    )

    TokenRepositoryDefaultsSection(
      localRepositoryPath: localRepositoryPath,
      chooseLocalRepository: chooseLocalRepository,
      repositoryProviderBinding: repositoryProviderBinding,
      repositoryProviderDisplayName: activeProfile.repositoryProvider.localizedDisplayName,
      repositoryBaseURL: activeProfileBinding.repositoryBaseURL,
      ownerOrNamespace: activeProfileBinding.repoOwner,
      ownerOrNamespaceDisplayValue: activeProfile.repoOwner.isEmpty
        ? "未填写" : activeProfile.repoOwner,
      repositoryRepoOrProject: activeProfileBinding.repoName,
      repositoryRepoOrProjectDisplayValue: activeProfile.repoName.isEmpty
        ? "未填写" : activeProfile.repoName,
      branch: activeProfileBinding.branch,
      branchDisplayValue: activeProfile.branch.isEmpty ? "未填写" : activeProfile.branch,
      publishStrategyBinding: activeProfileBinding.repositoryPublishStrategy,
      publishStrategyDisplayValue: activeProfile.repositoryPublishStrategy.localizedDisplayName,
      publishStrategyDetail: activeProfile.repositoryPublishStrategy.detail
    )

    TokenRepositoryAutomationSection(automationSettings: automationSettings)

    TokenRepositoryTokenSection(
      repositoryProvider: activeProfile.repositoryProvider,
      repositoryTokenInput: $credentialDrafts.repository,
      shouldFocusInput: shouldFocusRepositoryToken,
      navigationRequestID: repositoryTokenFocusRequestID,
      tokenAvailability: repositoryTokenAvailability,
      onSaveToken: {
        guard saveRepositoryAccessToken(credentialDrafts.repository) else { return false }
        credentialDrafts.repository = ""
        return true
      },
      onDeleteToken: {
        deleteRepositoryAccessToken()
        credentialDrafts.repository = ""
      },
      onRefreshTokenState: refreshRepositoryTokenAvailability
    )
    .id(activeProfile.id)

    Section("连接诊断与最近结果") {
      Button {
        isRepositoryPermissionPresented = true
      } label: {
        Label("连接诊断", systemImage: "lock.shield")
      }
      .accessibilityLabel("打开仓库连接诊断")

      Text("连接诊断只会在你点击后运行；正常发布会在需要时自动验证当前仓库连接。")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let publishActionMessage {
        LabeledContent("最近结果") {
          Text(publishActionMessage)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
      }
    }
  }

  @ViewBuilder
  private var deploymentSections: some View {
    TokenConnectionStatusSummary(
      presentation: .deployment(
        readiness: readiness,
        tokenAvailability: deploymentTokenAvailability
      )
    )

    TokenDeploymentDefaultsSection(
      deploymentProviderBinding: deploymentProviderBinding,
      deploymentProviderDisplayName: activeDeploymentProvider.localizedDisplayName,
      deploymentSiteURL: optionalProfileStringBinding(\.deploymentSiteURL),
      deploymentSiteURLDisplayValue: activeProfile.deploymentSiteURL?.nilIfEmpty ?? "未填写",
      deploymentStatusEndpointURL: optionalProfileStringBinding(\.deploymentStatusEndpointURL),
      deploymentStatusEndpointURLDisplayValue: activeProfile.deploymentStatusEndpointURL?.nilIfEmpty
        ?? "未填写",
      deploymentStatusEndpointUsesTokenBinding: deploymentStatusEndpointUsesTokenBinding,
      deploymentProjectID: optionalProfileStringBinding(\.deploymentProjectID),
      deploymentProjectIDDisplayValue: activeProfile.deploymentProjectID?.nilIfEmpty ?? "未填写",
      deploymentAccountID: optionalProfileStringBinding(\.deploymentAccountID),
      deploymentAccountIDDisplayValue: activeProfile.deploymentAccountID?.nilIfEmpty ?? "未填写"
    )

    TokenDeploymentAutomationSection(automationSettings: automationSettings)

    TokenDeploymentTokenSection(
      deploymentProvider: activeDeploymentProvider,
      deploymentTokenInput: $credentialDrafts.deployment,
      tokenAvailability: deploymentTokenAvailability,
      onSaveToken: {
        guard saveDeploymentAccessToken(credentialDrafts.deployment) else { return false }
        credentialDrafts.deployment = ""
        return true
      },
      onDeleteToken: {
        deleteDeploymentAccessToken()
        credentialDrafts.deployment = ""
      },
      onRefreshTokenState: refreshDeploymentTokenAvailability
    )
    .id(activeProfile.id)

    Section("验证与最近结果") {
      Label(
        readiness.statusTitle,
        systemImage: readiness.isAPIReady
          ? "checkmark.seal"
          : readiness.canCheckAnyStatus ? "exclamationmark.triangle" : "xmark.octagon"
      )
      .foregroundStyle(
        readiness.isAPIReady
          ? WorkbenchTheme.success
          : readiness.canCheckAnyStatus ? WorkbenchTheme.warning : WorkbenchTheme.risk
      )

      Text(readiness.nextStep)
        .font(.caption)
        .foregroundStyle(.secondary)

      if !readiness.missingRequirements.isEmpty {
        Text("待补齐：\(readiness.missingRequirements.joined(separator: "、"))")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
      }

      Text(readiness.fallbackMessage)
        .font(.caption)
        .foregroundStyle(.secondary)

      Text("这里仅显示配置就绪状态，不会自动发起线上部署测试。实际结果来自已有的发布后校验。")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let deploymentStatusMessage {
        LabeledContent("最近结果") {
          Text(deploymentStatusMessage)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
      }
    }
  }

  @ViewBuilder
  private var analyticsSections: some View {
    TokenAnalyticsSettingsSection(
      settings: analyticsSettingsBinding,
      tokenInput: $credentialDrafts.analytics,
      tokenAvailability: siteAnalyticsTokenAvailability,
      onSaveToken: {
        guard saveSiteAnalyticsAccessToken(credentialDrafts.analytics) else { return }
        credentialDrafts.analytics = ""
      },
      onDeleteToken: {
        deleteSiteAnalyticsAccessToken()
        credentialDrafts.analytics = ""
      },
      onRefreshTokenState: refreshSiteAnalyticsTokenAvailability
    )
    .id(activeProfile.id)

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

  private func optionalProfileStringBinding(_ keyPath: WritableKeyPath<SiteProfile, String?>)
    -> Binding<String>
  {
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

enum TokenSettingsScope: String, CaseIterable, Identifiable {
  case repository
  case deployment
  case analytics

  var id: String { rawValue }

  init(destination: SettingsTokenDestination) {
    switch destination {
    case .repository:
      self = .repository
    case .deployment:
      self = .deployment
    case .analytics:
      self = .analytics
    }
  }

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
}

struct TokenCredentialDrafts: Equatable {
  var repository = ""
  var deployment = ""
  var analytics = ""

  mutating func clearAll() {
    repository = ""
    deployment = ""
    analytics = ""
  }
}
