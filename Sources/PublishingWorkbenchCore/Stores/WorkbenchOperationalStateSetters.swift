import Foundation

extension WorkbenchStore {
  public func setDeploymentStatusMessage(_ message: String?) {
    deploymentStore.deploymentStatusMessage = message
  }

  func setDeploymentStatusSnapshots(_ snapshots: [UUID: DeploymentStatusSnapshot]) {
    deploymentStore.deploymentStatusSnapshots = snapshots
  }
}
