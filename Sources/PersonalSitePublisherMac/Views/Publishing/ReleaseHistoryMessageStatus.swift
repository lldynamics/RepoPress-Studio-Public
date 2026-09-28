import PublishingWorkbenchCore
import SwiftUI

extension PublishActionMessageStatus {
  var releaseHistorySystemImage: String {
    switch self {
    case .information:
      return "info.circle.fill"
    case .inProgress:
      return "arrow.trianglehead.2.clockwise.rotate.90"
    case .success:
      return "checkmark.circle.fill"
    case .warning:
      return "exclamationmark.triangle.fill"
    case .failure:
      return "xmark.octagon.fill"
    }
  }

  var releaseHistoryForeground: Color {
    switch self {
    case .information:
      return WorkbenchTheme.info
    case .inProgress:
      return WorkbenchTheme.progress
    case .success:
      return WorkbenchTheme.success
    case .warning:
      return WorkbenchTheme.warning
    case .failure:
      return WorkbenchTheme.risk
    }
  }
}
