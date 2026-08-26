import Foundation

/// Stable repository coordinates that scope every remote revision recorded for a draft.
/// A SHA without these coordinates is not safe to reuse after a site switches repository
/// or branch.
public struct DraftRepositoryIdentity: Codable, Hashable, Sendable {
  public var provider: RepositoryProvider
  public var baseURL: String
  public var owner: String
  public var repository: String
  public var branch: String

  public init(
    provider: RepositoryProvider,
    baseURL: String,
    owner: String,
    repository: String,
    branch: String
  ) {
    self.provider = provider
    self.baseURL = Self.normalizedBaseURL(baseURL)
    self.owner = owner.trimmedForPublishing
    self.repository = repository.trimmedForPublishing
    self.branch = branch.trimmedForPublishing.nilIfEmpty ?? "main"
  }

  public init(profile: SiteProfile) {
    self.init(
      provider: profile.repositoryProvider,
      baseURL: profile.repositoryBaseURL,
      owner: profile.repoOwner,
      repository: profile.repoName,
      branch: profile.branch
    )
  }

  private static func normalizedBaseURL(_ value: String) -> String {
    var normalized = value.trimmedForPublishing
    while normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized.lowercased()
  }
}

public enum DraftRepositoryBindingVerification: String, Codable, Hashable, Sendable {
  /// Migrated data or a local project file whose remote ownership has not been proved.
  case legacyUnverified
  /// The provider returned the recorded revision for this exact repository identity/path.
  case verified
}

public enum DraftRepositorySyncState: String, Codable, Hashable, Sendable {
  case localOnly
  case projectSaved
  case synced
  case localChanged
  case diverged
  case awaitingReview
  case failed

  public var displayName: String {
    switch self {
    case .localOnly:
      return CoreL10n.text("仅软件草稿")
    case .projectSaved:
      return CoreL10n.text("已写入项目，未同步远端")
    case .synced:
      return CoreL10n.text("已与远端同步")
    case .localChanged:
      return CoreL10n.text("有本地修改")
    case .diverged:
      return CoreL10n.text("本地与远端已分叉")
    case .awaitingReview:
      return CoreL10n.text("等待 PR/MR 合并")
    case .failed:
      return CoreL10n.text("同步失败")
    }
  }

  public var systemImage: String {
    switch self {
    case .localOnly: return "internaldrive"
    case .projectSaved: return "folder"
    case .synced: return "checkmark.icloud"
    case .localChanged: return "arrow.up.circle"
    case .diverged: return "arrow.triangle.branch"
    case .awaitingReview: return "arrow.triangle.pull"
    case .failed: return "exclamationmark.icloud"
    }
  }
}

/// Repository state is updated as one value so editor content writes cannot combine a new
/// path with an old SHA (or vice versa).
public struct DraftRepositoryBinding: Codable, Hashable, Sendable {
  public var identity: DraftRepositoryIdentity?
  public var repositoryPath: String
  public var remoteRevision: String?
  /// Rendered-content baseline associated with `remoteRevision`. Once a remote
  /// revision is confirmed, local project writes must not advance this digest;
  /// only another verified remote result may replace that baseline. For a
  /// project-only draft it records the latest successfully written file.
  public var renderedContentDigest: String?
  /// Digest of the exact Markdown bytes most recently written to the local
  /// checkout. This is intentionally separate from `renderedContentDigest`:
  /// once a remote revision is verified that property remains the remote CAS
  /// baseline while this one advances with successful local writes.
  public var projectFileContentDigest: String?
  /// Rendered bytes submitted to an open PR/MR. This is separate from the
  /// target-branch baseline above so a pending review can survive startup file
  /// reconciliation while a later local edit still becomes `localChanged`.
  public var pendingReviewContentDigest: String?
  public var verification: DraftRepositoryBindingVerification
  public var syncState: DraftRepositorySyncState
  public var verifiedAt: Date?

  public init(
    identity: DraftRepositoryIdentity?,
    repositoryPath: String,
    remoteRevision: String? = nil,
    renderedContentDigest: String? = nil,
    projectFileContentDigest: String? = nil,
    pendingReviewContentDigest: String? = nil,
    verification: DraftRepositoryBindingVerification = .legacyUnverified,
    syncState: DraftRepositorySyncState = .projectSaved,
    verifiedAt: Date? = nil
  ) {
    self.identity = identity
    self.repositoryPath = repositoryPath.normalizedRelativePath()
    self.remoteRevision = remoteRevision?.trimmedForPublishing.nilIfEmpty
    self.renderedContentDigest = renderedContentDigest?.trimmedForPublishing.nilIfEmpty
    self.projectFileContentDigest = projectFileContentDigest?.trimmedForPublishing.nilIfEmpty
    self.pendingReviewContentDigest = pendingReviewContentDigest?.trimmedForPublishing.nilIfEmpty
    self.verification = verification
    self.syncState = syncState
    self.verifiedAt = verifiedAt
  }
}
