import Foundation

extension WorkbenchStore {
  @discardableResult
  public func tickRepositoryAndDeploymentPolling(now: Date = Date()) async -> Bool {
    await repositoryDeploymentCoordinator.tickOperationalPolling(store: self, now: now)
  }

  /// Requests the normal operational check after a local repository write.
  /// The repository and deployment stores apply their configured minimum
  /// intervals, so frequent editor saves collapse into a no-op while an
  /// overdue check still runs once.
  func scheduleDueOperationalRefresh() {
    guard !isSafeMode else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      _ = await self.tickRepositoryAndDeploymentPolling(now: Date())
    }
  }

  public func activateQuickHide(reason: String? = nil) {
    privacyProtectionStore.activateQuickHide(reason: reason)
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
