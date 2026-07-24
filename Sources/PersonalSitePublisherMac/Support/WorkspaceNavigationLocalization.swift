import Foundation
import PublishingWorkbenchCore
import SwiftUI

func workspaceNavigationLocalizedKey(_ key: String) -> LocalizedStringKey {
  LocalizedStringKey(key)
}

func workspaceNavigationLocalizedString(_ key: String) -> String {
  NSLocalizedString(key, bundle: .main, comment: "Workspace navigation")
}
