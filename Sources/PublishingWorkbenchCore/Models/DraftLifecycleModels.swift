import Foundation

public enum DraftVersionReason: String, Codable, CaseIterable, Sendable {
  case automatic
  case manual
  case beforeRestore
  case beforeDeletion
  case beforeBatchProcessing

  public var displayName: String {
    switch self {
    case .automatic:
      return "自动保存"
    case .manual:
      return "手动快照"
    case .beforeRestore:
      return "恢复前"
    case .beforeDeletion:
      return "删除前"
    case .beforeBatchProcessing:
      return "批处理前"
    }
  }
}

public struct DraftVersionSnapshot: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var draftID: UUID
  public var capturedAt: Date
  public var reason: DraftVersionReason
  public var draft: ArticleDraft

  public init(
    id: UUID = UUID(),
    draft: ArticleDraft,
    capturedAt: Date = Date(),
    reason: DraftVersionReason
  ) {
    self.id = id
    self.draftID = draft.id
    self.capturedAt = capturedAt
    self.reason = reason
    self.draft = draft
  }
}

public struct RecycledDraft: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID { draft.id }
  public var draft: ArticleDraft
  public var deletedAt: Date

  public init(draft: ArticleDraft, deletedAt: Date = Date()) {
    self.draft = draft
    self.deletedAt = deletedAt
  }
}

public enum DraftRepositoryCleanupStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case completed
  case kept

  public var displayName: String {
    switch self {
    case .pending:
      return "待清理"
    case .completed:
      return "已清理"
    case .kept:
      return "保留文件"
    }
  }
}

public enum DraftRepositoryRemoteCleanupStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case reviewRequested
  case completed

  public var displayName: String {
    switch self {
    case .pending:
      return "待下线"
    case .reviewRequested:
      return "等待 PR/MR 合并"
    case .completed:
      return "已从网站下线"
    }
  }
}

