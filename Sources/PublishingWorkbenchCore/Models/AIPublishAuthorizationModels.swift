import Foundation

public struct AIPublishAuthorizationFileSnapshot: Hashable, Sendable {
  public let path: String
  public let kind: String
  public let operation: String
  public let contentSHA256: String
  public let expectedRemoteSHA: String?

  public init(
    path: String,
    kind: String,
    operation: String,
    contentSHA256: String,
    expectedRemoteSHA: String? = nil
  ) {
    self.path = path
    self.kind = kind
    self.operation = operation
    self.contentSHA256 = contentSHA256
    self.expectedRemoteSHA = expectedRemoteSHA
  }
}

public struct AIPublishAuthorizationScope: Hashable, Sendable {
  public let profileID: UUID
  public let siteName: String
  public let repositoryProvider: String
  public let repositoryDisplayName: String
  public let repositoryIdentitySHA256: String
  public let targetBranch: String
  public let publishMode: String
  public let publishStrategy: String
  public let localRepositoryIdentitySHA256: String?
  public let localBranchName: String?
  public let localUpstreamName: String?
  public let localIsDetached: Bool
  public let localGitHeadSHA: String?
  public let changedPaths: [String]
  public let files: [AIPublishAuthorizationFileSnapshot]

  public init(
    profileID: UUID,
    siteName: String,
    repositoryProvider: String,
    repositoryDisplayName: String,
    repositoryIdentitySHA256: String,
    targetBranch: String,
    publishMode: String,
    publishStrategy: String,
    localRepositoryIdentitySHA256: String? = nil,
    localBranchName: String? = nil,
    localUpstreamName: String? = nil,
    localIsDetached: Bool = false,
    localGitHeadSHA: String? = nil,
    changedPaths: [String],
    files: [AIPublishAuthorizationFileSnapshot]
  ) {
    self.profileID = profileID
    self.siteName = siteName
    self.repositoryProvider = repositoryProvider
    self.repositoryDisplayName = repositoryDisplayName
    self.repositoryIdentitySHA256 = repositoryIdentitySHA256
    self.targetBranch = targetBranch
    self.publishMode = publishMode
    self.publishStrategy = publishStrategy
    self.localRepositoryIdentitySHA256 = localRepositoryIdentitySHA256
    self.localBranchName = localBranchName
    self.localUpstreamName = localUpstreamName
    self.localIsDetached = localIsDetached
    self.localGitHeadSHA = localGitHeadSHA
    self.changedPaths = changedPaths
    self.files = files
  }

  public var publishModeDisplayName: String {
    switch publishMode {
    case RemoteRepositoryPublishMode.directCommit.rawValue:
      return CoreL10n.text("线上直接提交")
    case RemoteRepositoryPublishMode.reviewRequest.rawValue:
      return CoreL10n.text("线上 PR/MR")
    default:
      return publishMode
    }
  }

  public var repositoryProviderDisplayName: String {
    switch repositoryProvider {
    case RepositoryProvider.github.rawValue:
      return RepositoryProvider.github.displayName
    case RepositoryProvider.gitlab.rawValue:
      return RepositoryProvider.gitlab.displayName
    default:
      return repositoryProvider
    }
  }
}

public struct AIPublishAuthorizationSnapshot: Hashable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let nonce: UUID
  public let generatedAt: Date
  public let expiresAt: Date
  public let scope: AIPublishAuthorizationScope

  public init(
    schemaVersion: Int = currentSchemaVersion,
    nonce: UUID = UUID(),
    generatedAt: Date,
    expiresAt: Date,
    scope: AIPublishAuthorizationScope
  ) {
    self.schemaVersion = schemaVersion
    self.nonce = nonce
    self.generatedAt = generatedAt
    self.expiresAt = expiresAt
    self.scope = scope
  }
}

public enum AIPublishAuthorizationError: Error, Equatable, LocalizedError, Sendable {
  case unavailable(String)
  case invalidVersion
  case expired
  case changed(String)

  public static let reconfirmationMessagePrefix = CoreL10n.text("发布授权已失效")
  /// The batch publisher reports this scope drift before it has a typed
  /// authorization error. Keep the canonical message here so automation can
  /// classify it as a review boundary instead of an execution failure.
  public static let scopeDriftMessage = CoreL10n.text(
    "待发布文件已变化，请重新打开确认页审阅完整清单。"
  )

  public var requiresReconfirmation: Bool {
    switch self {
    case .invalidVersion, .expired, .changed:
      return true
    case .unavailable:
      return false
    }
  }

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message):
      return message
    case .invalidVersion:
      return CoreL10n.format("%@：授权快照版本不再受支持，请重新审阅并确认。", Self.reconfirmationMessagePrefix)
    case .expired:
      return CoreL10n.format("%@：授权已过期，请重新审阅完整文件清单并确认。", Self.reconfirmationMessagePrefix)
    case .changed(let reason):
      return CoreL10n.format("%@：%@，请重新审阅完整文件清单并确认。", Self.reconfirmationMessagePrefix, reason)
    }
  }

  public static func isReconfirmationMessage(_ message: String?) -> Bool {
    guard let message else { return false }
    return message.hasPrefix(reconfirmationMessagePrefix)
      || message == scopeDriftMessage
  }
}
