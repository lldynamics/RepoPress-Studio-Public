import Foundation

public struct DraftTaskQueueState: Equatable {
  public struct Signature: Equatable {
    public var profileID: UUID
    public var updatedAt: Date
    public var statusDescription: String
    public var isPrivate: Bool
    public var title: String
    public var slug: String
    public var summary: String
    public var repositoryPath: String
    public var bodyLength: Int
    public var attachmentFingerprint: String
    public var imageIssueCount: Int
    public var repositoryReadinessFingerprint: String

    public init(
      draft: ArticleDraft,
      profileID: UUID,
      imageIssueCount: Int,
      repositoryReadinessFingerprint: String = ""
    ) {
      self.profileID = profileID
      updatedAt = draft.updatedAt
      statusDescription = String(describing: draft.status)
      isPrivate = draft.isPrivate
      title = draft.title
      slug = draft.slug
      summary = draft.summary
      repositoryPath = draft.repositoryPath ?? ""
      bodyLength = draft.bodyMarkdown.count
      attachmentFingerprint = draft.attachments
        .map { attachment in
          [
            attachment.id.uuidString,
            attachment.repositoryPath,
            attachment.altText,
            attachment.caption
          ].joined(separator: "|")
        }
        .joined(separator: "\n")
      self.imageIssueCount = imageIssueCount
      self.repositoryReadinessFingerprint = repositoryReadinessFingerprint
    }
  }

  public var draftID: UUID
  public var signature: Signature
  public var hasPreflightErrors: Bool
  public var hasImageIssues: Bool

  public init(
    draftID: UUID,
    signature: Signature,
    hasPreflightErrors: Bool,
    hasImageIssues: Bool
  ) {
    self.draftID = draftID
    self.signature = signature
    self.hasPreflightErrors = hasPreflightErrors
    self.hasImageIssues = hasImageIssues
  }
}
