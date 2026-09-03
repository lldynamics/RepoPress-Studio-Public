import Foundation

extension RemoteRepositoryPublishService {
  public func preparePreviewPromotion(
    record: ReleaseRecord, profile: SiteProfile, token: String?, checkedAt: Date = Date()
  ) async throws -> PreviewPromotionPlan {
    let repository = try promotionRepository(
      record: record, profile: profile, kind: .remotePreviewBranch)
    let token = try requiredToken(token)
    let source = try await githubBranchSHA(
      repository: repository, branch: record.branchName!, token: token)
    if let recordedCommit = record.commitSHA?.trimmedForPublishing.nilIfEmpty,
      source != recordedCommit
    {
      throw PreviewPromotionError.changed
    }
    let target = try await githubBranchSHA(
      repository: repository, branch: profile.branch, token: token)
    let compare: PreviewPromotionComparison = try await send(
      githubRequest(
        repository: repository, method: "GET",
        path: promotionRepositoryPath(repository)
          + "/compare/\(encodedPathComponent(target))...\(encodedPathComponent(source))",
        token: token, queryItems: [URLQueryItem(name: "per_page", value: "1")]
      ))
    // GitHub returns at most 300 file changes on the first comparison page.
    // Never treat a capped response as a complete reviewed branch.
    guard let changes = compare.files, changes.count < 300 else {
      throw PreviewPromotionError.unavailable(CoreL10n.text("分支差异过大，无法确认完整文件清单；请使用单篇发布。"))
    }
    let files = try validatedPromotionFiles(changes, record: record, profile: profile)
    guard !files.isEmpty else {
      throw PreviewPromotionError.unavailable(CoreL10n.text("预览版本没有待合入内容；请到正式发布记录检查部署。"))
    }
    let markdown = try await promotionMarkdown(
      record: record, files: files, source: source, repository: repository, token: token)
    try Task.checkCancellation()
    return PreviewPromotionPlan(
      record: record, profile: profile, sourceCommitSHA: source,
      targetCommitSHA: target, files: files, markdown: markdown, checkedAt: checkedAt)
  }

  /// The confirmation authorizes creating a PR only. Merging requires a fresh,
  /// separate inspection; the original preview record remains unchanged.
  public func createReviewForPreview(
    plan: PreviewPromotionPlan, token: String?,
    beforeMutation: (@Sendable () async throws -> Void)? = nil
  ) async throws -> ReleaseRecord {
    let fresh = try await preparePreviewPromotion(
      record: plan.record, profile: plan.profile, token: token)
    guard fresh.sourceCommitSHA == plan.sourceCommitSHA,
      fresh.targetCommitSHA == plan.targetCommitSHA, fresh.files == plan.files,
      fresh.markdown == plan.markdown
    else { throw PreviewPromotionError.changed }
    let repository = try promotionRepository(
      record: plan.record, profile: plan.profile, kind: .remotePreviewBranch)
    let token = try requiredToken(token)
    let url: String
    if let existing = try await githubExistingPullRequestURL(
      repository: repository,
      sourceBranch: plan.record.branchName!, targetBranch: plan.profile.branch, token: token)
    {
      url = existing
    } else {
      try Task.checkCancellation()
      try await beforeMutation?()
      let response: GitHubPullRequestResponse = try await send(
        githubRequest(
          repository: repository, method: "POST",
          path: promotionRepositoryPath(repository) + "/pulls",
          token: token,
          body: GitHubCreatePullRequestBody(
            title: plan.record.draftTitle ?? plan.record.title,
            body: "RepoPress Studio: " + plan.files.map(\.path).joined(separator: "\n"),
            head: plan.record.branchName!, base: plan.profile.branch)
        ))
      guard let returnedURL = response.htmlURL else {
        throw RemoteRepositoryPublishError.invalidResponse
      }
      url = returnedURL
    }
    guard let number = validatedReviewNumber(from: url, provider: .github, repository: repository)
    else {
      throw RemoteRepositoryPublishError.invalidReviewURL(url)
    }
    var review = plan.record
    review.id = UUID()
    review.kind = .remoteReviewRequest
    review.title = CoreL10n.text("预览转正式发布：") + (review.draftTitle ?? review.title)
    review.summary = CoreL10n.text("正式发布请求已准备，等待审阅合并；尚未上线。")
    review.previewSourceRecordID = plan.record.id
    review.commitSHA = plan.sourceCommitSHA
    review.reviewNumber = number
    review.reviewURL = url
    review.reviewTitle = plan.record.draftTitle ?? plan.record.title
    review.changedPaths = plan.files.map(\.path)
    review.acceptedReviewHeadCommitSHA = nil
    review.acceptedReviewHeadAt = nil
    review.reviewStatus = nil
    review.createdAt = Date()
    // Return the validated receipt immediately. A subsequent read may fail;
    // that must not discard a PR that has already been created. The separate
    // merge inspection validates its repository, branches and exact head.
    return review
  }

