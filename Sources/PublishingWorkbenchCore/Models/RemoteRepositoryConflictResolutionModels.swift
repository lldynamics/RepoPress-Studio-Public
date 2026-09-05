import Foundation
import PublishingGitCore

public enum RemoteRepositoryConflictResolutionChoice: String, Hashable, Sendable {
  case keepLocal
  case useRemote
  case merge
}

/// One user-reviewed choice inside a conflict-resolution transaction. A
/// choice is inert until a complete plan is submitted for its source session.
public struct RemoteRepositoryConflictResolutionDecision: Hashable, Sendable {
  public var repositoryPath: String
  public var choice: RemoteRepositoryConflictResolutionChoice
  public var mergedDocument: String?

  public init(
    repositoryPath: String,
    choice: RemoteRepositoryConflictResolutionChoice,
    mergedDocument: String? = nil
  ) {
    self.repositoryPath = repositoryPath.normalizedRelativePath()
    self.choice = choice
    self.mergedDocument = choice == .merge ? mergedDocument : nil
  }

  public func isValid(for item: RemoteRepositoryConflictItem) -> Bool {
    guard repositoryPath == item.repositoryPath else { return false }
    switch choice {
    case .keepLocal:
      return item.canKeepLocalOperation
    case .useRemote:
      return item.canUseRemoteText
    case .merge:
      guard item.canMergeText, let mergedDocument else { return false }
      guard mergedDocument.utf8.count <= RepositoryMergeConflictPolicy.maximumFinalByteCount else {
        return false
      }
      return !RepositoryMergeConflictPolicy.containsConflictMarkers(mergedDocument)
    }
  }
}

/// An all-or-nothing set of decisions for one immutable conflict snapshot.
/// The store rejects missing, duplicate, extra, stale, or invalid paths before
/// it performs any draft or remote mutation.
public struct RemoteRepositoryConflictResolutionPlan: Hashable, Sendable {
  public var sessionID: UUID
  public var decisions: [RemoteRepositoryConflictResolutionDecision]

  public init(
    sessionID: UUID,
    decisions: [RemoteRepositoryConflictResolutionDecision]
  ) {
    self.sessionID = sessionID
    self.decisions = decisions
  }

  public func validatedDecisions(
    for session: RemoteRepositoryConflictSession
  ) -> [String: RemoteRepositoryConflictResolutionDecision]? {
    guard sessionID == session.id, session.hasCompleteConflictSnapshot else { return nil }
    let conflictsByPath = Dictionary(
      session.conflicts.map { ($0.repositoryPath, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    guard conflictsByPath.count == session.conflicts.count else { return nil }

    var decisionsByPath: [String: RemoteRepositoryConflictResolutionDecision] = [:]
    for decision in decisions {
      let path = decision.repositoryPath.normalizedRelativePath()
      guard !path.isEmpty,
        decisionsByPath[path] == nil,
        let item = conflictsByPath[path],
        decision.repositoryPath == path,
        decision.isValid(for: item)
      else { return nil }
      decisionsByPath[path] = decision
    }
    guard decisionsByPath.count == conflictsByPath.count else { return nil }
    return decisionsByPath
  }

  public func isComplete(for session: RemoteRepositoryConflictSession) -> Bool {
    validatedDecisions(for: session) != nil
  }
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

/// Freezes the publish candidate set that produced a remote conflict. A
/// resolver must never broaden a single-article conflict into the current
/// batch merely because the drawer's selection changed while it was open.
public enum RemoteRepositoryConflictPublishScope: Hashable, Sendable {
  case selectedDraft(UUID)
  case batch([UUID])

  public var draftIDs: [UUID] {
    switch self {
    case .selectedDraft(let draftID):
      return [draftID]
    case .batch(let draftIDs):
      return draftIDs
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
  public var publishScope: RemoteRepositoryConflictPublishScope
  public var conflicts: [RemoteRepositoryConflictItem]
  public var totalConflictCount: Int
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    profileID: UUID,
    repositoryIdentity: DraftRepositoryIdentity,
    packageFingerprint: String,
    publishScope: RemoteRepositoryConflictPublishScope = .batch([]),
    conflicts: [RemoteRepositoryConflictItem],
    totalConflictCount: Int? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.profileID = profileID
    self.repositoryIdentity = repositoryIdentity
    self.packageFingerprint = packageFingerprint
    self.publishScope = publishScope
    self.conflicts = conflicts
    self.totalConflictCount = max(totalConflictCount ?? conflicts.count, conflicts.count)
    self.createdAt = createdAt
  }

  public var isEmpty: Bool { conflicts.isEmpty }
  public var hasCompleteConflictSnapshot: Bool { totalConflictCount == conflicts.count }
}
