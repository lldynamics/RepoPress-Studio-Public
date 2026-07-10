import Foundation

extension WorkbenchStore {
  public func setMonetizationMessage(_ message: String?) {
    privacyMonetizationStore.monetizationMessage = message
  }

  public func setDeploymentStatusMessage(_ message: String?) {
    deploymentStore.deploymentStatusMessage = message
  }

  func setDeploymentStatusSnapshots(_ snapshots: [UUID: DeploymentStatusSnapshot]) {
    deploymentStore.deploymentStatusSnapshots = snapshots
  }
}
