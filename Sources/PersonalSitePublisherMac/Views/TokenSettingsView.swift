import PublishingWorkbenchCore
import SwiftUI

struct TokenSettingsView<RepositoryPermissionContent: View>: View {
  let activeProfileBinding: Binding<SiteProfile>
  let readiness: DeploymentStatusProviderReadiness
  let hasRepositoryToken: Bool
  let hasDeploymentToken: Bool
  let publishActionMessage: String?
  let deploymentStatusMessage: String?
  let shouldFocusRepositoryToken: Bool
  let navigationRequestID: UUID
  let setRepositoryProvider: (RepositoryProvider) -> Void
  let saveRepositoryAccessToken: (String) -> Bool
  let deleteRepositoryAccessToken: () -> Void
  let refreshRepositoryTokenAvailability: () -> Void
  let saveDeploymentAccessToken: (String) -> Bool
  let deleteDeploymentAccessToken: () -> Void
  let refreshDeploymentTokenAvailability: () -> Void
  let repositoryPermissionContent: (Binding<Bool>) -> RepositoryPermissionContent

  @State private var repositoryTokenInput = ""
  @State private var deploymentTokenInput = ""
  @State private var isRepositoryPermissionPresented = false
  @State private var selectedScope: ConnectionSettingsScope = .repository

  var body: some View {
    VStack(spacing: 0) {
      Picker("设置范围", selection: $selectedScope) {
        ForEach(ConnectionSettingsScope.allCases) { scope in
          Text(scope.title).tag(scope)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 360)
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
      .accessibilityLabel("仓库与部署设置范围")

      Divider()

      Form {
        switch selectedScope {
        case .repository:
          repositorySections
        case .deployment:
          deploymentSections
        }
      }
      .formStyle(.grouped)
      .padding()
    }
    .sheet(isPresented: $isRepositoryPermissionPresented) {
      repositoryPermissionContent($isRepositoryPermissionPresented)
    }
    .task(id: navigationRequestID) {
      guard shouldFocusRepositoryToken else { return }
      selectedScope = .repository
    }
    .onChange(of: activeProfile.repositoryProvider) { _, _ in
      refreshRepositoryTokenAvailability()
    }
    .onChange(of: activeDeploymentProvider) { _, _ in
      refreshDeploymentTokenAvailability()
    }
  }

  @ViewBuilder
  private var repositorySections: some View {
    TokenRepositoryTokenSection(
      repositoryProviderName: activeProfile.repositoryProvider.localizedDisplayName,
      repositoryTokenInput: $repositoryTokenInput,
      shouldFocusInput: shouldFocusRepositoryToken,
      navigationRequestID: navigationRequestID,
      hasRepositoryToken: hasRepositoryToken,
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
      hasDeploymentToken: hasDeploymentToken,
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

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }

  private var activeDeploymentProvider: DeploymentProvider {
    activeProfile.deploymentProvider
      ?? (activeProfile.repositoryProvider == .github ? .githubPages : .gitlabPages)
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

  var id: String { rawValue }

  var title: String {
    switch self {
    case .repository:
      return String(localized: "仓库")
    case .deployment:
      return String(localized: "部署")
    }
  }
}
