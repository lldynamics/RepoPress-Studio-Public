import Foundation
import PublishingCoreSupport

/// Foundation-only inputs for constructing a hosted pull/merge request URL.
/// Workbench-specific profile and localization decisions stay outside GitCore.
public struct RepositoryReviewURLInput: Hashable, Sendable {
  public var provider: RepositoryProvider
  public var repositoryBaseURL: String
  public var owner: String
  public var repositoryName: String
  public var sourceBranch: String
  public var targetBranch: String
  public var title: String
  public var body: String

  public init(
    provider: RepositoryProvider,
    repositoryBaseURL: String,
    owner: String,
    repositoryName: String,
    sourceBranch: String,
    targetBranch: String,
    title: String,
    body: String
  ) {
    self.provider = provider
    self.repositoryBaseURL = repositoryBaseURL
    self.owner = owner
    self.repositoryName = repositoryName
    self.sourceBranch = sourceBranch
    self.targetBranch = targetBranch
    self.title = title
    self.body = body
  }
}

public struct RepositoryReviewURLBuilder: Sendable {
  public init() {}

  public func buildURL(for input: RepositoryReviewURLInput) -> URL? {
    let owner = input.owner.trimmedForPublishing
    let repositoryName = input.repositoryName.trimmedForPublishing
    guard !owner.isEmpty, !repositoryName.isEmpty else {
      return nil
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = webHost(for: input.provider, baseURL: input.repositoryBaseURL)

    switch input.provider {
    case .github:
      components.path = "/" + owner + "/" + repositoryName
        + "/compare/" + input.targetBranch + "..." + input.sourceBranch
      components.queryItems = [
        URLQueryItem(name: "quick_pull", value: "1"),
        URLQueryItem(name: "title", value: input.title),
        URLQueryItem(name: "body", value: input.body),
      ]
    case .gitlab:
      components.path = "/" + owner + "/" + repositoryName + "/-/merge_requests/new"
      components.queryItems = [
        URLQueryItem(name: "merge_request[source_branch]", value: input.sourceBranch),
        URLQueryItem(name: "merge_request[target_branch]", value: input.targetBranch),
        URLQueryItem(name: "merge_request[title]", value: input.title),
        URLQueryItem(name: "merge_request[description]", value: input.body),
      ]
    }

    return components.url
  }

  private func webHost(for provider: RepositoryProvider, baseURL: String) -> String {
    guard let host = URL(string: baseURL)?.host, !host.isEmpty else {
      return provider == .github ? "github.com" : "gitlab.com"
    }

    switch provider {
    case .github:
      return host == "api.github.com" ? "github.com" : host
    case .gitlab:
      return host
    }
  }
}

/// Foundation-only inputs for the copyable local branch preparation commands.
public struct RemoteReviewBranchCommandInput: Hashable, Sendable {
  public var rootPath: String
  public var branchName: String
  public var commitMessage: String
  public var repositoryPaths: [String]

  public init(
    rootPath: String,
    branchName: String,
    commitMessage: String,
    repositoryPaths: [String]
  ) {
    self.rootPath = rootPath
    self.branchName = branchName
    self.commitMessage = commitMessage
    self.repositoryPaths = repositoryPaths
  }
}

public struct RemoteReviewBranchCommandBuilder: Sendable {
  public init() {}

  public func buildCommands(for input: RemoteReviewBranchCommandInput) -> [String] {
    let root = posixShellQuote(input.rootPath)
    let branch = posixShellQuote(input.branchName)
    let commitMessage = posixShellQuote(input.commitMessage)
    let paths = input.repositoryPaths
      .map(posixShellQuote)
      .joined(separator: " ")

    return [
      "cd \(root)",
      "git switch -c \(branch)",
      "git add \(paths)",
      "git commit -m \(commitMessage)",
      "git push -u origin \(branch)",
    ]
  }
}
