import Foundation

/// The branch and upstream state reported by a local Git worktree.
public struct RepositoryBranchStatus: Codable, Hashable, Sendable {
  public var branchName: String?
  public var upstreamName: String?
  public var aheadCount: Int
  public var behindCount: Int
  public var isDetached: Bool

  public init(
    branchName: String?,
    upstreamName: String?,
    aheadCount: Int = 0,
    behindCount: Int = 0,
    isDetached: Bool = false
  ) {
    self.branchName = branchName
    self.upstreamName = upstreamName
    self.aheadCount = aheadCount
    self.behindCount = behindCount
    self.isDetached = isDetached
  }
}

/// A local branch returned by Git's branch listing.
public struct RepositoryBranch: Identifiable, Codable, Hashable, Sendable {
  public var id: String { name }
  public var name: String
  public var isCurrent: Bool
  public var upstreamName: String?

  public init(name: String, isCurrent: Bool = false, upstreamName: String? = nil) {
    self.name = name
    self.isCurrent = isCurrent
    self.upstreamName = upstreamName
  }
}

/// A recent commit returned by Git's log formatter.
public struct RepositoryCommitInfo: Identifiable, Codable, Hashable, Sendable {
  public var id: String { sha }
  public var sha: String
  public var shortSHA: String
  public var author: String
  public var date: Date
  public var message: String

  public init(sha: String, shortSHA: String, author: String, date: Date, message: String) {
    self.sha = sha
    self.shortSHA = shortSHA
    self.author = author
    self.date = date
    self.message = message
  }
}
