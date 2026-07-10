import PublishingWorkbenchCore
import SwiftUI

struct TokenSettingsView<RepositoryPermissionContent: View>: View {
  let activeProfileBinding: Binding<SiteProfile>
  let readiness: DeploymentStatusProviderReadiness
  let hasRepositoryToken: Bool
  let hasDeploymentToken: Bool
  let publishActionMessage: String?
  let deploymentStatusMessage: String?
  let setRepositoryProvider: (RepositoryProvider) -> Void
  let saveRepositoryAccessToken: (String) -> Void
  let deleteRepositoryAccessToken: () -> Void
  let refreshRepositoryTokenAvailability: () -> Void
  let saveDeploymentAccessToken: (String) -> Void
  let deleteDeploymentAccessToken: () -> Void
  let refreshDeploymentTokenAvailability: () -> Void
  let repositoryPermissionContent: (Binding<Bool>) -> RepositoryPermissionContent

  @State private var repositoryTokenInput = ""
  @State private var deploymentTokenInput = ""
  @State private var isRepositoryPermissionPresented = false

  var body: some View {
    Form {
      TokenRepositoryDefaultsSection(
        repositoryProviderBinding: repositoryProviderBinding,
        repositoryProviderDisplayName: activeProfile.repositoryProvider.displayName,
        repositoryBaseURL: activeProfileBinding.repositoryBaseURL,
        ownerOrNamespace: activeProfileBinding.repoOwner,
        ownerOrNamespaceDisplayValue: activeProfile.repoOwner.isEmpty ? "未填写" : activeProfile.repoOwner,
        repositoryRepoOrProject: activeProfileBinding.repoName,
        repositoryRepoOrProjectDisplayValue: activeProfile.repoName.isEmpty ? "未填写" : activeProfile.repoName,
        branch: activeProfileBinding.branch,
        branchDisplayValue: activeProfile.branch.isEmpty ? "未填写" : activeProfile.branch,
        publishStrategyBinding: activeProfileBinding.repositoryPublishStrategy,
        publishStrategyDisplayValue: activeProfile.repositoryPublishStrategy.displayName,
        publishStrategyDetail: activeProfile.repositoryPublishStrategy.detail
      )

      TokenDeploymentDefaultsSection(
        readiness: readiness,
        deploymentProviderBinding: deploymentProviderBinding,
        deploymentProviderDisplayName: activeDeploymentProvider.displayName,
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

      TokenRepositoryTokenSection(
        repositoryTokenInput: $repositoryTokenInput,
        hasRepositoryToken: hasRepositoryToken,
        onSaveToken: {
          saveRepositoryAccessToken(repositoryTokenInput)
          repositoryTokenInput = ""
        },
        onDeleteToken: {
          deleteRepositoryAccessToken()
          repositoryTokenInput = ""
        },
        onRefreshTokenState: {
          refreshRepositoryTokenAvailability()
        },
        onOpenRepositoryPermission: {
          isRepositoryPermissionPresented = true
        }
      )

      TokenDeploymentTokenSection(
        deploymentProvider: activeDeploymentProvider,
        deploymentTokenInput: $deploymentTokenInput,
        hasDeploymentToken: hasDeploymentToken,
        onSaveToken: {
          saveDeploymentAccessToken(deploymentTokenInput)
          deploymentTokenInput = ""
        },
        onDeleteToken: {
          deleteDeploymentAccessToken()
          deploymentTokenInput = ""
        },
        onRefreshTokenState: refreshDeploymentTokenAvailability
      )

      if let message = publishActionMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let message = deploymentStatusMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
    .sheet(isPresented: $isRepositoryPermissionPresented) {
      repositoryPermissionContent($isRepositoryPermissionPresented)
    }
    .onChange(of: activeProfile.repositoryProvider) { _, _ in
      refreshRepositoryTokenAvailability()
    }
    .onChange(of: activeDeploymentProvider) { _, _ in
      refreshDeploymentTokenAvailability()
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
