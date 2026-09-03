import Foundation

extension RemoteRepositoryPublishService {
  public func prepareReviewMerge(
    record: ReleaseRecord, profile: SiteProfile, token: String?, checkedAt: Date = Date()
  ) async throws -> ReviewMergePlan {
    let repository = try promotionRepository(
      record: record, profile: profile, kind: .remoteReviewRequest)
    let token = try requiredToken(token)
    let status = try await reviewStatus(for: record, profile: profile, token: token)
    guard status.headCommitSHA == (record.acceptedReviewHeadCommitSHA ?? record.commitSHA) else {
      throw PreviewPromotionError.changed
    }
    var observedRecord = record
    observedRecord.reviewStatus = status
    if status.state == .merged {
      return ReviewMergePlan(
        record: observedRecord, profile: profile, sourceCommitSHA: status.headCommitSHA!,
        targetCommitSHA: status.mergeCommitSHA!, files: [], markdown: "", blockers: [],
        mergedCommitSHA: status.mergeCommitSHA, checkedAt: checkedAt)
    }
    guard status.state == .open else {
      throw PreviewPromotionError.unavailable(CoreL10n.text("发布请求已关闭或正在处理，暂时无法合并。"))
    }
    let path = promotionRepositoryPath(repository)
    let pull: ReviewMergeGitHubPull = try await send(
      githubRequest(
        repository: repository, method: "GET",
        path: path + "/pulls/\(status.reviewNumber)", token: token))
    guard pull.head.sha == status.headCommitSHA,
      pull.head.ref == record.branchName, pull.base.ref == profile.branch,
      pull.head.repo?.fullName.caseInsensitiveCompare(repository.displayName) == .orderedSame,
      pull.base.repo?.fullName.caseInsensitiveCompare(repository.displayName) == .orderedSame,
      pull.state == "open", !pull.merged,
      let expectedFileCount = pull.changedFiles, expectedFileCount > 0, expectedFileCount < 300
    else { throw PreviewPromotionError.changed }
    var changes: [PreviewPromotionChange] = []
    for page in 1...3 {
      let pageFiles: [PreviewPromotionChange] = try await send(
        githubRequest(
          repository: repository, method: "GET",
          path: path + "/pulls/\(status.reviewNumber)/files", token: token,
          queryItems: [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: String(page)),
          ]))
      changes += pageFiles
      if pageFiles.count < 100 { break }
    }
    guard changes.count == expectedFileCount else { throw PreviewPromotionError.changed }
    let files = try validatedPromotionFiles(changes, record: record, profile: profile)
    let markdown = try await promotionMarkdown(
      record: record, files: files, source: pull.head.sha, repository: repository, token: token)
    var blockers: [String] = []
    if pull.draft != false { blockers.append(CoreL10n.text("此 PR 仍为草稿，请先将其设为可审阅状态。")) }
    if pull.mergeable != true {
      blockers.append(
        pull.mergeable == false
          ? CoreL10n.text("存在合并冲突，软件不会自动覆盖任一版本。")
          : CoreL10n.text("GitHub 正在计算是否可合并，请稍后重新检查。"))
    }
    if pull.mergeableState != "clean" {
      blockers.append(CoreL10n.text("仓库的审核、分支保护或构建条件尚未全部通过，请处理后继续。"))
    }
    let checks: ReviewMergeGitHubChecks = try await readGitHubMergeCheck(
      githubRequest(
        repository: repository, method: "GET",
        path: path + "/commits/\(encodedPathComponent(pull.head.sha))/check-runs", token: token,
        queryItems: [
          URLQueryItem(name: "per_page", value: "100"),
          URLQueryItem(name: "filter", value: "latest"),
        ]), permission: .checks)
    if checks.totalCount != checks.checkRuns.count {
      blockers.append(CoreL10n.text("无法读取完整构建检查清单，暂时不能确认合并。"))
    }
    for check in checks.checkRuns
    where check.status != "completed"
      || !["success", "neutral", "skipped"].contains(check.conclusion ?? "")
    {
      blockers.append(CoreL10n.text("检查尚未通过：") + check.name)
    }
    let combined: ReviewMergeGitHubStatuses = try await readGitHubMergeCheck(
      githubRequest(
        repository: repository, method: "GET",
        path: path + "/commits/\(encodedPathComponent(pull.head.sha))/status", token: token,
        queryItems: [URLQueryItem(name: "per_page", value: "100")]), permission: .commitStatuses)
    if combined.totalCount > 0 && combined.state != "success" {
      blockers.append(CoreL10n.text("提交状态检查未通过或仍在运行。"))
    }
    // Re-read both moving refs after the multi-request inspection.
    let head = try await githubBranchSHA(
      repository: repository, branch: record.branchName!, token: token)
    let base = try await githubBranchSHA(
      repository: repository, branch: profile.branch, token: token)
    guard head == pull.head.sha, base == pull.base.sha else { throw PreviewPromotionError.changed }
    try Task.checkCancellation()
    return ReviewMergePlan(
      record: observedRecord, profile: profile, sourceCommitSHA: head,
      targetCommitSHA: base, files: files, markdown: markdown, blockers: blockers,
      mergedCommitSHA: nil, checkedAt: checkedAt)
  }

  private func readGitHubMergeCheck<Response: Decodable>(
    _ request: URLRequest, permission: GitHubReviewCheckPermission
  ) async throws -> Response {
    do {
      return try await send(request)
    } catch let RemoteRepositoryPublishError.httpStatus(status, body)
      where status == 403 && body.localizedCaseInsensitiveContains("resource not accessible by")
    {
      // Preserve the sanitized remote detail. Never turn a denied read into an
      // empty/passing result or retry without authentication.
      throw RemoteRepositoryPublishError.reviewCheckPermissionDenied(
        permission: permission, body: body)
    }
  }

  public func mergeReviewedPublication(
    plan: ReviewMergePlan, token: String?,
    beforeMutation: (@Sendable () async throws -> Void)? = nil
  ) async throws -> ReleaseRecord {
    guard plan.canMerge else {
      throw PreviewPromotionError.unavailable(CoreL10n.text("当前发布检查尚未通过，请重新检查后再确认合并。"))
    }
    let fresh = try await prepareReviewMerge(
      record: plan.record, profile: plan.profile, token: token)
    if fresh.mergedCommitSHA != nil { return fresh.record }
    guard fresh.canMerge, fresh.sourceCommitSHA == plan.sourceCommitSHA,
      fresh.targetCommitSHA == plan.targetCommitSHA, fresh.files == plan.files,
      fresh.markdown == plan.markdown
    else { throw PreviewPromotionError.changed }
    let repository = try promotionRepository(
      record: plan.record, profile: plan.profile, kind: .remoteReviewRequest)
    let token = try requiredToken(token)
    guard let number = fresh.record.reviewStatus?.reviewNumber else {
      throw RemoteRepositoryPublishError.invalidResponse
    }
    // No force/admin bypass or branch deletion. GitHub enforces required checks.
    // SHA binds the mutation to the exact source version the user reviewed.
    try Task.checkCancellation()
    try await beforeMutation?()
    let response: ReviewMergeGitHubResult = try await send(
      githubRequest(
        repository: repository, method: "PUT",
        path: promotionRepositoryPath(repository) + "/pulls/\(number)/merge", token: token,
        body: ReviewMergeGitHubRequest(sha: plan.sourceCommitSHA)))
    guard response.merged, let commit = response.sha, !commit.isEmpty else {
      throw PreviewPromotionError.unavailable(
        response.message ?? CoreL10n.text("GitHub 未确认合并成功，请重新检查此发布请求。"))
    }
    var record = fresh.record
    record.reviewStatus = RemoteRepositoryReviewStatusSnapshot(
      provider: .github, reviewNumber: number,
      reviewURL: record.reviewURL!, state: .merged, sourceBranch: record.branchName!,
      targetBranch: plan.profile.branch, headCommitSHA: plan.sourceCommitSHA,
      mergeCommitSHA: commit, checkedAt: Date())
    return record
  }
}

private struct ReviewMergeGitHubPull: Decodable {
  let state: String
  let merged: Bool
  let draft: Bool?
  let mergeable: Bool?
  let mergeableState: String?
  let changedFiles: Int?
  let head: GitHubPullRequestStatusResponse.Branch
  let base: GitHubPullRequestStatusResponse.Branch
  enum CodingKeys: String, CodingKey {
    case state, merged, draft, mergeable, head, base
    case mergeableState = "mergeable_state"
    case changedFiles = "changed_files"
  }
}
private struct ReviewMergeGitHubChecks: Decodable {
  let totalCount: Int
  let checkRuns: [Check]
  struct Check: Decodable {
    let name: String
    let status: String
    let conclusion: String?
  }
  enum CodingKeys: String, CodingKey {
    case totalCount = "total_count"
    case checkRuns = "check_runs"
  }
}
private struct ReviewMergeGitHubStatuses: Decodable {
  let state: String
  let totalCount: Int
  enum CodingKeys: String, CodingKey {
    case state
    case totalCount = "total_count"
  }
}
private struct ReviewMergeGitHubRequest: Encodable { let sha: String }
private struct ReviewMergeGitHubResult: Decodable {
  let merged: Bool
  let sha: String?
  let message: String?
}
