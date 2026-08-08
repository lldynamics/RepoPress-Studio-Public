import Foundation

/// The state captured when a chat composer submission starts.
///
/// The independent window and the inspector keep their own ephemeral composer
/// state. This snapshot lets a caller decide whether an async result is still
/// allowed to clear that particular surface's input.
public struct AIChatComposerSubmissionSnapshot: Equatable, Sendable {
  public let conversationID: UUID
  public let text: String
  public let contextReferences: [AIContextReference]
  public let imageAttachments: [AIChatImageAttachment]

  public init(
    conversationID: UUID,
    text: String,
    contextReferences: [AIContextReference],
    imageAttachments: [AIChatImageAttachment]
  ) {
    self.conversationID = conversationID
    self.text = text
    self.contextReferences = contextReferences
    self.imageAttachments = imageAttachments
  }
}

/// Decides whether a completed async send may clear a composer's draft.
///
/// A reply or an accepted user message is necessary, but not sufficient: the
/// user must still be looking at the same conversation and the surface must
/// still contain exactly the input that started the request. This prevents a
/// late result from deleting a newly typed message or another conversation's
/// attachments.
public enum AIChatComposerSubmissionPolicy {
  public static func shouldClearComposer(
    snapshot: AIChatComposerSubmissionSnapshot,
    currentConversationID: UUID?,
    currentText: String,
    currentContextReferences: [AIContextReference],
    currentImageAttachments: [AIChatImageAttachment],
    didReceiveReply: Bool,
    didAcceptSubmittedUserMessage: Bool
  ) -> Bool {
    guard didReceiveReply || didAcceptSubmittedUserMessage else { return false }
    guard currentConversationID == snapshot.conversationID else { return false }
    guard currentText == snapshot.text else { return false }
    guard currentContextReferences == snapshot.contextReferences else { return false }
    guard currentImageAttachments == snapshot.imageAttachments else { return false }
    return true
  }
}
