import Foundation
import PublishingWorkbenchCore
import SwiftUI

func workspaceNavigationLocalizedKey(_ key: String) -> LocalizedStringKey {
  LocalizedStringKey(key)
}

func workspaceNavigationLocalizedString(_ key: String) -> String {
  NSLocalizedString(key, bundle: .main, comment: "Workspace navigation")
}

extension WorkspaceArea {
  var localizedDisplayName: String {
    switch self {
    case .writing:
      return String(localized: "workspace.area.writing")
    case .publishing:
      return String(localized: "workspace.area.publishing")
    case .site:
      return String(localized: "workspace.area.site")
    }
  }
}
