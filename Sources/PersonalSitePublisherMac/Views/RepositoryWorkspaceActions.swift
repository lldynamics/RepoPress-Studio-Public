import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { store.setPublishActionMessage($0) }
  }

  func ledgerStatusForeground(_ status: ReleaseLedgerStatus) -> AnyShapeStyle {
    switch status {
    case .succeeded:
      return AnyShapeStyle(WorkbenchTheme.success)
    case .deploying, .pendingDeployment, .pendingRemoteRecovery, .pendingRetry, .pendingReview:
      return AnyShapeStyle(WorkbenchTheme.warning)
    case .failed:
      return AnyShapeStyle(WorkbenchTheme.risk)
    case .localOnly, .unknown:
      return AnyShapeStyle(.secondary)
    }
  }
}
