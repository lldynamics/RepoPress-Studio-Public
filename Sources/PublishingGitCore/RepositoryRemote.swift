import Foundation

public struct RepositoryRemote: Codable, Hashable, Sendable {
  public var remoteURL: String
  public var provider: RepositoryProvider
  public var repositoryBaseURL: String
  public var owner: String
  public var name: String

  public init(
    remoteURL: String,
    provider: RepositoryProvider,
    repositoryBaseURL: String,
    owner: String,
    name: String
  ) {
    self.remoteURL = remoteURL
    self.provider = provider
    self.repositoryBaseURL = repositoryBaseURL
    self.owner = owner
    self.name = name
  }

  public var displayName: String {
    "\(provider.displayName) \(owner)/\(name)"
  }
}
