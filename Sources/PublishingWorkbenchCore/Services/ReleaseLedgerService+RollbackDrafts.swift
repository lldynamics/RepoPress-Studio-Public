import Foundation
import PublishingGitCore

extension ReleaseLedgerService {
  public func rollbackDraft(for record: ReleaseRecord) -> ReleaseRollbackDraft? {
    switch record.kind {
    case .localWrite, .batchLocalWrite:
      return localRollbackDraft(for: record)
    case .directCommit, .remoteDirectCommit:
      return commitRollbackDraft(for: record)
    case .reviewBranch:
      return reviewRollbackDraft(for: record)
    case .remoteReviewRequest:
      switch record.reviewStatus?.state {
      case .merged:
        guard record.deploymentCommitSHA != nil else { return nil }
        var mergedRecord = record.deploymentAttributionRecord
        // The original Review URL is evidence for the completed merge, not a
        // rollback Review. Let the commit rollback builder create a new compare URL.
        mergedRecord.reviewURL = nil
        return commitRollbackDraft(for: mergedRecord)
      case .closedWithoutMerge:
        return nil
      case .open, .locked, .none:
        return reviewRollbackDraft(for: record)
      }
    case .remotePublishFailure:
      return failedRemotePublishRollbackDraft(for: record)
    case .remotePreviewBranch, .remoteRollback, .remoteReviewWithdrawal:
      return nil
    }
  }

  private func localRollbackDraft(for record: ReleaseRecord) -> ReleaseRollbackDraft? {
    let paths = record.changedPaths.filter { !$0.trimmedForPublishing.isEmpty }
    guard !paths.isEmpty else {
      return nil
    }

    return ReleaseRollbackDraft(
      title: CoreL10n.format("恢复本地写入：%@", record.draftTitle ?? record.title),
      summary: CoreL10n.text("跟踪文件恢复到 HEAD 并同步取消暂存；本次新增且未跟踪的文件会按记录路径删除。执行前先确认没有其他手动编辑混在这些路径里。"),
      commandLines: paths.map { path in
        let quotedPath = quotedShellPath(path)
        return
          "if git cat-file -e HEAD:\(quotedPath) >/dev/null 2>&1; then git restore --source=HEAD --staged --worktree -- \(quotedPath); else git restore --staged -- \(quotedPath) >/dev/null 2>&1 || true; git clean -fd -- \(quotedPath); fi"
      },
      changedPaths: paths
    )
  }

  private func commitRollbackDraft(for record: ReleaseRecord) -> ReleaseRollbackDraft? {
    guard let commitSHA = record.commitSHA?.trimmedForPublishing, !commitSHA.isEmpty else {
      return nil
    }
    let branchName =
      record.branchName?.trimmedForPublishing.nilIfEmpty ?? record.targetBranch?
      .trimmedForPublishing.nilIfEmpty ?? "main"
    let shortSHA = String(commitSHA.prefix(8))
    let rollbackBranchName = "rollback/\(shortSHA)"
    let reviewTitle = CoreL10n.format("回滚：%@", record.draftTitle ?? record.title)
    let reviewBody = rollbackReviewBody(for: record, commitSHA: commitSHA, branchName: branchName)
    return ReleaseRollbackDraft(
      title: CoreL10n.format("回滚提交：%@", record.draftTitle ?? record.title),
      summary: CoreL10n.format(
        "基于 %@ 创建 %@，生成 revert 提交来撤销 %@，再用下方回滚草稿发起 PR/MR。", branchName, rollbackBranchName, shortSHA
      ),
      commandLines: [
        "git checkout \(quotedShellPath(branchName))",
        "git pull --ff-only",
        "git checkout -b \(quotedShellPath(rollbackBranchName))",
        "git revert --no-edit \(quotedShellPath(commitSHA))",
        "git push origin \(quotedShellPath(rollbackBranchName))",
      ],
      changedPaths: record.changedPaths,
      reviewBranchName: rollbackBranchName,
      reviewTitle: reviewTitle,
      reviewBody: reviewBody,
      reviewURL: record.reviewURL
        ?? remoteRollbackReviewURL(
          for: record,
          sourceBranch: rollbackBranchName,
          targetBranch: branchName,
          title: reviewTitle,
          body: reviewBody
        ),
      remoteURL: remoteCommitURL(for: record, commitSHA: commitSHA)
    )
  }

  private func reviewRollbackDraft(for record: ReleaseRecord) -> ReleaseRollbackDraft? {
    if let reviewURL = record.reviewURL?.trimmedForPublishing, !reviewURL.isEmpty {
      return ReleaseRollbackDraft(
        title: CoreL10n.format("撤回 Review：%@", record.draftTitle ?? record.title),
        summary: CoreL10n.text("关闭或废弃这个 PR/MR；如果已经合并，应改用合并提交或目标分支上的 commit 做 revert。"),
        commandLines: [
          CoreL10n.format("打开 Review 并关闭：%@", reviewURL)
        ],
        changedPaths: record.changedPaths,
        reviewTitle: CoreL10n.format("关闭发布 Review：%@", record.draftTitle ?? record.title),
        reviewBody: closeReviewBody(for: record),
        reviewURL: reviewURL,
        remoteURL: reviewURL
      )
    }

    guard let branchName = record.branchName?.trimmedForPublishing, !branchName.isEmpty else {
      return nil
    }

    return ReleaseRollbackDraft(
      title: CoreL10n.format("撤回发布分支：%@", record.draftTitle ?? record.title),
      summary: CoreL10n.text("删除尚未合并的发布分支。执行前确认该分支没有其他需要保留的提交。"),
      commandLines: [
        "git push origin --delete \(quotedShellPath(branchName))"
      ],
      changedPaths: record.changedPaths,
      reviewBranchName: branchName,
      reviewTitle: CoreL10n.format("关闭发布分支：%@", record.draftTitle ?? record.title),
      reviewBody: closeReviewBody(for: record),
      remoteURL: remoteBranchURL(for: record, branchName: branchName)
    )
  }