public struct DraftRepositoryCleanupRequest: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var draftID: UUID
  public var siteProfileID: UUID
  public var draftTitle: String
  public var repositoryPath: String
  public var expectedRemoteSHA: String?
  public var expectedContentSHA256: String?
  public var expectedGitBlobSHA: String?
  public var requestedAt: Date
  public var resolvedAt: Date?
  public var status: DraftRepositoryCleanupStatus
  /// Records an explicit user request to delete this file from the remote
  /// repository. Local recycle-bin cleanup deliberately leaves this nil.
  ///
  /// This is intentionally separate from `remoteStatus`: older persisted
  /// records inferred a pending remote deletion from that status alone, which
  /// made an ordinary local deletion capable of being published as a remote
  /// deletion later.
  public var remoteEnqueuedAt: Date?
  public var remoteStatus: DraftRepositoryRemoteCleanupStatus
  public var remoteResolvedAt: Date?
  public var remoteReviewURL: String?
  public var lastRemoteErrorMessage: String?

  public init(
    id: UUID = UUID(),
    draft: ArticleDraft,
    repositoryPath: String,
    requestedAt: Date = Date(),
    resolvedAt: Date? = nil,
    status: DraftRepositoryCleanupStatus = .pending,
    expectedContentSHA256: String? = nil,
    expectedGitBlobSHA: String? = nil,
    remoteEnqueuedAt: Date? = nil,
    remoteStatus: DraftRepositoryRemoteCleanupStatus = .completed,
    remoteResolvedAt: Date? = nil,
    remoteReviewURL: String? = nil,
    lastRemoteErrorMessage: String? = nil
  ) {
    self.id = id
    self.draftID = draft.id
    self.siteProfileID = draft.siteProfileID
    self.draftTitle = draft.title
    self.repositoryPath = repositoryPath
    self.expectedRemoteSHA = draft.repositorySHA?.trimmedForPublishing.nilIfEmpty
    self.expectedContentSHA256 = expectedContentSHA256
    self.expectedGitBlobSHA = expectedGitBlobSHA
    self.requestedAt = requestedAt
    self.resolvedAt = resolvedAt
    self.status = status
    self.remoteEnqueuedAt = remoteEnqueuedAt
    self.remoteStatus = remoteStatus
    self.remoteResolvedAt = remoteResolvedAt
    self.remoteReviewURL = remoteReviewURL
    self.lastRemoteErrorMessage = lastRemoteErrorMessage
  }

  public var needsLocalCleanup: Bool {
    status == .pending
  }

  public var hasRemoteCleanupIntent: Bool {
    remoteEnqueuedAt != nil
  }

  public var needsRemoteCleanup: Bool {
    hasRemoteCleanupIntent && remoteStatus == .pending
  }

  public var isAwaitingRemoteReview: Bool {
    hasRemoteCleanupIntent && remoteStatus == .reviewRequested
  }

  public var needsAttention: Bool {
    needsLocalCleanup || needsRemoteCleanup || isAwaitingRemoteReview
  }

  public mutating func enqueueRemoteCleanup(at date: Date = Date()) {
    remoteEnqueuedAt = date
    remoteStatus = .pending
    remoteResolvedAt = nil
    remoteReviewURL = nil
    lastRemoteErrorMessage = nil
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case draftID
    case siteProfileID
    case draftTitle
    case repositoryPath
    case expectedRemoteSHA
    case expectedContentSHA256
    case expectedGitBlobSHA
    case requestedAt
    case resolvedAt
    case status
    case remoteEnqueuedAt
    case remoteStatus
    case remoteResolvedAt
    case remoteReviewURL
    case lastRemoteErrorMessage
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    draftID = try container.decode(UUID.self, forKey: .draftID)
    siteProfileID = try container.decode(UUID.self, forKey: .siteProfileID)
    draftTitle = try container.decode(String.self, forKey: .draftTitle)
    repositoryPath = try container.decode(String.self, forKey: .repositoryPath)
    expectedRemoteSHA = try container.decodeIfPresent(String.self, forKey: .expectedRemoteSHA)
    expectedContentSHA256 = try container.decodeIfPresent(
      String.self,
      forKey: .expectedContentSHA256
    )
    expectedGitBlobSHA = try container.decodeIfPresent(String.self, forKey: .expectedGitBlobSHA)
    requestedAt = try container.decode(Date.self, forKey: .requestedAt)
    resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
    status =
      try container.decodeIfPresent(DraftRepositoryCleanupStatus.self, forKey: .status)
      ?? .pending
    remoteEnqueuedAt = try container.decodeIfPresent(Date.self, forKey: .remoteEnqueuedAt)
    let decodedRemoteStatus = try container.decodeIfPresent(
      DraftRepositoryRemoteCleanupStatus.self,
      forKey: .remoteStatus
    )
    remoteResolvedAt = try container.decodeIfPresent(Date.self, forKey: .remoteResolvedAt)
    remoteReviewURL = try container.decodeIfPresent(String.self, forKey: .remoteReviewURL)
    // A legacy review URL proves that a remote operation was explicitly
    // submitted. Preserve that safety lock so restoring the draft still
    // requires closing the PR/MR. Ambiguous legacy pending records have no
    // such proof and remain local-only.
    if remoteEnqueuedAt == nil,
      decodedRemoteStatus == .reviewRequested,
      remoteReviewURL?.trimmedForPublishing.nilIfEmpty != nil
    {
      remoteEnqueuedAt = requestedAt
    }
    remoteStatus = remoteEnqueuedAt == nil ? .completed : (decodedRemoteStatus ?? .pending)
    lastRemoteErrorMessage = try container.decodeIfPresent(
      String.self,
      forKey: .lastRemoteErrorMessage
    )
  }
}

public struct DraftLifecycleService: Sendable {
  public static let maximumVersionsPerDraft = 30
  public static let maximumTotalVersions = 500
  public static let automaticSnapshotInterval: TimeInterval = 5 * 60
  /// A large body edit is worth keeping even when it happens inside the
  /// normal automatic snapshot interval. Small metadata edits continue to be
  /// coalesced so typing in the inspector does not repeatedly compare and
  /// snapshot the whole article.
  public static let automaticSnapshotMinimumBodySizeDelta = 500
  public static let maximumRecycledDrafts = 100
  public static let maximumRepositoryCleanupRequests = 200

  public init() {}

