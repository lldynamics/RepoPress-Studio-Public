import Foundation

/// Reminder data never starts a publication or changes the public article date.
public struct ArticlePublishReminderPlan: Equatable, Sendable {
  public static let identifierPrefix = "repopress.publish-reminder."
  public let draftID: UUID
  public let title: String
  public let date: Date

  public init(draftID: UUID, title: String, date: Date) {
    self.draftID = draftID
    self.title = title
    self.date = date
  }

  public var identifier: String { Self.identifierPrefix + draftID.uuidString }

  public static func plans(for drafts: [ArticleDraft], now: Date) -> [Self] {
    drafts.compactMap { draft in
      guard let date = draft.publishReminderAt, date > now,
        date.timeIntervalSince1970.isFinite
      else { return nil }
      return Self(draftID: draft.id, title: draft.title, date: date)
    }
  }
}
