import Foundation

/// A locally persisted AI conversation. Credentials are intentionally excluded;
/// API keys remain in the system Keychain and are resolved from the draft's site
/// profile when a request is sent.
public struct AIConversation: Codable, Hashable, Identifiable, Sendable {
  public static let maximumMessages = 80
  public static let maximumImageBytes: Int64 = 8_000_000
  public static let maximumTextCharacters = 250_000

  public var id: UUID
  public var draftID: UUID
  public var title: String?
  public var messages: [AIPublishingChatMessage]
  public var contextMode: AIPublishingChatContextMode
  public var knowledgePolicy: KnowledgeRetrievalPolicy
  public var modelGrade: AIChatModelGrade
  public var reasoningLevel: AIChatReasoningLevel
  public var selectedModel: String
  public var focusedParagraphID: String?
  public var createdAt: Date
  public var updatedAt: Date
  public var archivedAt: Date?

  public init(
    id: UUID = UUID(),
    draftID: UUID,
    title: String? = nil,
    messages: [AIPublishingChatMessage] = [],
    contextMode: AIPublishingChatContextMode = .site,
    knowledgePolicy: KnowledgeRetrievalPolicy = .automatic,
    modelGrade: AIChatModelGrade = .standard,
    reasoningLevel: AIChatReasoningLevel = .deep,
    selectedModel: String = "",
    focusedParagraphID: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    archivedAt: Date? = nil
  ) {
    self.id = id
    self.draftID = draftID
    self.title = title?.trimmedForPublishing.nilIfEmpty
    self.messages = messages
    self.contextMode = contextMode
    self.knowledgePolicy = knowledgePolicy
    self.modelGrade = modelGrade
    self.reasoningLevel = reasoningLevel
    self.selectedModel = selectedModel.trimmedForPublishing
    self.focusedParagraphID = focusedParagraphID?.nilIfEmpty
    self.createdAt = createdAt
    self.updatedAt = max(updatedAt ?? createdAt, createdAt)
    self.archivedAt = archivedAt
  }

  public var isArchived: Bool {
    archivedAt != nil
  }

  public var sessionState: AIPublishingChatSessionState {
    AIPublishingChatSessionState(
      conversationTitle: title,
      messages: messages,
      contextMode: contextMode,
      knowledgePolicy: knowledgePolicy,
      modelGrade: modelGrade,
      reasoningLevel: reasoningLevel,
      selectedModel: selectedModel,
      focusedParagraphID: focusedParagraphID
    )
  }

  public func prepared(
    maxMessages: Int = AIConversation.maximumMessages,
    maxImageBytes: Int64 = AIConversation.maximumImageBytes,
    maxTextCharacters: Int = AIConversation.maximumTextCharacters
  ) -> AIConversation {
    let preparedState = sessionState.prepared(
      maxMessagesPerConversation: maxMessages,
      maxTotalImageBytes: maxImageBytes,
      maxTotalTextCharacters: maxTextCharacters
    )
    var prepared = self
    prepared.apply(preparedState, updatedAt: updatedAt)
    return prepared
  }

  mutating func apply(
    _ state: AIPublishingChatSessionState,
    updatedAt: Date = Date()
  ) {
    let preparedState = state.prepared(
      maxMessagesPerConversation: Self.maximumMessages,
      maxTotalImageBytes: Self.maximumImageBytes,
      maxTotalTextCharacters: Self.maximumTextCharacters
    )
    title = preparedState.conversationTitle
    messages = preparedState.messages
    contextMode = preparedState.contextMode
    knowledgePolicy = preparedState.knowledgePolicy
    modelGrade = preparedState.modelGrade
    reasoningLevel = preparedState.reasoningLevel
    selectedModel = preparedState.selectedModel.trimmedForPublishing
    focusedParagraphID = preparedState.focusedParagraphID?.nilIfEmpty
    self.updatedAt = max(updatedAt, createdAt)
  }
}

public enum AIConversationRetentionPolicy {
  public static let maximumConversationsPerDraft = 40
  public static let maximumConversationCount = 100
  public static let maximumTotalImageBytes: Int64 = 48_000_000

  public static func limited(
    _ conversations: [AIConversation],
    validDraftIDs: Set<UUID>? = nil,
    preserving preferredConversationIDs: Set<UUID> = []
  ) -> [AIConversation] {
    var seenConversationIDs: Set<UUID> = []
    let prepared = conversations
      .filter { validDraftIDs?.contains($0.draftID) ?? true }
      .sorted {
        retentionOrder(
          $0,
          $1,
          preferredConversationIDs: []
        )
      }
      .filter { seenConversationIDs.insert($0.id).inserted }

    let limitedByDraft = Dictionary(grouping: prepared, by: \.draftID)
      .values
      .flatMap {
        $0.sorted {
          retentionOrder(
            $0,
            $1,
            preferredConversationIDs: preferredConversationIDs
          )
        }
          .prefix(maximumConversationsPerDraft)
      }
      .sorted {
        retentionOrder(
          $0,
          $1,
          preferredConversationIDs: []
        )
      }
      .prefix(maximumConversationCount)

    var remainingImageBytes = maximumTotalImageBytes
    return limitedByDraft.map { conversation in
      let retained = conversation.prepared(
        maxImageBytes: min(
          AIConversation.maximumImageBytes,
          max(remainingImageBytes, 0)
        )
      )
      remainingImageBytes -= retained.sessionState.imageAttachmentByteCount
      return retained
    }
  }

  public static func validActiveConversationIDs(
    _ activeIDs: [UUID: UUID],
    conversations: [AIConversation]
  ) -> [UUID: UUID] {
    let conversationsByID = Dictionary(
      uniqueKeysWithValues: conversations.map { ($0.id, $0) }
    )
    var result: [UUID: UUID] = [:]

    for (draftID, draftConversations) in Dictionary(
      grouping: conversations,
      by: \.draftID
    ) {
      if let candidateID = activeIDs[draftID],
         let candidate = conversationsByID[candidateID],
         candidate.draftID == draftID,
         !candidate.isArchived {
        result[draftID] = candidateID
        continue
      }

      result[draftID] = draftConversations
        .filter { !$0.isArchived }
        .max { $0.updatedAt < $1.updatedAt }?
        .id
    }
    return result
  }

  private static func retentionOrder(
    _ lhs: AIConversation,
    _ rhs: AIConversation,
    preferredConversationIDs: Set<UUID>
  ) -> Bool {
    let lhsIsPreferred = preferredConversationIDs.contains(lhs.id)
    let rhsIsPreferred = preferredConversationIDs.contains(rhs.id)
    if lhsIsPreferred != rhsIsPreferred {
      return lhsIsPreferred
    }
    if lhs.isArchived != rhs.isArchived {
      return !lhs.isArchived
    }
    if lhs.updatedAt != rhs.updatedAt {
      return lhs.updatedAt > rhs.updatedAt
    }
    return lhs.createdAt > rhs.createdAt
  }
}
