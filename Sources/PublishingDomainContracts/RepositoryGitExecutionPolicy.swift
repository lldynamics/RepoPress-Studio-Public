import Foundation

/// Explicit, site-owned permissions for local commit execution. Missing policy
/// fields and historical site snapshots retain the isolated default.
public struct RepositoryGitExecutionPolicy: Codable, Hashable, Sendable {
  public var sshCommitSigningEnabled: Bool
  /// An absolute SSH key path. Key material is never stored in the profile.
  public var sshSigningKey: String
  public var trustedHooksRepositoryPath: String?
  public var trustedHooksGitDirectoryPath: String?

  public init(
    sshCommitSigningEnabled: Bool = false,
    sshSigningKey: String = "",
    trustedHooksRepositoryPath: String? = nil,
    trustedHooksGitDirectoryPath: String? = nil
  ) {
    self.sshCommitSigningEnabled = sshCommitSigningEnabled
    self.sshSigningKey = sshSigningKey
    self.trustedHooksRepositoryPath = trustedHooksRepositoryPath
    self.trustedHooksGitDirectoryPath = trustedHooksGitDirectoryPath
  }

  public var hasTrustedHooks: Bool {
    trustedHooksRepositoryPath != nil || trustedHooksGitDirectoryPath != nil
  }

  public var requiresControlledCommitExecution: Bool {
    sshCommitSigningEnabled || hasTrustedHooks
  }

  private enum CodingKeys: String, CodingKey {
    case sshCommitSigningEnabled, sshSigningKey
    case trustedHooksRepositoryPath, trustedHooksGitDirectoryPath
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    sshCommitSigningEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .sshCommitSigningEnabled) ?? false
    sshSigningKey = try values.decodeIfPresent(String.self, forKey: .sshSigningKey) ?? ""
    trustedHooksRepositoryPath = try values.decodeIfPresent(
      String.self, forKey: .trustedHooksRepositoryPath)
    trustedHooksGitDirectoryPath = try values.decodeIfPresent(
      String.self, forKey: .trustedHooksGitDirectoryPath)
  }
}
