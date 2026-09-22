import Foundation

/// Import results exposed by the library without depending on an application's
/// operation ledger. No document text, paths, or credentials enter this event.
public struct KnowledgeImportEvent: Sendable {
  public enum Outcome: Sendable {
    case succeeded
    case partial
    case failed
    case cancelled
    case recorded
  }

  public let id: UUID
  public let occurredAt: Date
  public let outcome: Outcome
  public let createdItemCount: Int?
  public let updatedItemCount: Int?
  public let skippedItemCount: Int?

  public init(
    id: UUID = UUID(),
    occurredAt: Date = Date(),
    outcome: Outcome,
    createdItemCount: Int? = nil,
    updatedItemCount: Int? = nil,
    skippedItemCount: Int? = nil
  ) {
    self.id = id
    self.occurredAt = occurredAt
    self.outcome = outcome
    self.createdItemCount = createdItemCount
    self.updatedItemCount = updatedItemCount
    self.skippedItemCount = skippedItemCount
  }
}
