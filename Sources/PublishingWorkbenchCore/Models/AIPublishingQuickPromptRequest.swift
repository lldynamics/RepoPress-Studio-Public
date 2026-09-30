import Foundation

/// A single, ephemeral delivery to the article composer. The request identity
/// changes even when the same template is opened again. A nil conversation
/// means the draft did not yet have a conversation when delivery was requested.
public struct AIPublishingQuickPromptRequest: Equatable, Identifiable, Sendable {
  public let id: UUID
  public let prompt: AIPublishingQuickPrompt
  public let ownerWindowID: UUID?
  public let draftID: UUID
  public let conversationID: UUID?

  public init(
    id: UUID = UUID(),
    prompt: AIPublishingQuickPrompt,
    ownerWindowID: UUID? = nil,
    draftID: UUID,
    conversationID: UUID?
  ) {
    self.id = id
    self.prompt = prompt
    self.ownerWindowID = ownerWindowID
    self.draftID = draftID
    self.conversationID = conversationID
  }

  public func matches(
    ownerWindowID: UUID?,
    draftID: UUID?,
    conversationID: UUID?
  ) -> Bool {
    self.ownerWindowID == ownerWindowID
      && self.draftID == draftID
      && self.conversationID == conversationID
  }
}