  public func recordingVersion(
    of draft: ArticleDraft,
    reason: DraftVersionReason,
    in versions: [DraftVersionSnapshot],
    at capturedAt: Date = Date()
  ) -> [DraftVersionSnapshot] {
    let newestForDraft =
      versions
      .filter { $0.draftID == draft.id }
      .max { $0.capturedAt < $1.capturedAt }

    if reason == .automatic, let newestForDraft {
      let elapsed = capturedAt.timeIntervalSince(newestForDraft.capturedAt)
      let bodySizeDelta = abs(
        newestForDraft.draft.bodyMarkdown.utf8.count - draft.bodyMarkdown.utf8.count
      )
      guard
        elapsed >= Self.automaticSnapshotInterval
          || bodySizeDelta >= Self.automaticSnapshotMinimumBodySizeDelta
      else {
        return versions
      }
    }

    if let newestForDraft, draftsHaveEquivalentContent(newestForDraft.draft, draft) {
      return versions
    }

    var updated = versions
    updated.append(DraftVersionSnapshot(draft: draft, capturedAt: capturedAt, reason: reason))
    updated = trimVersions(updated)
    return updated
  }

  public func recycling(
    _ draft: ArticleDraft,
    existing recycledDrafts: [RecycledDraft],
    at deletedAt: Date = Date()
  ) -> [RecycledDraft] {
    var updated = recycledDrafts.filter { $0.id != draft.id }
    updated.insert(RecycledDraft(draft: draft, deletedAt: deletedAt), at: 0)
    // The configured limit is a soft limit. Every recycle-bin entry is still
    // user-recoverable, so silently dropping the oldest entry would make a
    // later deletion irreversible. Pruning can be added once entries have an
    // explicit, persisted non-recoverable state.
    return updated.sorted { $0.deletedAt > $1.deletedAt }
  }

  public func cleanupRequest(
    for draft: ArticleDraft,
    existing requests: [DraftRepositoryCleanupRequest],
    at requestedAt: Date = Date()
  ) -> [DraftRepositoryCleanupRequest] {
    guard let repositoryPath = draft.repositoryPath?.trimmedForPublishing.nilIfEmpty else {
      return requests
    }
    var updated = requests.filter { !($0.draftID == draft.id && $0.needsAttention) }
    updated.insert(
      DraftRepositoryCleanupRequest(
        draft: draft,
        repositoryPath: repositoryPath,
        requestedAt: requestedAt
      ),
      at: 0
    )
    let sorted = updated.sorted { $0.requestedAt > $1.requestedAt }
    let requestsNeedingAttention = sorted.filter(\.needsAttention)
    guard requestsNeedingAttention.count < Self.maximumRepositoryCleanupRequests else {
      // Never evict an unfinished or review-backed request merely because a
      // soft history limit was reached. In this case, retaining the complete
      // queue is safer than losing a remote cleanup operation.
      return sorted
    }

    let retainedHistoryCount =
      Self.maximumRepositoryCleanupRequests
      - requestsNeedingAttention.count
    let retainedHistory =
      sorted
      .filter { !$0.needsAttention }
      .prefix(retainedHistoryCount)
    return (requestsNeedingAttention + retainedHistory)
      .sorted { $0.requestedAt > $1.requestedAt }
  }

  public func cleanupPackage(for request: DraftRepositoryCleanupRequest) -> PublishPackage {
    PublishPackage(
      draftID: request.draftID,
      title: request.draftTitle,
      markdownPath: request.repositoryPath,
      files: [
        PublishPackageFile(
          kind: .markdown,
          operation: .delete,
          repositoryPath: request.repositoryPath,
          expectedRemoteSHA: request.expectedRemoteSHA,
          expectedContentSHA256: request.expectedContentSHA256,
          expectedGitBlobSHA: request.expectedGitBlobSHA
        )
      ],
      commitMessage: "Delete: \(request.draftTitle)",
      reviewBranchName: "cleanup/\(request.draftID.uuidString.lowercased())",
      reviewTitle: "Delete \(request.draftTitle)",
      reviewChecklist: [
        "已确认文章仍在回收站或已永久删除",
        "已核对待删除的仓库路径",
      ]
    )
  }

