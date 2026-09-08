import Foundation
import PublishingWorkbenchCore

/// An AI action belongs to the workspace that presented the command sheet.
/// Dismissal and key-window restoration can arrive in either order.
struct WorkspaceDeferredAIRequestState {
  struct Request: Equatable {
    let draftID: UUID?
    let quickPrompt: AIPublishingQuickPrompt?
  }

  private var request: Request?
  private var didDismissSheet = false

  mutating func enqueue(draftID: UUID?, quickPrompt: AIPublishingQuickPrompt?) {
    request = Request(draftID: draftID, quickPrompt: quickPrompt)
    didDismissSheet = false
  }

  mutating func sheetDidDismiss() {
    didDismissSheet = true
  }

  mutating func cancel() {
    request = nil
    didDismissSheet = false
  }

  mutating func consume(isKeyWindow: Bool) -> Request? {
    guard didDismissSheet, isKeyWindow, let request else { return nil }
    cancel()
    return request
  }
}
