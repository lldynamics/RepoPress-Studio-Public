import Foundation

public enum DraftVersionReason: String, Codable, CaseIterable, Sendable {
  case automatic
  case manual
  case beforeRestore
  case beforeDeletion

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

public struct DraftRepositoryCleanupRequest: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var draftID: UUID
  public var siteProfileID: UUID
  public var draftTitle: String
  public var repositoryPath: String
  public var expectedRemoteSHA: String?
  public var requestedAt: Date
  public var resolvedAt: Date?
  public var status: DraftRepositoryCleanupStatus

  public init(
    id: UUID = UUID(),
    draft: ArticleDraft,
    repositoryPath: String,
    requestedAt: Date = Date(),
    resolvedAt: Date? = nil,
    status: DraftRepositoryCleanupStatus = .pending
  ) {
    self.id = id
    self.draftID = draft.id
    self.siteProfileID = draft.siteProfileID
    self.draftTitle = draft.title
    self.repositoryPath = repositoryPath
    self.expectedRemoteSHA = draft.repositorySHA?.trimmedForPublishing.nilIfEmpty
    self.requestedAt = requestedAt
    self.resolvedAt = resolvedAt
    self.status = status
  }
}

public struct DraftLifecycleService: Sendable {
  public static let maximumVersionsPerDraft = 30
  public static let maximumTotalVersions = 500
  public static let automaticSnapshotInterval: TimeInterval = 5 * 60
  public static let maximumRecycledDrafts = 100
  public static let maximumRepositoryCleanupRequests = 200

  public init() {}

  public func recordingVersion(
    of draft: ArticleDraft,
    reason: DraftVersionReason,
    in versions: [DraftVersionSnapshot],
    at capturedAt: Date = Date()
  ) -> [DraftVersionSnapshot] {
    let newestForDraft = versions
      .filter { $0.draftID == draft.id }
      .max { $0.capturedAt < $1.capturedAt }

    if let newestForDraft, draftsHaveEquivalentContent(newestForDraft.draft, draft) {
      return versions
    }
    if reason == .automatic,
       let newestForDraft,
       capturedAt.timeIntervalSince(newestForDraft.capturedAt) < Self.automaticSnapshotInterval {
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
    return Array(updated.sorted { $0.deletedAt > $1.deletedAt }.prefix(Self.maximumRecycledDrafts))
  }

  public func cleanupRequest(
    for draft: ArticleDraft,
    existing requests: [DraftRepositoryCleanupRequest],
    at requestedAt: Date = Date()
  ) -> [DraftRepositoryCleanupRequest] {
    guard let repositoryPath = draft.repositoryPath?.trimmedForPublishing.nilIfEmpty else {
      return requests
    }
    var updated = requests.filter { !($0.draftID == draft.id && $0.status == .pending) }
    updated.insert(
      DraftRepositoryCleanupRequest(
        draft: draft,
        repositoryPath: repositoryPath,
        requestedAt: requestedAt
      ),
      at: 0
    )
    return Array(
      updated
        .sorted { $0.requestedAt > $1.requestedAt }
        .prefix(Self.maximumRepositoryCleanupRequests)
    )
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
          expectedRemoteSHA: request.expectedRemoteSHA
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

  private func draftsHaveEquivalentContent(_ lhs: ArticleDraft, _ rhs: ArticleDraft) -> Bool {
    var normalizedLHS = lhs
    var normalizedRHS = rhs
    normalizedLHS.updatedAt = .distantPast
    normalizedRHS.updatedAt = .distantPast
    return normalizedLHS == normalizedRHS
  }
}
