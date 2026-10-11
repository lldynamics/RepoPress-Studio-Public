import PublishingWorkbenchCore
import SwiftUI

enum ReleaseHistoryStatusStyle {
  static func deploymentForeground(_ level: DeploymentStatusLevel) -> AnyShapeStyle {
    switch level {
    case .success:
      return AnyShapeStyle(WorkbenchTheme.success)
    case .running:
      return AnyShapeStyle(WorkbenchTheme.warning)
    case .failed:
      return AnyShapeStyle(WorkbenchTheme.risk)
    case .unknown:
      return AnyShapeStyle(.secondary)
    }
  }

  static func ledgerForeground(_ status: ReleaseLedgerStatus) -> AnyShapeStyle {
    switch status {
    case .succeeded:
      return AnyShapeStyle(WorkbenchTheme.success)
    case .deploying, .pendingDeployment, .pendingRemoteRecovery, .pendingRetry, .pendingReview:
      return AnyShapeStyle(WorkbenchTheme.warning)
    case .failed:
      return AnyShapeStyle(WorkbenchTheme.risk)
    case .localOnly, .previewOnly, .reviewWithdrawn, .unknown:
      return AnyShapeStyle(.secondary)
    }
  }

  static func priorityForeground(_ priority: ReleaseLedgerActionPriority) -> AnyShapeStyle {
    switch priority {
    case .high:
      return AnyShapeStyle(WorkbenchTheme.risk)
    case .medium:
      return AnyShapeStyle(WorkbenchTheme.warning)
    case .low:
      return AnyShapeStyle(.secondary)
    }
  }

  static func priorityBackground(_ priority: ReleaseLedgerActionPriority) -> Color {
    switch priority {
    case .high:
      return WorkbenchTheme.risk.opacity(0.14)
    case .medium:
      return WorkbenchTheme.warning.opacity(0.14)
    case .low:
      return Color.secondary.opacity(0.12)
    }
  }

}
