import Foundation

public enum AIOutboundPayloadContextCategory: String, Codable, CaseIterable, Hashable, Sendable {
  case conversationHistory
  case currentSelection
  case currentArticle
  case specifiedArticle
  case siteProfile
  case knowledgeEntry
  case publishCheck
  case automaticKnowledge
  case imageAttachment
}

public struct AIOutboundPayloadContextCount: Codable, Hashable, Sendable {
  public let category: AIOutboundPayloadContextCategory
  public let count: Int

  public init(category: AIOutboundPayloadContextCategory, count: Int) {
    self.category = category
    self.count = max(0, count)
  }
}

public enum AIOutboundPayloadStrippedField: String, Codable, CaseIterable, Hashable, Sendable {
  case absoluteLocalPath
  case homeUsername
  case shellCommand
  case previewCommand
  case buildCommand
  case credentialLikeSecret
}

public enum AIOutboundPayloadSensitiveCategory: String, Codable, CaseIterable, Hashable, Sendable {
  case absoluteLocalPath
  case homeUsername
  case shellCommand
  case previewCommand
  case buildCommand
  case credentialLikeSecret
}

/// A content-free, persistable description of one exact outbound AI request.
///
/// The preview deliberately has no field capable of storing message bodies,
/// credentials, raw paths, commands, or image bytes.
public struct AIOutboundPayloadPreview: Codable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public let destination: String
  public let model: String
  public let contextCounts: [AIOutboundPayloadContextCount]
  public let textCharacterCount: Int
  public let imageCount: Int
  public let imageByteCount: Int64
  public let strippedFields: [AIOutboundPayloadStrippedField]
  public let sensitiveCategories: [AIOutboundPayloadSensitiveCategory]
  public let nonce: UUID
  public let fingerprint: String
  public let createdAt: Date
  public let expiresAt: Date
  public let isLoopback: Bool

  public init(
    id: UUID = UUID(),
    destination: String,
    model: String,
    contextCounts: [AIOutboundPayloadContextCount],
    textCharacterCount: Int,
    imageCount: Int,
    imageByteCount: Int64,
    strippedFields: [AIOutboundPayloadStrippedField],
    sensitiveCategories: [AIOutboundPayloadSensitiveCategory],
    nonce: UUID = UUID(),
    fingerprint: String,
    createdAt: Date,
    expiresAt: Date,
    isLoopback: Bool
  ) {
    self.id = id
    self.destination = destination
    self.model = model
    self.contextCounts = contextCounts
    self.textCharacterCount = max(0, textCharacterCount)
    self.imageCount = max(0, imageCount)
    self.imageByteCount = max(0, imageByteCount)
    self.strippedFields = strippedFields
    self.sensitiveCategories = sensitiveCategories
    self.nonce = nonce
    self.fingerprint = fingerprint
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.isLoopback = isLoopback
  }
}

public struct AIOutboundPayloadConfirmation: Hashable, Sendable {
  public let nonce: UUID
  public let fingerprint: String
  public let confirmedAt: Date
  public let expiresAt: Date

  public init(
    nonce: UUID,
    fingerprint: String,
    confirmedAt: Date = Date(),
    expiresAt: Date
  ) {
    self.nonce = nonce
    self.fingerprint = fingerprint
    self.confirmedAt = confirmedAt
    self.expiresAt = expiresAt
  }

  public init(preview: AIOutboundPayloadPreview, confirmedAt: Date = Date()) {
    self.init(
      nonce: preview.nonce,
      fingerprint: preview.fingerprint,
      confirmedAt: confirmedAt,
      expiresAt: preview.expiresAt
    )
  }
}

public struct AIOutboundPayloadApprovalRequest: Identifiable, Sendable {
  public let id: UUID
  public let scopeID: UUID
  public let preview: AIOutboundPayloadPreview

  public init(
    id: UUID = UUID(),
    scopeID: UUID,
    preview: AIOutboundPayloadPreview
  ) {
    self.id = id
    self.scopeID = scopeID
    self.preview = preview
  }
}

public enum AIOutboundPayloadApprovalDecision: Sendable {
  case confirm
  case cancel
}

public enum AIOutboundPayloadApprovalOutcome: Sendable {
  case confirmed(AIOutboundPayloadConfirmation)
  case cancelled
}

public enum AIOutboundPayloadConfirmationError: LocalizedError, Equatable, Sendable {
  case confirmationRequired
  case cancelled
  case expired
  case drifted
  case alreadyConsumed

  public var errorDescription: String? {
    switch self {
    case .confirmationRequired:
      return "AI 发送授权不可用，本次未发送，请重试。"
    case .cancelled:
      return "已取消本次 AI 载荷发送。"
    case .expired:
      return "AI 发送授权已过期，本次未发送，请重试。"
    case .drifted:
      return "发送前 AI 载荷发生变化，本次未发送，请重试。"
    case .alreadyConsumed:
      return "本次 AI 发送授权已使用，请重试。"
    }
  }
}
