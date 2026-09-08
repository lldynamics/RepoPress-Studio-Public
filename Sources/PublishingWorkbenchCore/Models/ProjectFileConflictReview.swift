import Foundation

/// A review is bound to the exact article, site and file bytes that were read.
/// Resolving it revalidates all three before accepting the user's choice.
public struct ProjectFileConflictReview: Sendable {
  let rootIdentity: ProjectFileConflictRootIdentity
  public let draft: ArticleDraft
  public let profile: SiteProfile
  public let repositoryPath: String
  public let rootPath: String
  public let draftDocument: String
  public let diskDocument: String
  public let diskContentDigest: String
  public let diskDraft: ArticleDraft
}

public enum ProjectFileConflictResolution: Sendable {
  case keepBoth
  case useDisk
  case mergedDocument(String)
}

public enum WorkbenchTerminationSaveResult: Equatable, Sendable {
  case saved
  case savedLocally(pendingProjectFileCount: Int)
  case failed(String)
}
