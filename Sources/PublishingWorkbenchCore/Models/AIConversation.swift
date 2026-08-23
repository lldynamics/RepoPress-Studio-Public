import Foundation

/// The owner of a conversation is explicit.  In particular, `.general` is not
/// represented by a missing draft, a sentinel draft, or a site profile.
public enum AIConversationScope: Codable, Hashable, Sendable {
  case general
  case draft(UUID)

  public var draftID: UUID? {
    guard case .draft(let id) = self else { return nil }
    return id
  }

  public var storageKey: String {
    switch self {
    case .general:
      return "general"
    case .draft(let id):
      return "draft:\(id.uuidString.lowercased())"
    }
  }

  public init(storageKey: String) {
    let prefix = "draft:"
    if storageKey.lowercased().hasPrefix(prefix),
      let id = UUID(uuidString: String(storageKey.dropFirst(prefix.count)))
    {
      self = .draft(id)
    } else {
      self = .general
    }
  }
}

/// Freezes the article conversation selected by a UI surface before any
/// asynchronous attachment preparation begins. The complete value is retained
/// so an in-place mutation, such as clearing a conversation without changing
/// its ID, also fails the pending send closed. A `nil` conversation is a
/// meaningful expectation: none existed at submission time.
public struct AIChatDraftConversationExpectation: Equatable, Sendable {
  public let draftID: UUID
  public let conversation: AIConversation?

  public var conversationID: UUID? { conversation?.id }

  public init(draftID: UUID, conversation: AIConversation?) {
    self.draftID = draftID
    self.conversation = conversation
  }
}

/// Freezes whether a general conversation existed before asynchronous UI
/// preparation, including its exact contents and settings. The outer optional
/// at API call sites means "do not validate"; this value with a `nil`
/// conversation means "validate that none exists".
public struct AIChatGeneralConversationExpectation: Equatable, Sendable {
  public let conversation: AIConversation?

  public var conversationID: UUID? { conversation?.id }

  public init(conversation: AIConversation?) {
    self.conversation = conversation
  }
}

/// The authority a single conversation may use when the connected profile
/// offers Agent tools.  A conversation can only narrow the connection-level
/// permission; it can never grant tools when the connection has disabled them.
public enum AIConversationAgentMode: String, Codable, Hashable, Sendable {
  /// Follow the connection's current tool permission.
  case inheritConnection
  /// Keep this conversation text-only, regardless of the connection setting.
  case textOnly

  /// Resolves the effective permission for this conversation.  This is
  /// deliberately a one-way reduction: `.textOnly` can never become `true`.
  public func effectiveAllowsTools(connectionAllowsTools: Bool) -> Bool {
    switch self {
    case .inheritConnection:
      return connectionAllowsTools
    case .textOnly:
      return false
    }
  }
}

/// A locally persisted AI conversation. Credentials are intentionally excluded
/// and are resolved from the explicitly stored connection profile through the
/// user-selected credential storage mode when a request is sent.
public struct AIConversation: Codable, Hashable, Identifiable, Sendable {
  public static let maximumMessages = 80
  public static let maximumImageBytes: Int64 = 8_000_000
  public static let maximumTextCharacters = 250_000

  public var id: UUID
  public var scope: AIConversationScope
  public var connectionProfileID: UUID?
  public var agentMode: AIConversationAgentMode
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

  /// Compatibility projection for draft-specific callers. New code should use
  /// `scope` so that general conversations cannot accidentally inherit draft
  /// context.
  public var draftID: UUID? { scope.draftID }

  private enum CodingKeys: String, CodingKey {
    case id
    case scope
    case draftID
    case connectionProfileID
    case agentMode
    case title
    case messages
    case contextMode
    case knowledgePolicy
    case modelGrade
    case reasoningLevel
    case selectedModel
    case focusedParagraphID
    case createdAt
    case updatedAt
    case archivedAt
  }

