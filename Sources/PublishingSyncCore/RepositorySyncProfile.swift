import Foundation
import PublishingGitCore

/// Repository identity required to validate a guarded synchronization.
/// App profile state stays in the composition layer.
public protocol RepositorySyncProfile: Sendable {
  var localRepositoryRootURL: URL? { get }
  var branch: String { get }
  var repoOwner: String { get }
  var repoName: String { get }
  var repositoryProvider: RepositoryProvider { get }
}
