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

public struct RemoteReviewDraftBuilder {
  public init() {}

  public func build(package: PublishPackage, profile: SiteProfile) -> RemoteReviewDraft {
    let body = reviewBody(package: package, profile: profile)
    let targetBranch = profile.branch.nilIfEmpty ?? "main"
    return RemoteReviewDraft(
      provider: profile.repositoryProvider,
      branchName: package.reviewBranchName,
      targetBranch: targetBranch,
      title: package.reviewTitle,
      body: body,
      webURL: reviewWebURL(
        branchName: package.reviewBranchName,
        targetBranch: targetBranch,
        title: package.reviewTitle,
        profile: profile,
        body: body
      )
    )
  }

  public func buildBatch(plan: BatchPublishPlan, profile: SiteProfile) -> RemoteReviewDraft? {
    let items = plan.writableItems
    guard !items.isEmpty else {
      return nil
    }

    let branchName = BatchPublishCommandBuilder().reviewBranchName(for: items, now: plan.generatedAt)
    let targetBranch = profile.branch.nilIfEmpty ?? "main"
    let title = "Publish \(items.count) articles"
    let body = batchReviewBody(items: items, plan: plan, profile: profile, targetBranch: targetBranch)

    return RemoteReviewDraft(
      provider: profile.repositoryProvider,
      branchName: branchName,
      targetBranch: targetBranch,
      title: title,
      body: body,
      webURL: reviewWebURL(
        branchName: branchName,
        targetBranch: targetBranch,
        title: title,
        profile: profile,
        body: body
      )
    )
  }

  public func branchCommands(package: PublishPackage, profile: SiteProfile) -> [String] {
    guard let rootPath = profile.localRepositoryRootURL?.path else {
      return []
    }

    let root = posixShellQuote(rootPath)
    let branch = posixShellQuote(package.reviewBranchName)
    let commitMessage = posixShellQuote(package.commitMessage)
    let paths = package.files
      .map(\.repositoryPath)
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

  private func reviewBody(package: PublishPackage, profile: SiteProfile) -> String {
    let checklist = package.reviewChecklist
      .map { "- [ ] \($0)" }
      .joined(separator: "\n")
    let files = package.files
      .map { file in
        let action = file.operation == .delete ? file.operation.displayName : file.kind.displayName
        return "- \(action): `\(file.repositoryPath)`"
      }
      .joined(separator: "\n")

    return """
    ## 发布内容
    - 站点：\(profile.name)
    - 目标分支：\(profile.branch.nilIfEmpty ?? "main")
    - 文章路径：`\(package.markdownPath)`

    ## 文件
    \(files)

    ## 检查清单
    \(checklist)
    """
  }

  private func batchReviewBody(
    items: [BatchPublishPlanItem],
    plan: BatchPublishPlan,
    profile: SiteProfile,
    targetBranch: String
  ) -> String {
    let articles = items
      .map { "- \($0.draftTitle): `\($0.markdownPath)`（\($0.changedFileCount) 个变化）" }
      .joined(separator: "\n")
    let files = items
      .flatMap { item in
        item.package.files.map { file in
          let action = file.operation == .delete ? file.operation.displayName : file.kind.displayName
          return "- \(action): `\(file.repositoryPath)`"
        }
      }
      .joined(separator: "\n")

    return """
    ## 批量发布内容
    - 站点：\(profile.name)
    - 目标分支：\(targetBranch)
    - 文章数：\(items.count)
    - 文件变化：\(plan.changedFileCount)

    ## 文章
    \(articles)

    ## 文件
    \(files)

    ## 检查清单
    - [ ] Front Matter 已检查
    - [ ] 图片路径和 alt/caption 已检查
    - [ ] 本地预览已确认
    - [ ] 公开风险和私密内容已确认
    """
  }

  private func reviewWebURL(
    branchName: String,
    targetBranch: String,
    title: String,
    profile: SiteProfile,
    body: String
  ) -> URL? {
    let owner = profile.repoOwner.trimmedForPublishing
    let repo = profile.repoName.trimmedForPublishing
    guard !owner.isEmpty, !repo.isEmpty else {
      return nil
    }

    switch profile.repositoryProvider {
    case .github:
      return githubPullRequestURL(
        owner: owner,
        repo: repo,
        branchName: branchName,
        targetBranch: targetBranch,
        title: title,
        profile: profile,
        body: body
      )
    case .gitlab:
      return gitlabMergeRequestURL(
        owner: owner,
        repo: repo,
        branchName: branchName,
        targetBranch: targetBranch,
        title: title,
        profile: profile,
        body: body
      )
    }
  }

  private func githubPullRequestURL(
    owner: String,
    repo: String,
    branchName: String,
    targetBranch: String,
    title: String,
    profile: SiteProfile,
    body: String
  ) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = githubWebHost(from: profile.repositoryBaseURL)
    components.path = "/\(owner)/\(repo)/compare/\(targetBranch)...\(branchName)"
    components.queryItems = [
      URLQueryItem(name: "quick_pull", value: "1"),
      URLQueryItem(name: "title", value: title),
      URLQueryItem(name: "body", value: body),
    ]
    return components.url
  }

  private func gitlabMergeRequestURL(
    owner: String,
    repo: String,
    branchName: String,
    targetBranch: String,
    title: String,
    profile: SiteProfile,
    body: String
  ) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = gitlabWebHost(from: profile.repositoryBaseURL)
    components.path = "/\(owner)/\(repo)/-/merge_requests/new"
    components.queryItems = [
      URLQueryItem(name: "merge_request[source_branch]", value: branchName),
      URLQueryItem(name: "merge_request[target_branch]", value: targetBranch),
      URLQueryItem(name: "merge_request[title]", value: title),
      URLQueryItem(name: "merge_request[description]", value: body),
    ]
    return components.url
  }

  private func githubWebHost(from baseURL: String) -> String {
    guard let host = URL(string: baseURL)?.host, !host.isEmpty else {
      return "github.com"
    }
    return host == "api.github.com" ? "github.com" : host
  }

  private func gitlabWebHost(from baseURL: String) -> String {
    guard let host = URL(string: baseURL)?.host, !host.isEmpty else {
      return "gitlab.com"
    }
    return host
  }
}
