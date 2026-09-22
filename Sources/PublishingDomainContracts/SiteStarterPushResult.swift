public struct SiteStarterPushResult: Codable, Hashable, Sendable {
  public var rootPath: String
  public var branch: String
  public var remoteURL: String
  public var commitSHA: String
  public var committedPaths: [String]
  public var output: String

  public init(
    rootPath: String,
    branch: String,
    remoteURL: String,
    commitSHA: String,
    committedPaths: [String],
    output: String
  ) {
    self.rootPath = rootPath
    self.branch = branch
    self.remoteURL = remoteURL
    self.commitSHA = commitSHA
    self.committedPaths = committedPaths
    self.output = output
  }
}
