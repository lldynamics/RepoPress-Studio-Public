import PublishingWorkbenchCore
import SwiftUI

struct TokenSettingsView<RepositoryPermissionContent: View>: View {
  @ObservedObject var store: WorkbenchStore
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

  @State private var credentialDrafts = TokenCredentialDrafts()
  @State private var isRepositoryPermissionPresented = false
  @State private var selectedScope: TokenSettingsScope = .repository

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
      guard case .token(let destination) = navigationDestination else { return }
      selectedScope = TokenSettingsScope(destination: destination)
    }
    .task(id: repositoryTokenFocusRequestID) {
      guard shouldFocusRepositoryToken else { return }
      selectedScope = .repository
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

  private var connectionSettingsHeader: some View {
    HStack {
      Spacer(minLength: 0)
      connectionSettingsPicker
        .frame(maxWidth: 420)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, WorkbenchSpacing.content)
    .padding(.vertical, WorkbenchSpacing.control)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var connectionSettingsPicker: some View {
    Picker("仓库与部署设置分类", selection: $selectedScope) {
      ForEach(TokenSettingsScope.allCases) { scope in
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

    TokenRepositoryAutomationSection(store: store)

    TokenRepositoryTokenSection(
      repositoryProvider: activeProfile.repositoryProvider,
      repositoryTokenInput: $credentialDrafts.repository,
      shouldFocusInput: shouldFocusRepositoryToken,
      navigationRequestID: repositoryTokenFocusRequestID,
      tokenAvailability: repositoryTokenAvailability,
      onSaveToken: {
        guard saveRepositoryAccessToken(credentialDrafts.repository) else { return }
        credentialDrafts.repository = ""
      },
      onDeleteToken: {
        deleteRepositoryAccessToken()
        credentialDrafts.repository = ""
      },
      onRefreshTokenState: refreshRepositoryTokenAvailability
    )
    .id(activeProfile.id)

    Section("验证与最近结果") {
      Button {
        isRepositoryPermissionPresented = true
      } label: {
        Label("检查仓库权限", systemImage: "lock.shield")
      }
      .accessibilityLabel("打开仓库权限检查")

      Text("权限检查只会在你点击后运行，并使用当前仓库目标与已保存的仓库令牌。")
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

    TokenDeploymentAutomationSection(store: store)

    TokenDeploymentTokenSection(
      deploymentProvider: activeDeploymentProvider,
      deploymentTokenInput: $credentialDrafts.deployment,
      tokenAvailability: deploymentTokenAvailability,
      onSaveToken: {
        guard saveDeploymentAccessToken(credentialDrafts.deployment) else { return }
        credentialDrafts.deployment = ""
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
