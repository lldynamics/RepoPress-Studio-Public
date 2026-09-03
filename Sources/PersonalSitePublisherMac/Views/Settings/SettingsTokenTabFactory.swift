import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SettingsTokenTabFactory {
  static func make(context: SettingsContext) -> some View {
    TokenSettingsView(
      store: context.store,
      activeProfileBinding: context.activeProfileBinding,
      readiness: context.store.activeDeploymentStatusReadiness,
      repositoryTokenAvailability: context.store.repositoryTokenAvailability,
      deploymentTokenAvailability: context.store.deploymentTokenAvailability,
      siteAnalyticsTokenAvailability: context.store.siteAnalyticsTokenAvailability,
      publishActionMessage: context.store.publishActionMessage,
      deploymentStatusMessage: context.store.deploymentStatusMessage,
      siteAnalyticsMessage: context.store.siteAnalyticsMessage,
      navigationDestination: context.navigationDestination,
      navigationRequestID: context.navigationRequestID,
      shouldFocusRepositoryToken: context.healthDestination == .repositoryToken,
      repositoryTokenFocusRequestID: context.healthNavigationRequestID,
      localRepositoryPath: context.store.activeProfile.localRepositoryRootPath,
      chooseLocalRepository: {
        guard let url = RepositorySelectionPanel.chooseDirectory() else { return }
        Task {
          await context.store.repository.rememberRootAsync(url)
        }
      },
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
      saveSiteAnalyticsAccessToken: { token in
        context.store.saveSiteAnalyticsAccessToken(token)
      },
      deleteSiteAnalyticsAccessToken: {
        context.store.deleteSiteAnalyticsAccessToken()
      },
      refreshSiteAnalyticsTokenAvailability: {
        context.store.refreshSiteAnalyticsTokenAvailability()
      },
      repositoryPermissionContent: { isPresented in
        RepositoryPermissionSettingsView(
          state: RepositoryPermissionSettingsState(
            repositoryProviderDisplayName: context.store.activeProfile.repositoryProvider
              .localizedDisplayName,
            repoOwner: context.store.activeProfile.repoOwner,
            repoName: context.store.activeProfile.repoName,
            branch: context.store.activeProfile.branch,
            isChecking: context.store.isRemoteRepositoryChecking,
            isPublishing: context.store.isRemoteRepositoryPublishing,
            activeAccessCheck: context.store.activeRemoteRepositoryAccessCheck,
            hasStaleAccessCheck: context.store.hasStaleRemoteRepositoryAccessCheckForActiveProfile,
            publishActionMessage: context.store.publishActionMessage
          ),
          actions: RepositoryPermissionSettingsActions(
            checkGitTransport: {
              let profileSnapshot = context.store.activeProfile
              return await RepositoryGitTransportCheckService().check(
                profile: profileSnapshot,
                remoteName: "origin"
              )
            },
            checkAccess: {
              await context.actions.checkRepositoryTokenAccess()
            }
          ),
          isPresented: isPresented
        )
      }
    )
  }
}