  public func cleanupPackage(for requests: [DraftRepositoryCleanupRequest]) -> PublishPackage? {
    let pending =
      requests
      .filter(\.needsRemoteCleanup)
      .sorted { lhs, rhs in
        if lhs.requestedAt != rhs.requestedAt {
          return lhs.requestedAt < rhs.requestedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
    guard let first = pending.first else { return nil }

    var filesByPath: [String: PublishPackageFile] = [:]
    var orderedPaths: [String] = []
    for request in pending {
      let path = request.repositoryPath.normalizedRelativePath()
      guard !path.isEmpty else { continue }
      let candidate = PublishPackageFile(
        kind: .markdown,
        operation: .delete,
        repositoryPath: path,
        expectedRemoteSHA: request.expectedRemoteSHA,
        expectedContentSHA256: request.expectedContentSHA256,
        expectedGitBlobSHA: request.expectedGitBlobSHA
      )
      if filesByPath[path] == nil {
        orderedPaths.append(path)
        filesByPath[path] = candidate
      } else {
        guard let existing = filesByPath[path],
          cleanupBaselineEvidenceIsCompatible(existing, candidate)
        else {
          // Two cleanup records referring to one remote path disagree about
          // the version being deleted. Publishing either would turn an
          // ambiguous historical record into a destructive remote action.
          return nil
        }
        filesByPath[path] = mergingCleanupBaselineEvidence(existing, candidate)
      }
    }
    let files = orderedPaths.compactMap { filesByPath[$0] }
    guard !files.isEmpty else { return nil }

    // The manifest, not the number of historical cleanup records, is the
    // number of files this operation can remove.
    let count = files.count
    return PublishPackage(
      draftID: first.draftID,
      title: count == 1 ? first.draftTitle : "下线 \(count) 篇文章",
      markdownPath: first.repositoryPath,
      files: files,
      commitMessage: count == 1
        ? "Delete: \(first.draftTitle)"
        : "Delete: \(count) articles",
      reviewBranchName: count == 1
        ? "cleanup/\(first.draftID.uuidString.lowercased())"
        : "cleanup/batch-\(first.id.uuidString.lowercased())",
      reviewTitle: count == 1
        ? "Delete \(first.draftTitle)"
        : "Delete \(count) articles",
      reviewChecklist: [
        "已确认文章仍在回收站或已永久删除",
        "已核对待删除的仓库路径",
      ]
    )
  }

  private func trimVersions(_ versions: [DraftVersionSnapshot]) -> [DraftVersionSnapshot] {
    let grouped = Dictionary(grouping: versions, by: \.draftID)
    let perDraftLimited = grouped.values.flatMap { entries in
      entries.sorted { $0.capturedAt > $1.capturedAt }.prefix(Self.maximumVersionsPerDraft)
    }
    return Array(
      perDraftLimited
        .sorted { $0.capturedAt > $1.capturedAt }
        .prefix(Self.maximumTotalVersions)
    )
  }

  private func cleanupBaselineEvidenceIsCompatible(
    _ lhs: PublishPackageFile,
    _ rhs: PublishPackageFile
  ) -> Bool {
    cleanupEvidenceMatches(lhs.expectedRemoteSHA, rhs.expectedRemoteSHA)
      && cleanupEvidenceMatches(lhs.expectedContentSHA256, rhs.expectedContentSHA256)
      && cleanupEvidenceMatches(lhs.expectedGitBlobSHA, rhs.expectedGitBlobSHA)
  }

  private func cleanupEvidenceMatches(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs = lhs?.trimmedForPublishing.nilIfEmpty,
      let rhs = rhs?.trimmedForPublishing.nilIfEmpty
    else {
      return true
    }
    return lhs == rhs
  }

  private func mergingCleanupBaselineEvidence(
    _ lhs: PublishPackageFile,
    _ rhs: PublishPackageFile
  ) -> PublishPackageFile {
    var merged = lhs
    if merged.expectedRemoteSHA?.trimmedForPublishing.nilIfEmpty == nil {
      merged.expectedRemoteSHA = rhs.expectedRemoteSHA?.trimmedForPublishing.nilIfEmpty
    }
    if merged.expectedContentSHA256?.trimmedForPublishing.nilIfEmpty == nil {
      merged.expectedContentSHA256 = rhs.expectedContentSHA256?.trimmedForPublishing.nilIfEmpty
    }
    if merged.expectedGitBlobSHA?.trimmedForPublishing.nilIfEmpty == nil {
      merged.expectedGitBlobSHA = rhs.expectedGitBlobSHA?.trimmedForPublishing.nilIfEmpty
    }
    return merged
  }

  private func draftsHaveEquivalentContent(_ lhs: ArticleDraft, _ rhs: ArticleDraft) -> Bool {
    var normalizedLHS = lhs
    var normalizedRHS = rhs
    normalizedLHS.updatedAt = .distantPast
    normalizedRHS.updatedAt = .distantPast
    return normalizedLHS == normalizedRHS
  }
}