  private func failedRemotePublishRollbackDraft(for record: ReleaseRecord) -> ReleaseRollbackDraft?
  {
    let branchName = record.branchName?.trimmedForPublishing.nilIfEmpty
    let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty
    if let branchName, branchName != targetBranch {
      return reviewRollbackDraft(for: record)
    }
    return commitRollbackDraft(for: record)
  }

  private func rollbackReviewBody(
    for record: ReleaseRecord,
    commitSHA: String,
    branchName: String
  ) -> String {
    let paths =
      record.changedPaths.isEmpty
      ? CoreL10n.text("- 未记录变更路径")
      : record.changedPaths.map { "- \($0)" }.joined(separator: "\n")
    return [
      CoreL10n.format("撤销 %@ 在 %@ 上的提交。", commitSHA, branchName),
      "",
      CoreL10n.text("原因："),
      CoreL10n.format("- 回滚发布记录：%@", record.title),
      CoreL10n.format("- 状态摘要：%@", record.summary),
      "",
      CoreL10n.text("变更路径："),
      paths,
      "",
      CoreL10n.text("检查清单："),
      CoreL10n.text("- [ ] 确认此回滚不会删除无关的手动编辑。"),
      CoreL10n.text("- [ ] 合并后验证站点构建和部署。"),
    ].joined(separator: "\n")
  }

  private func closeReviewBody(for record: ReleaseRecord) -> String {
    let paths =
      record.changedPaths.isEmpty
      ? CoreL10n.text("- 未记录变更路径")
      : record.changedPaths.map { "- \($0)" }.joined(separator: "\n")
    return [
      CoreL10n.text("应关闭或取代此发布 Review。"),
      "",
      CoreL10n.text("发布记录："),
      "- \(record.title)",
      "- \(record.summary)",
      "",
      CoreL10n.text("变更路径："),
      paths,
      "",
      CoreL10n.text("检查清单："),
      CoreL10n.text("- [ ] 确认 Review 分支尚未合并。"),
      CoreL10n.text("- [ ] 如果已合并，改为针对目标分支创建 revert 提交。"),
    ].joined(separator: "\n")
  }

  private func remoteCommitURL(for record: ReleaseRecord, commitSHA: String) -> String? {
    guard let provider = record.repositoryProvider,
      let owner = record.repoOwner?.trimmedForPublishing, !owner.isEmpty,
      let repo = record.repoName?.trimmedForPublishing, !repo.isEmpty
    else {
      return nil
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = webHost(provider: provider, baseURL: record.repositoryBaseURL)
    switch provider {
    case .github:
      components.path = "/\(owner)/\(repo)/commit/\(commitSHA)"
    case .gitlab:
      components.path = "/\(owner)/\(repo)/-/commit/\(commitSHA)"
    }
    return components.url?.absoluteString
  }

  private func remoteBranchURL(for record: ReleaseRecord, branchName: String) -> String? {
    guard let provider = record.repositoryProvider,
      let owner = record.repoOwner?.trimmedForPublishing, !owner.isEmpty,
      let repo = record.repoName?.trimmedForPublishing, !repo.isEmpty
    else {
      return nil
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = webHost(provider: provider, baseURL: record.repositoryBaseURL)
    switch provider {
    case .github:
      components.path = "/\(owner)/\(repo)/tree/\(branchName)"
    case .gitlab:
      components.path = "/\(owner)/\(repo)/-/tree/\(branchName)"
    }
    return components.url?.absoluteString
  }

  private func remoteRollbackReviewURL(
    for record: ReleaseRecord,
    sourceBranch: String,
    targetBranch: String,
    title: String,
    body: String
  ) -> String? {
    guard let provider = record.repositoryProvider,
      let owner = record.repoOwner?.trimmedForPublishing, !owner.isEmpty,
      let repo = record.repoName?.trimmedForPublishing, !repo.isEmpty
    else {
      return nil
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = webHost(provider: provider, baseURL: record.repositoryBaseURL)
    switch provider {
    case .github:
      components.path = "/\(owner)/\(repo)/compare/\(targetBranch)...\(sourceBranch)"
      components.queryItems = [
        URLQueryItem(name: "quick_pull", value: "1"),
        URLQueryItem(name: "title", value: title),
        URLQueryItem(name: "body", value: body),
      ]
    case .gitlab:
      components.path = "/\(owner)/\(repo)/-/merge_requests/new"
      components.queryItems = [
        URLQueryItem(name: "merge_request[source_branch]", value: sourceBranch),
        URLQueryItem(name: "merge_request[target_branch]", value: targetBranch),
        URLQueryItem(name: "merge_request[title]", value: title),
        URLQueryItem(name: "merge_request[description]", value: body),
      ]
    }
    return components.url?.absoluteString
  }

  private func webHost(provider: RepositoryProvider, baseURL: String?) -> String {
    let fallback: String
    switch provider {
    case .github:
      fallback = "github.com"
    case .gitlab:
      fallback = "gitlab.com"
    }

    guard let host = baseURL.flatMap({ URL(string: $0)?.host }), !host.isEmpty else {
      return fallback
    }

    if provider == .github, host == "api.github.com" {
      return "github.com"
    }
    return host
  }

  private func quotedShellPath(_ value: String) -> String {
    posixShellQuote(value)
  }
}