  func promotionRepository(record: ReleaseRecord, profile: SiteProfile, kind: ReleaseRecordKind)
    throws -> RemoteRepository
  {
    guard profile.repositoryProvider == .github else {
      throw PreviewPromotionError.unavailable(CoreL10n.text("当前版本的软件内合并仅支持 GitHub。"))
    }
    let repository = try remoteRepository(from: profile)
    var recordedProfile = profile
    recordedProfile.repositoryBaseURL = record.repositoryBaseURL ?? ""
    guard record.kind == kind, record.siteProfileID == profile.id,
      record.repositoryProvider == .github,
      record.repoOwner?.caseInsensitiveCompare(profile.repoOwner) == .orderedSame,
      record.repoName?.caseInsensitiveCompare(profile.repoName) == .orderedSame,
      try apiBaseURL(for: recordedProfile) == repository.apiBaseURL,
      record.targetBranch == profile.branch, !profile.branch.isEmpty,
      let source = record.branchName, !source.isEmpty, source != profile.branch,
      kind == .remotePreviewBranch || record.commitSHA?.isEmpty == false, record.batchItems.isEmpty,
      let markdownPath = record.markdownPath,
      LocalContentImportService(isContentIndexEnabled: false).isImportableArticleRepositoryPath(
        markdownPath, profile: profile),
      !profile.isPrivateContentPath(markdownPath),
      !StructuralArticlePathPolicy.isProtected(markdownPath, profile: profile)
    else {
      throw PreviewPromotionError.unavailable(CoreL10n.text("此记录与当前站点不匹配，或不属于可单篇发布的公开文章。"))
    }
    return repository
  }

  func promotionRepositoryPath(_ repository: RemoteRepository) -> String {
    "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))"
  }

  func validatedPromotionFiles(
    _ changes: [PreviewPromotionChange], record: ReleaseRecord, profile: SiteProfile
  ) throws -> [PreviewPromotionFile] {
    let allowed = Set(record.changedPaths + [record.markdownPath ?? ""])
    let attachments = Set([
      "png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "svg", "pdf", "mp3", "m4a", "wav", "mp4",
      "mov", "webm",
    ])
    var seen = Set<String>()
    return try changes.map { change in
      let path = change.filename
      let parts = path.split(separator: "/", omittingEmptySubsequences: false)
      guard allowed.contains(path), !path.hasPrefix("/"), !path.contains("\\"),
        !parts.contains(where: {
          $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git"
        }),
        seen.insert(path).inserted,
        !profile.isPrivateContentPath(path),
        !StructuralArticlePathPolicy.isProtected(path, profile: profile),
        ["added", "modified"].contains(change.status), change.previousFilename == nil,
        !change.sha.isEmpty,
        path == record.markdownPath
          || attachments.contains((path as NSString).pathExtension.lowercased())
      else {
        throw PreviewPromotionError.unavailable(
          CoreL10n.text("分支包含本篇清单之外的内容、删除或结构文件；已阻止整支合并，请改用发布当前文章。"))
      }
      return PreviewPromotionFile(
        path: path, status: change.status, blobSHA: change.sha,
        additions: change.additions, deletions: change.deletions, patch: change.patch)
    }.sorted { $0.path < $1.path }
  }

  func promotionMarkdown(
    record: ReleaseRecord, files: [PreviewPromotionFile], source: String,
    repository: RemoteRepository, token: String
  ) async throws -> String {
    guard let path = record.markdownPath else { throw RemoteRepositoryPublishError.invalidResponse }
    // Read the immutable source SHA, never the moving preview branch.
    let remote = try await githubFileState(
      repository: repository, path: path, ref: source, token: token)
    guard remote.exists, let data = remote.content, data.count <= 2 * 1024 * 1024,
      let markdown = String(data: data, encoding: .utf8),
      files.first(where: { $0.path == path }).map({ $0.blobSHA == remote.sha }) ?? true
    else { throw RemoteRepositoryPublishError.invalidResponse }
    try PreviewPromotionFrontMatterPolicy.validatePublicDocument(markdown)
    return markdown
  }
}

struct PreviewPromotionComparison: Decodable { let files: [PreviewPromotionChange]? }
struct PreviewPromotionChange: Decodable {
  let filename: String
  let status: String
  let sha: String
  let additions: Int
  let deletions: Int
  let patch: String?
  let previousFilename: String?
  enum CodingKeys: String, CodingKey {
    case filename, status, sha, additions, deletions, patch
    case previousFilename = "previous_filename"
  }
}
