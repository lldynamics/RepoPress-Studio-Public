import Foundation

public struct RemoteReviewDraft: Codable, Hashable, Sendable {
  public var provider: RepositoryProvider
  public var branchName: String
  public var targetBranch: String
  public var title: String
  public var body: String
  public var webURL: URL?

  public init(
    provider: RepositoryProvider,
    branchName: String,
    targetBranch: String,
    title: String,
    body: String,
    webURL: URL?
  ) {
    self.provider = provider
    self.branchName = branchName
    self.targetBranch = targetBranch
    self.title = title
    self.body = body
    self.webURL = webURL
  }
}
