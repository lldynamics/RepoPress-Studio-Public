import Foundation

public enum AIChatMessageListFollowPolicy {
  public static func shouldResetFollowState(
    previousConversationID: UUID?,
    newConversationID: UUID?
  ) -> Bool {
    previousConversationID != newConversationID
  }

  public static func shouldFollowLatest(
    isFollowingLatest: Bool,
    contentChanged: Bool
  ) -> Bool {
    isFollowingLatest && contentChanged
  }
}
