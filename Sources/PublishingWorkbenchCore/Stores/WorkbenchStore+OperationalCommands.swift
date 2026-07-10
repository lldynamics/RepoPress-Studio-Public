import Foundation

extension WorkbenchStore {
  @discardableResult
  public func tickRepositoryAndDeploymentPolling(now: Date = Date()) async -> Bool {
    await repositoryDeploymentCoordinator.tickOperationalPolling(store: self, now: now)
  }

  public func lockPrivacy(reason: String? = nil) {
    privacyMonetizationStore.lockPrivacy(reason: reason)
    setAIPublishingAssistantPresented(false)
    privacyMonetizationStore.recordManualPrivacyMaskShown(reason: reason)
    save()
  }

  public func unlockPrivacy() {
    privacyMonetizationStore.unlockPrivacy()
    privacyMonetizationStore.recordPrivacyMaskRemoved()
    save()
  }

  public func lockPrivacyIfNeededForInactiveScene() {
    let wasLocked = privacyMonetizationStore.isPrivacyLocked
    privacyMonetizationStore.lockPrivacyIfNeededForInactiveScene()
    if !wasLocked && privacyMonetizationStore.isPrivacyLocked {
      privacyMonetizationStore.recordInactivePrivacyMaskShown()
      save()
    }
  }

  public func refreshReleaseQualityGate(projectRoot: URL? = nil) {
    publishingStore.refreshReleaseQualityGate(projectRoot: projectRoot, store: self)
  }

  public var activeDeploymentStatusReadiness: DeploymentStatusProviderReadiness {
    deploymentStore.activeDeploymentStatusReadiness(store: self)
  }
}
