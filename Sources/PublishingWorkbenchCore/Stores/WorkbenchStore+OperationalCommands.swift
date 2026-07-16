import Foundation

extension WorkbenchStore {
  @discardableResult
  public func tickRepositoryAndDeploymentPolling(now: Date = Date()) async -> Bool {
    await repositoryDeploymentCoordinator.tickOperationalPolling(store: self, now: now)
  }

  public func lockPrivacy(reason: String? = nil) {
    privacyMonetizationStore.lockPrivacy(reason: reason)
    setAIPublishingAssistantPresented(false)
    save()
  }

  public func unlockPrivacy() {
    privacyMonetizationStore.unlockPrivacy()
    save()
  }

  public var activeDeploymentStatusReadiness: DeploymentStatusProviderReadiness {
    deploymentStore.activeDeploymentStatusReadiness(store: self)
  }
}
