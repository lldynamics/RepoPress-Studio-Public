import Foundation

public struct AIPublishingMetadataApplicationRecord: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var siteProfileID: UUID
  public var draftID: UUID
  public var draftTitle: String
  public var createdAt: Date
  public var fields: [AIPublishingMetadataField]
  public var previousTitle: String?
  public var newTitle: String?
  public var previousSlug: String?
  public var newSlug: String?
  public var previousSummary: String?
  public var newSummary: String?
  public var previousTags: [String]?
  public var newTags: [String]?

  public init(
    id: UUID = UUID(),
    siteProfileID: UUID,
    draftID: UUID,
    draftTitle: String,
    createdAt: Date = Date(),
    fields: [AIPublishingMetadataField],
    previousTitle: String? = nil,
    newTitle: String? = nil,
    previousSlug: String? = nil,
    newSlug: String? = nil,
    previousSummary: String? = nil,
    newSummary: String? = nil,
    previousTags: [String]? = nil,
    newTags: [String]? = nil
  ) {
    self.id = id
    self.siteProfileID = siteProfileID
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.createdAt = createdAt
    self.fields = fields
    self.previousTitle = previousTitle
    self.newTitle = newTitle
    self.previousSlug = previousSlug
    self.newSlug = newSlug
    self.previousSummary = previousSummary
    self.newSummary = newSummary
    self.previousTags = previousTags
    self.newTags = newTags
  }

  public var fieldText: String {
    guard !fields.isEmpty else {
      return "无字段"
    }
    return fields.map(\.displayName).joined(separator: " / ")
  }

  public var summaryText: String {
    "\(draftTitle) · \(fieldText)"
  }

  public var diffSummaryText: String {
    var lines: [String] = []
    if previousTitle != nil || newTitle != nil {
      lines.append("标题：\(display(previousTitle)) -> \(display(newTitle))")
    }
    if previousSlug != nil || newSlug != nil {
      lines.append("Slug：\(display(previousSlug)) -> \(display(newSlug))")
    }
    if previousSummary != nil || newSummary != nil {
      lines.append("摘要：\(display(previousSummary)) -> \(display(newSummary))")
    }
    if previousTags != nil || newTags != nil {
      lines.append("Tags：\(display(previousTags)) -> \(display(newTags))")
    }
    return lines.joined(separator: "\n")
  }

  private func display(_ value: String?) -> String {
    guard let value, !value.isEmpty else {
      return "空"
    }
    return value
  }

  private func display(_ values: [String]?) -> String {
    guard let values, !values.isEmpty else {
      return "空"
    }
    return values.joined(separator: ", ")
  }
}

public struct AIPublishingMetadataApplicationRollbackFailure: Codable, Hashable, Sendable {
  public var recordID: UUID
  public var draftTitle: String
  public var message: String

  public init(recordID: UUID, draftTitle: String, message: String) {
    self.recordID = recordID
    self.draftTitle = draftTitle
    self.message = message
  }
}

public struct AIPublishingMetadataApplicationBatchRollbackResult: Codable, Hashable, Sendable {
  public var requestedCount: Int
  public var restoredCount: Int
  public var skippedCount: Int
  public var failures: [AIPublishingMetadataApplicationRollbackFailure]

  public init(
    requestedCount: Int,
    restoredCount: Int,
    skippedCount: Int,
    failures: [AIPublishingMetadataApplicationRollbackFailure]
  ) {
    self.requestedCount = requestedCount
    self.restoredCount = restoredCount
    self.skippedCount = skippedCount
    self.failures = failures
  }

  public var failureCount: Int {
    failures.count
  }
}
