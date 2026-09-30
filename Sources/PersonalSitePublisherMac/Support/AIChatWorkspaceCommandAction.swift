import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct AIChatWorkspaceCommandAction: Sendable {
  let isAvailable: Bool
  let unavailableReason: String?
  let open:
    @MainActor @Sendable (
      _ draftID: UUID?,
      _ quickPrompt: AIPublishingQuickPrompt?
    ) -> Void
  var openAfterSheetDismissal: (@MainActor @Sendable (UUID?, AIPublishingQuickPrompt?) -> Void)? =
    nil
  var sheetDidDismiss: (@MainActor @Sendable () -> Void)? = nil
}

private struct AIChatWorkspaceCommandActionEnvironmentKey: EnvironmentKey {
  static let defaultValue: AIChatWorkspaceCommandAction? = nil
}

extension EnvironmentValues {
  var aiChatWorkspaceCommandAction: AIChatWorkspaceCommandAction? {
    get { self[AIChatWorkspaceCommandActionEnvironmentKey.self] }
    set { self[AIChatWorkspaceCommandActionEnvironmentKey.self] = newValue }
  }
}
