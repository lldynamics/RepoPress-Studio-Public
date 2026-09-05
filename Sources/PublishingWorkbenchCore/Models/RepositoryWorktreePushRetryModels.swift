import Foundation

/// Frozen evidence for commits that exist locally but have not reached the
/// configured remote branch. It can be rebuilt after relaunch from Git itself.
public struct RepositoryWorktreePushRetrySnapshot: Hashable, Sendable {
  public let repositoryRoot: String
  public let gitCommonDirectory: String
  public let branch: String
  public let originURL: String
  public let pushOriginURL: String
  public let remoteBranchSHA: String
  public let localHeadSHA: String
  public let localTreeSHA: String
  public let commitCount: Int
  public let entries: [RepositoryWorktreePublishEntry]

  public var paths: [String] {
    Array(
      Set(
        entries.flatMap { entry in
          [entry.path, entry.sourcePath].compactMap { $0 }
        }
      )
    ).sorted()
  }

  public init(
    repositoryRoot: String,
    gitCommonDirectory: String,
    branch: String,
    originURL: String,
    pushOriginURL: String? = nil,
    remoteBranchSHA: String,
    localHeadSHA: String,
    localTreeSHA: String,
    commitCount: Int,
    entries: [RepositoryWorktreePublishEntry]
  ) {
    self.repositoryRoot = repositoryRoot
    self.gitCommonDirectory = gitCommonDirectory
    self.branch = branch
    self.originURL = originURL
    self.pushOriginURL = pushOriginURL ?? originURL
    self.remoteBranchSHA = remoteBranchSHA
    self.localHeadSHA = localHeadSHA
    self.localTreeSHA = localTreeSHA
    self.commitCount = commitCount
    self.entries = entries
  }
}

public struct RepositoryWorktreePushRetryConfirmation: Hashable, Sendable, Identifiable {
  public let snapshot: RepositoryWorktreePushRetrySnapshot
  public let safetyReport: RepositoryPublishSafetyReport
  public let sitePreflightResult: RepositoryPublishPreflightResult?
  public let fileReviews: [RepositoryWorktreeFileReview]

  public var id: String {
    [
      snapshot.repositoryRoot,
      snapshot.branch,
      snapshot.remoteBranchSHA,
      snapshot.localHeadSHA,
      snapshot.localTreeSHA,
    ].joined(separator: "\u{1E}")
  }

  public init(
    snapshot: RepositoryWorktreePushRetrySnapshot,
    safetyReport: RepositoryPublishSafetyReport = RepositoryPublishSafetyReport(),
    sitePreflightResult: RepositoryPublishPreflightResult? = nil,
    fileReviews: [RepositoryWorktreeFileReview] = []
  ) {
    self.snapshot = snapshot
    self.safetyReport = safetyReport
    self.sitePreflightResult = sitePreflightResult
    self.fileReviews = fileReviews
  }
}
