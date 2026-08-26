import Foundation

/// Describes local surface state used to gate controls. The local Task is not
/// proof of Store operation ownership; surface cancellation must also present
/// the token that was passed to the Store when this submission was admitted.
public enum AIChatSurfaceOperationOwnershipPolicy {
  public static func ownsLocalTask(
    localTaskExists: Bool,
    ownerToken: UUID?
  ) -> Bool {
    localTaskExists && ownerToken != nil
  }

  public static func canCancelLocalOperation(
    localTaskExists: Bool,
    ownerToken: UUID?
  ) -> Bool {
    ownsLocalTask(
      localTaskExists: localTaskExists,
      ownerToken: ownerToken
    )
  }

  public static func canStartLocalOperation(
    localTaskExists: Bool,
    globalOperationRunning: Bool
  ) -> Bool {
    !localTaskExists
      && !globalOperationRunning
  }
}
