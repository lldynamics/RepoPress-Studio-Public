import Foundation

/// Uses the effective API endpoint, preserving its case-sensitive path.
public struct RemoteRepositoryRollbackIdentity: Codable, Hashable, Sendable {
  public var provider: RepositoryProvider
  public var baseURL: String
  public var owner: String
  public var repository: String
  public var branch: String

  public init(profile: SiteProfile) throws {
    let service = RemoteRepositoryPublishService()
    let apiURL = try service.apiBaseURL(for: profile)
    guard var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
      throw RemoteRepositoryPublishError.invalidBaseURL(profile.repositoryBaseURL)
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    guard let normalizedURL = components.url else {
      throw RemoteRepositoryPublishError.invalidBaseURL(profile.repositoryBaseURL)
    }
    provider = profile.repositoryProvider
    baseURL = service.normalizedAPIBaseURLString(normalizedURL)
    owner = profile.repoOwner.trimmedForPublishing
    repository = profile.repoName.trimmedForPublishing
    branch = profile.branch.trimmedForPublishing.nilIfEmpty ?? "main"
  }
}

public struct RemoteRepositoryRollbackDraft: Codable, Hashable, Sendable {
  public var recordID: UUID
  public var title: String
  public var commitMessage: String
  public var targetBranch: String
  public var commitSHA: String
  public var changedPaths: [String]
  /// Frozen repository coordinates. Older payloads decode as nil and cannot
  /// authorize a remote write using only a commit SHA.
  public var repositoryIdentity: RemoteRepositoryRollbackIdentity?

  public init(
    recordID: UUID,
    title: String,
    commitMessage: String,
    targetBranch: String,
    commitSHA: String,
    changedPaths: [String],
    repositoryIdentity: RemoteRepositoryRollbackIdentity? = nil
  ) {
    self.recordID = recordID
    self.title = title
    self.commitMessage = commitMessage
    self.targetBranch = targetBranch
    self.commitSHA = commitSHA
    self.changedPaths = changedPaths
    self.repositoryIdentity = repositoryIdentity
  }
}

public struct RemoteRepositoryRollbackResult: Codable, Hashable, Sendable {
  public var provider: RepositoryProvider
  public var recordID: UUID
  public var targetBranch: String
  public var rolledBackCommitSHA: String
  public var rollbackCommitSHA: String
  public var changedPaths: [String]
  public var remoteURL: String?

  public init(
    provider: RepositoryProvider,
    recordID: UUID,
    targetBranch: String,
    rolledBackCommitSHA: String,
    rollbackCommitSHA: String,
    changedPaths: [String],
    remoteURL: String? = nil
  ) {
    self.provider = provider
    self.recordID = recordID
    self.targetBranch = targetBranch
    self.rolledBackCommitSHA = rolledBackCommitSHA
    self.rollbackCommitSHA = rollbackCommitSHA
    self.changedPaths = changedPaths
    self.remoteURL = remoteURL
  }

  public var shortRollbackCommitSHA: String {
    String(rollbackCommitSHA.prefix(8))
  }
}

extension RemoteRepositoryRollbackDraft {
  public static func make(record: ReleaseRecord) throws -> RemoteRepositoryRollbackDraft {
    guard let commitSHA = record.commitSHA?.trimmedForPublishing.nilIfEmpty else {
      throw RemoteRepositoryPublishError.missingRollbackCommit
    }
    guard let provider = record.repositoryProvider,
      let baseURL = record.repositoryBaseURL?.trimmedForPublishing.nilIfEmpty,
      let owner = record.repoOwner?.trimmedForPublishing.nilIfEmpty,
      let name = record.repoName?.trimmedForPublishing.nilIfEmpty,
      let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty
        ?? record.branchName?.trimmedForPublishing.nilIfEmpty
    else { throw RemoteRepositoryRollbackSafetyError.missingRecordedIdentity }
    var recordedProfile = SiteProfile.defaultProfile
    recordedProfile.repositoryProvider = provider
    recordedProfile.repositoryBaseURL = baseURL
    recordedProfile.repoOwner = owner
    recordedProfile.repoName = name
    recordedProfile.branch = targetBranch
    let identity = try normalizedRepositoryIdentity(profile: recordedProfile)
    let displayTitle = record.draftTitle ?? record.title
    let rollbackTitle = CoreL10n.format("回滚：%@", displayTitle)
    return RemoteRepositoryRollbackDraft(
      recordID: record.id,
      title: rollbackTitle,
      commitMessage: rollbackTitle,
      targetBranch: targetBranch,
      commitSHA: commitSHA,
      changedPaths: record.changedPaths,
      repositoryIdentity: identity
    )
  }

  public func validateRepositoryIdentity(profile: SiteProfile) throws {
    guard let repositoryIdentity,
      !repositoryIdentity.baseURL.isEmpty,
      !repositoryIdentity.owner.isEmpty,
      !repositoryIdentity.repository.isEmpty,
      !repositoryIdentity.branch.isEmpty
    else { throw RemoteRepositoryRollbackSafetyError.missingRecordedIdentity }
    guard repositoryIdentity == (try Self.normalizedRepositoryIdentity(profile: profile)),
      targetBranch.trimmedForPublishing == repositoryIdentity.branch
    else { throw RemoteRepositoryRollbackSafetyError.repositoryIdentityChanged }
  }

  public static func normalizedRepositoryIdentity(profile: SiteProfile) throws
    -> RemoteRepositoryRollbackIdentity
  {
    try RemoteRepositoryRollbackIdentity(profile: profile)
  }
}

public enum RemoteRepositoryRollbackSafetyError: LocalizedError, Equatable {
  case missingRecordedIdentity
  case missingRecordedProfile
  case repositoryIdentityChanged

  public var errorDescription: String? {
    switch self {
    case .missingRecordedIdentity:
      return CoreL10n.text("发布记录缺少完整仓库身份，无法安全执行线上回滚。")
    case .missingRecordedProfile:
      return CoreL10n.text("发布记录对应的站点配置已不存在，无法执行线上回滚。")
    case .repositoryIdentityChanged:
      return CoreL10n.text("站点的仓库、API 端点或目标分支与发布记录不一致，无法执行线上回滚。")
    }
  }
}
