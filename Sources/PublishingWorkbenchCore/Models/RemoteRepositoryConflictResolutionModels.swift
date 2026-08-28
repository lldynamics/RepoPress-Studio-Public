import Foundation
import PublishingGitCore

public enum RemoteRepositoryConflictResolutionChoice: String, Hashable, Sendable {
  case keepLocal
  case useRemote
  case merge
}

public enum RemoteRepositoryConflictResolutionOutcome: Equatable, Sendable {
  case completed(message: String)
  case sessionRefreshed(message: String)
  case sessionInvalidated(message: String)
  case failed(message: String)

  public var shouldDismissResolver: Bool {
    switch self {
    case .completed, .sessionInvalidated:
      return true
    case .sessionRefreshed, .failed:
      return false
    }
  }

  public var message: String {
    switch self {
    case .completed(let message), .sessionRefreshed(let message),
      .sessionInvalidated(let message), .failed(let message):
      return message
    }
  }
}

/// One bounded, provider-backed conflict snapshot. Text is retained only for
/// Markdown upserts that fit the same safety envelope as the local Git merge
/// resolver; media and unsupported encodings remain diagnostic-only.
public struct RemoteRepositoryConflictItem: Identifiable, Hashable, Sendable {
  public var id: String { repositoryPath }

  public var repositoryPath: String
  public var fileKind: PublishFileKind
  public var operation: PublishFileOperation
  public var expectedSHA: String?
  public var actualSHA: String?
  public var base: RepositoryMergeConflictContent
  public var local: RepositoryMergeConflictContent
  public var remote: RepositoryMergeConflictContent

  public init(
    repositoryPath: String,
    fileKind: PublishFileKind,
    operation: PublishFileOperation,
    expectedSHA: String?,
    actualSHA: String?,
    base: RepositoryMergeConflictContent,
    local: RepositoryMergeConflictContent,
    remote: RepositoryMergeConflictContent
  ) {
    self.repositoryPath = repositoryPath.normalizedRelativePath()
    self.fileKind = fileKind
    self.operation = operation
    self.expectedSHA = expectedSHA?.trimmedForPublishing.nilIfEmpty
    self.actualSHA = actualSHA?.trimmedForPublishing.nilIfEmpty
    self.base = base
    self.local = local
    self.remote = remote
  }

  public var canUseRemoteText: Bool {
    fileKind == .markdown && operation == .upsert && remote.isText
  }

  public var canMergeText: Bool {
    fileKind == .markdown && operation == .upsert && local.isText && remote.isText
  }

  /// Keeping the frozen local operation is always a safe escape hatch because
  /// the resolver routes this choice through PR/MR instead of overwriting the
  /// target branch. This also covers delete conflicts, whose local side is
  /// intentionally represented as missing text.
  public var canKeepLocalOperation: Bool { true }
}

/// Ephemeral evidence for resolving an API preflight conflict. It is never
/// persisted and never contains repository credentials.
public struct RemoteRepositoryConflictSession: Identifiable, Hashable, Sendable {
  public var id: UUID
  public var profileID: UUID
  public var repositoryIdentity: DraftRepositoryIdentity
  public var packageFingerprint: String
  public var conflicts: [RemoteRepositoryConflictItem]
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    profileID: UUID,
    repositoryIdentity: DraftRepositoryIdentity,
    packageFingerprint: String,
    conflicts: [RemoteRepositoryConflictItem],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.profileID = profileID
    self.repositoryIdentity = repositoryIdentity
    self.packageFingerprint = packageFingerprint
    self.conflicts = conflicts
    self.createdAt = createdAt
  }

  public var isEmpty: Bool { conflicts.isEmpty }
}
