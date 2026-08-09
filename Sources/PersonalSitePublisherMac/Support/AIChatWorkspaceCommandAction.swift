import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct AIChatWorkspaceCommandAction: Sendable {
  let isAvailable: Bool
  let unavailableReason: String?
  let open:
    @MainActor @Sendable (
      _ draftID: UUID,
      _ quickPrompt: AIPublishingQuickPrompt?
    ) -> Void
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
