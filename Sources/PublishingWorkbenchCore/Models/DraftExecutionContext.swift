import Foundation

/// Immutable identity used by work that must stay scoped to one draft while
/// the active editor selection is allowed to change independently.
public struct DraftExecutionContext: Hashable, Sendable {
  public let draftID: UUID
  public let profileID: UUID
  public let bodyRevision: UInt64

  public init(draftID: UUID, profileID: UUID, bodyRevision: UInt64) {
    self.draftID = draftID
    self.profileID = profileID
    self.bodyRevision = bodyRevision
  }
}

/// The value returned by a draft-scoped preflight. The result is deliberately
/// not written to the workbench's selection/global preflight projection; a
/// caller can apply it only while its context still belongs to that draft.
public struct DraftPreflightResult: Hashable, Sendable {
  public let context: DraftExecutionContext
  public let issues: [PreflightIssue]

  public init(context: DraftExecutionContext, issues: [PreflightIssue]) {
    self.context = context
    self.issues = issues
  }
}

extension ArticleDraft {
  /// Compares all inputs consumed by preflight while ignoring the asynchronously
  /// derived writing-unit count. A word-count refresh is not a content change
  /// and must not invalidate an otherwise stable detached preflight result.
  func hasSamePreflightInput(as other: ArticleDraft) -> Bool {
    var lhs = self
    var rhs = other
    _ = lhs.storeWordCount(0, for: lhs.bodyMarkdown)
    _ = rhs.storeWordCount(0, for: rhs.bodyMarkdown)
    return lhs == rhs
  }
}
