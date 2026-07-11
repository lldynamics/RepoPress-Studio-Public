import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsTokenTabFactory {
  static func make(context: SettingsContext) -> some View {
    TokenSettingsView(
      activeProfileBinding: context.activeProfileBinding,
      readiness: context.store.activeDeploymentStatusReadiness,
      hasRepositoryToken: context.store.repositoryTokenAvailability.hasToken,
      hasDeploymentToken: context.store.deploymentTokenAvailability.hasToken,
      publishActionMessage: context.store.publishActionMessage,
      deploymentStatusMessage: context.store.deploymentStatusMessage,
      shouldFocusRepositoryToken: context.healthDestination == .repositoryToken,
      navigationRequestID: context.healthNavigationRequestID,
      setRepositoryProvider: { provider in
        context.store.setRepositoryProvider(provider)
      },
      saveRepositoryAccessToken: { token in
        context.store.saveRepositoryAccessToken(token)
      },
      deleteRepositoryAccessToken: {
        context.store.deleteRepositoryAccessToken()
      },
      refreshRepositoryTokenAvailability: {
        context.store.refreshRepositoryTokenAvailability(updatesMessage: true)
      },
      saveDeploymentAccessToken: { token in
        context.store.saveDeploymentAccessToken(token)
      },
      deleteDeploymentAccessToken: {
        context.store.deleteDeploymentAccessToken()
      },
      refreshDeploymentTokenAvailability: {
        context.store.refreshDeploymentTokenAvailability()
      },
      repositoryPermissionContent: { isPresented in
        RepositoryPermissionSettingsView(
          state: RepositoryPermissionSettingsState(
            repositoryProviderDisplayName: context.store.activeProfile.repositoryProvider.displayName,
            repoOwner: context.store.activeProfile.repoOwner,
            repoName: context.store.activeProfile.repoName,
            branch: context.store.activeProfile.branch,
            isChecking: context.store.isRemoteRepositoryChecking,
            activeAccessCheck: context.store.activeRemoteRepositoryAccessCheck,
            hasStaleAccessCheck: context.store.hasStaleRemoteRepositoryAccessCheckForActiveProfile,
            publishActionMessage: context.store.publishActionMessage
          ),
          actions: RepositoryPermissionSettingsActions(
            checkAccess: {
              await context.actions.checkRepositoryTokenAccess()
            },
            copyAccessEvidence: { check in
              context.actions.copyRepositoryAccessEvidence(check)
            }
          ),
          isPresented: isPresented
        )
      }
    )
  }
}
