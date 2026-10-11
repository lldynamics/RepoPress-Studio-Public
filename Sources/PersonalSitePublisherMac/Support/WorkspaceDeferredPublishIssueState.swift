import Foundation
import PublishingWorkbenchCore

/// A compact publish sheet must close before showing the issue's repair surface.
/// Keep the destination local until both sheet dismissal and window activation.
struct WorkspaceDeferredPublishIssueState {
  struct Request {
    let profileID: UUID
    let draftID: UUID
    let target: PublishReadinessTarget
    let scope: PublishScope
  }

  private var request: Request?
  private var didDismissSheet = false

  mutating func enqueue(
    profileID: UUID, draftID: UUID, target: PublishReadinessTarget, scope: PublishScope
  ) {
    request = Request(profileID: profileID, draftID: draftID, target: target, scope: scope)
    didDismissSheet = false
  }

  mutating func sheetDidDismiss() {
    didDismissSheet = true
  }

  mutating func cancel() {
    request = nil
    didDismissSheet = false
  }

  mutating func consume(isKeyWindow: Bool, currentProfileID: UUID) -> Request? {
    guard didDismissSheet, isKeyWindow, let request else { return nil }
    cancel()
    guard request.profileID == currentProfileID else { return nil }
    return request
  }
}
