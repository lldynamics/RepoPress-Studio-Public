import Foundation
import PublishingCoreSupport

/// The transport Git will use when it talks to a configured remote.
///
/// This intentionally describes the local Git channel, which is independent
/// from the repository API token stored by the app.
public enum RepositoryGitTransportKind: String, Codable, Hashable, Sendable {
  case ssh
  case https
  case local
  case unknown

  public var displayName: String {
    switch self {
    case .ssh:
      CoreL10n.text("SSH")
    case .https:
      CoreL10n.text("HTTPS")
    case .local:
      CoreL10n.text("本地路径")
    case .unknown:
      CoreL10n.text("未知协议")
    }
  }
}

/// Evidence collected by a read-only Git remote diagnostic.
///
/// A successful check proves only that `git ls-remote` could read the remote.
/// It never runs `git push` (including a dry run), so
/// `writePermissionVerified` is deliberately always `false`.
public struct RepositoryGitTransportCheck: Codable, Hashable, Sendable {
  public var remoteName: String
  public var sanitizedRemoteURL: String?
  public var transport: RepositoryGitTransportKind
  public var targetBranch: String
  public var canReadRemote: Bool
  public var targetBranchExists: Bool?
  public let writePermissionVerified: Bool
  public var summary: String
  public var detail: String
  public var checkedAt: Date

  public init(
    remoteName: String,
    sanitizedRemoteURL: String?,
    transport: RepositoryGitTransportKind,
    targetBranch: String,
    canReadRemote: Bool,
    targetBranchExists: Bool?,
    writePermissionVerified: Bool = false,
    summary: String,
    detail: String,
    checkedAt: Date = Date()
  ) {
    self.remoteName = remoteName
    self.sanitizedRemoteURL = sanitizedRemoteURL
    self.transport = transport
    self.targetBranch = targetBranch
    self.canReadRemote = canReadRemote
    self.targetBranchExists = targetBranchExists
    // This type is evidence from read-only commands only. Keep callers from
    // accidentally serializing an affirmative write claim.
    self.writePermissionVerified = false
    self.summary = summary
    self.detail = detail
    self.checkedAt = checkedAt
  }

  private enum CodingKeys: String, CodingKey {
    case remoteName
    case sanitizedRemoteURL
    case transport
    case targetBranch
    case canReadRemote
    case targetBranchExists
    case writePermissionVerified
    case summary
    case detail
    case checkedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    remoteName = try container.decode(String.self, forKey: .remoteName)
    sanitizedRemoteURL = try container.decodeIfPresent(String.self, forKey: .sanitizedRemoteURL)
    transport = try container.decode(RepositoryGitTransportKind.self, forKey: .transport)
    targetBranch = try container.decode(String.self, forKey: .targetBranch)
    canReadRemote = try container.decode(Bool.self, forKey: .canReadRemote)
    targetBranchExists = try container.decodeIfPresent(Bool.self, forKey: .targetBranchExists)
    // This evidence is read-only by definition. Intentionally discard a
    // persisted value so a stale or tampered cache cannot assert write access.
    writePermissionVerified = false
    summary = try container.decode(String.self, forKey: .summary)
    detail = try container.decode(String.self, forKey: .detail)
    checkedAt = try container.decode(Date.self, forKey: .checkedAt)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(remoteName, forKey: .remoteName)
    try container.encodeIfPresent(sanitizedRemoteURL, forKey: .sanitizedRemoteURL)
    try container.encode(transport, forKey: .transport)
    try container.encode(targetBranch, forKey: .targetBranch)
    try container.encode(canReadRemote, forKey: .canReadRemote)
    try container.encodeIfPresent(targetBranchExists, forKey: .targetBranchExists)
    try container.encode(false, forKey: .writePermissionVerified)
    try container.encode(summary, forKey: .summary)
    try container.encode(detail, forKey: .detail)
    try container.encode(checkedAt, forKey: .checkedAt)
  }
}
