import Foundation

public enum AIChatSurface: String, Codable, Hashable, Sendable {
  case inspector
  case independentWindow
}

/// Ephemeral composer state is scoped to a UI surface and conversation. It is
/// intentionally separate from `AIConversation`, whose messages are shared.
public struct AIChatSurfaceState: Equatable, Sendable {
  public let surface: AIChatSurface
  public var selectedConversationID: UUID?
  public private(set) var composerTextByConversation: [UUID: String]
  public private(set) var contextReferencesByConversation: [UUID: [AIContextReference]]
  public private(set) var imageAttachmentsByConversation: [UUID: [AIChatImageAttachment]]
  public private(set) var imageAttachmentIDsByConversation: [UUID: Set<UUID>]

  public init(
    surface: AIChatSurface,
    selectedConversationID: UUID? = nil,
    composerTextByConversation: [UUID: String] = [:],
    contextReferencesByConversation: [UUID: [AIContextReference]] = [:],
    imageAttachmentsByConversation: [UUID: [AIChatImageAttachment]] = [:],
    imageAttachmentIDsByConversation: [UUID: Set<UUID>] = [:]
  ) {
    self.surface = surface
    self.selectedConversationID = selectedConversationID
    self.composerTextByConversation = composerTextByConversation
    self.contextReferencesByConversation = contextReferencesByConversation
    self.imageAttachmentsByConversation = imageAttachmentsByConversation
    self.imageAttachmentIDsByConversation = imageAttachmentIDsByConversation
  }

  public func composerText(for conversationID: UUID) -> String {
    composerTextByConversation[conversationID] ?? ""
  }

  public func contextReferences(for conversationID: UUID) -> [AIContextReference] {
    contextReferencesByConversation[conversationID] ?? []
  }

  public func imageAttachments(for conversationID: UUID) -> [AIChatImageAttachment] {
    imageAttachmentsByConversation[conversationID] ?? []
  }

  public func imageAttachmentIDs(for conversationID: UUID) -> Set<UUID> {
    imageAttachmentIDsByConversation[conversationID] ?? []
  }

  public var conversationsWithEphemeralState: Set<UUID> {
    var result = Set(composerTextByConversation.keys)
    result.formUnion(contextReferencesByConversation.keys)
    result.formUnion(imageAttachmentsByConversation.keys)
    result.formUnion(imageAttachmentIDsByConversation.keys)
    return result
  }

  public mutating func setComposerText(_ text: String, for conversationID: UUID) {
    composerTextByConversation[conversationID] = text
  }

  public mutating func setContextReferences(
    _ references: [AIContextReference],
    for conversationID: UUID
  ) {
    contextReferencesByConversation[conversationID] = references
  }

  public mutating func setImageAttachments(
    _ attachments: [AIChatImageAttachment],
    for conversationID: UUID
  ) {
    imageAttachmentsByConversation[conversationID] = attachments
  }

  public mutating func setImageAttachmentIDs(
    _ attachmentIDs: Set<UUID>,
    for conversationID: UUID
  ) {
    imageAttachmentIDsByConversation[conversationID] = attachmentIDs
  }

  public mutating func clearComposer(for conversationID: UUID) {
    composerTextByConversation[conversationID] = ""
    contextReferencesByConversation[conversationID] = []
    imageAttachmentsByConversation[conversationID] = []
    imageAttachmentIDsByConversation[conversationID] = []
  }

  /// Releases all ephemeral state for a conversation, including image bytes.
  /// This is used when a conversation is deleted/archived or a window is
  /// destroyed; `clearComposer` intentionally remains useful for an accepted
  /// send without changing the surface's conversation bookkeeping.
  public mutating func discardState(for conversationID: UUID) {
    composerTextByConversation.removeValue(forKey: conversationID)
    contextReferencesByConversation.removeValue(forKey: conversationID)
    imageAttachmentsByConversation.removeValue(forKey: conversationID)
    imageAttachmentIDsByConversation.removeValue(forKey: conversationID)
    if selectedConversationID == conversationID {
      selectedConversationID = nil
    }
  }

  public mutating func discardAllState() {
    for conversationID in conversationsWithEphemeralState {
      discardState(for: conversationID)
    }
    selectedConversationID = nil
  }
}