  public init(
    id: UUID = UUID(),
    scope: AIConversationScope,
    connectionProfileID: UUID? = nil,
    agentMode: AIConversationAgentMode = .inheritConnection,
    title: String? = nil,
    messages: [AIPublishingChatMessage] = [],
    contextMode: AIPublishingChatContextMode = .general,
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
    self.scope = scope
    self.connectionProfileID = connectionProfileID
    self.agentMode = agentMode
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

  /// Source compatibility for the pre-scope persistence model.
  public init(
    id: UUID = UUID(),
    draftID: UUID,
    connectionProfileID: UUID? = nil,
    agentMode: AIConversationAgentMode = .inheritConnection,
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
    self.init(
      id: id,
      scope: .draft(draftID),
      connectionProfileID: connectionProfileID,
      agentMode: agentMode,
      title: title,
      messages: messages,
      contextMode: contextMode,
      knowledgePolicy: knowledgePolicy,
      modelGrade: modelGrade,
      reasoningLevel: reasoningLevel,
      selectedModel: selectedModel,
      focusedParagraphID: focusedParagraphID,
      createdAt: createdAt,
      updatedAt: updatedAt,
      archivedAt: archivedAt
    )
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let legacyDraftID = try container.decodeIfPresent(UUID.self, forKey: .draftID)
    let storedScope = try container.decodeIfPresent(AIConversationScope.self, forKey: .scope)
    guard storedScope != nil || legacyDraftID != nil else {
      throw DecodingError.dataCorruptedError(
        forKey: .scope,
        in: container,
        debugDescription: "AI conversation is missing both scope and legacy draftID"
      )
    }
    self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    self.scope =
      storedScope
      ?? legacyDraftID.map(AIConversationScope.draft)
      ?? .general
    self.connectionProfileID = try container.decodeIfPresent(
      UUID.self, forKey: .connectionProfileID)
    // Snapshots written before per-conversation Agent modes existed inherit
    // the connection's setting, preserving the previous behavior safely.
    self.agentMode =
      try container.decodeIfPresent(
        AIConversationAgentMode.self,
        forKey: .agentMode
      ) ?? .inheritConnection
    self.title = try container.decodeIfPresent(String.self, forKey: .title)?.trimmedForPublishing
      .nilIfEmpty
    self.messages =
      try container.decodeIfPresent([AIPublishingChatMessage].self, forKey: .messages) ?? []
    if self.scope == .general {
      // A general owner is authoritative even if an intermediate snapshot
      // carried the old draft-oriented `.site` mode.
      self.contextMode = .general
    } else {
      self.contextMode =
        try container.decodeIfPresent(
          AIPublishingChatContextMode.self,
          forKey: .contextMode
        ) ?? .site
    }
    self.knowledgePolicy =
      try container.decodeIfPresent(KnowledgeRetrievalPolicy.self, forKey: .knowledgePolicy)
      ?? .automatic
    self.modelGrade =
      try container.decodeIfPresent(AIChatModelGrade.self, forKey: .modelGrade) ?? .standard
    self.reasoningLevel =
      try container.decodeIfPresent(AIChatReasoningLevel.self, forKey: .reasoningLevel) ?? .deep
    self.selectedModel =
      (try container.decodeIfPresent(String.self, forKey: .selectedModel) ?? "")
      .trimmedForPublishing
    self.focusedParagraphID = try container.decodeIfPresent(
      String.self, forKey: .focusedParagraphID)?.nilIfEmpty
    self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    self.updatedAt = max(
      try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? self.createdAt,
      self.createdAt
    )
    self.archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(scope, forKey: .scope)
    // Keep the legacy key for draft conversations so older workspaces can
    // still inspect/restore them. General conversations deliberately omit it.
    if let draftID {
      try container.encode(draftID, forKey: .draftID)
    }
    try container.encodeIfPresent(connectionProfileID, forKey: .connectionProfileID)
    try container.encode(agentMode, forKey: .agentMode)
    try container.encodeIfPresent(title, forKey: .title)
    try container.encode(messages, forKey: .messages)
    try container.encode(contextMode, forKey: .contextMode)
    try container.encode(knowledgePolicy, forKey: .knowledgePolicy)
    try container.encode(modelGrade, forKey: .modelGrade)
    try container.encode(reasoningLevel, forKey: .reasoningLevel)
    try container.encode(selectedModel, forKey: .selectedModel)
    try container.encodeIfPresent(focusedParagraphID, forKey: .focusedParagraphID)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
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
    let prepared =
      conversations
      .filter { conversation in
        guard let validDraftIDs else { return true }
        guard let draftID = conversation.draftID else { return true }
        return validDraftIDs.contains(draftID)
      }
      .sorted {
        retentionOrder(
          $0,
          $1,
          preferredConversationIDs: []
        )
      }
      .filter { seenConversationIDs.insert($0.id).inserted }

    let limitedByScope = Dictionary(grouping: prepared, by: { $0.scope.storageKey })
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
    return limitedByScope.map { conversation in
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
      by: { $0.draftID }
    ) {
      guard let draftID else { continue }
      if let candidateID = activeIDs[draftID],
        let candidate = conversationsByID[candidateID],
        candidate.draftID == draftID,
        !candidate.isArchived
      {
        result[draftID] = candidateID
        continue
      }

      result[draftID] =
        draftConversations
        .filter { !$0.isArchived }
        .max { $0.updatedAt < $1.updatedAt }?
        .id
    }
    return result
  }

  public static func validActiveConversationIDsByScope(
    _ activeIDs: [String: UUID],
    conversations: [AIConversation]
  ) -> [String: UUID] {
    let conversationsByID = Dictionary(
      uniqueKeysWithValues: conversations.map { ($0.id, $0) }
    )
    var result: [String: UUID] = [:]

    for (scopeKey, scopedConversations) in Dictionary(
      grouping: conversations,
      by: { $0.scope.storageKey }
    ) {
      if let candidateID = activeIDs[scopeKey],
        let candidate = conversationsByID[candidateID],
        candidate.scope.storageKey == scopeKey,
        !candidate.isArchived
      {
        result[scopeKey] = candidateID
        continue
      }

      result[scopeKey] =
        scopedConversations
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
