import Foundation

extension WorkbenchStore {
  @discardableResult
  public func tickRepositoryAndDeploymentPolling(now: Date = Date()) async -> Bool {
    await repositoryDeploymentCoordinator.tickOperationalPolling(store: self, now: now)
  }

  public func activateQuickHide(reason: String? = nil) {
    privacyProtectionStore.activateQuickHide(reason: reason)
    setAIPublishingAssistantPresented(false)
    save()
  }

  public func deactivateQuickHide() {
    privacyProtectionStore.deactivateQuickHide()
    save()
  }

  public var activeDeploymentStatusReadiness: DeploymentStatusProviderReadiness {
    deploymentStore.activeDeploymentStatusReadiness(store: self)
  }
}
