import Foundation

enum PublishExecutionVerification: Sendable {
  case accepted(RemoteRepositoryPublishResult)
  case unchanged
  case unresolved(String)
}

extension RemoteRepositoryPublishService {
  func freezeExecutionPlan(
    package: PublishPackage, batchItems: [BatchPublishPlanItem],
    profile: SiteProfile, preview: RemoteRepositoryPublishPreview
  ) throws -> PublishExecutionPlan {
    var frozen = try normalizedPublishPackage(package)
    var sha256: [String: String] = [:]
    var blobSHA: [String: String] = [:]
    for index in frozen.files.indices where frozen.files[index].operation == .upsert {
      let data = try contentData(for: frozen.files[index])
      let path = frozen.files[index].repositoryPath
      sha256[path] = WorkbenchRecordPayload.digest(data)
      blobSHA[path] = gitBlobSHA(for: data)
      if frozen.files[index].kind != .markdown {
        frozen.files[index].reviewedSourceSHA256 = sha256[path]
      }
    }
    let frozenItems = batchItems.map { item in
      var result = item
      result.package = item.package.freezingArticleVerification(
        finalFiles: frozen.files, profile: profile)
      return result
    }
    return PublishExecutionPlan(
      package: frozen.freezingArticleVerification(finalFiles: frozen.files, profile: profile),
      batchItems: frozenItems,
      target: RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview),
      branchName: preview.branchName,
      contentSHA256ByPath: sha256, gitBlobSHAByPath: blobSHA)
  }

  /// Only GET requests. All files are compared at one immutable commit; a
  /// lost response never authorizes another write or a branch deletion.
  func verifyExecution(
    _ plan: PublishExecutionPlan, profile: SiteProfile, token: String?
  ) async throws -> PublishExecutionVerification {
    try plan.validate()
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)
    func branchHead() async throws -> String {
      switch profile.repositoryProvider {
      case .github:
        try await githubBranchSHA(repository: repository, branch: plan.branchName, token: token)
      case .gitlab:
        try await gitLabBranchSHA(repository: repository, branch: plan.branchName, token: token)
      }
    }
    let head: String
    do { head = try await branchHead() } catch RemoteRepositoryPublishError.httpStatus(404, _) {
      return .unchanged
    }
    var desiredCount = 0
    var originalCount = 0
    var versions: [String: String] = [:]
    for file in plan.package.files {
      let remoteVersion: String?
      let exists: Bool
      let desired: Bool
      switch profile.repositoryProvider {
      case .github:
        remoteVersion = try await githubContentSHA(
          repository: repository, path: file.repositoryPath, branch: head, token: token)
        exists = remoteVersion != nil
        desired =
          file.operation == .delete
          ? remoteVersion == nil
          : remoteVersion != nil && remoteVersion == plan.gitBlobSHAByPath[file.repositoryPath]
      case .gitlab:
        let remote = try await gitLabFileState(
          repository: repository, path: file.repositoryPath, ref: head, token: token)
        remoteVersion = remote.lastCommitID
        exists = remote.exists
        desired =
          file.operation == .delete
          ? !remote.exists
          : remote.content.map(WorkbenchRecordPayload.digest)
            == plan.contentSHA256ByPath[file.repositoryPath]
            && remote.exists
      }
      if desired { desiredCount += 1 }
      if (!exists && file.expectedRemoteSHA == nil)
        || (exists && file.expectedRemoteSHA != nil && remoteVersion == file.expectedRemoteSHA)
      {
        originalCount += 1
      }
      if file.operation == .upsert, let remoteVersion {
        versions[file.repositoryPath] = remoteVersion
      }
    }
    guard try await branchHead() == head else {
      return .unresolved(CoreL10n.text("核对期间远端分支发生变化，请再次核对。"))
    }
    if desiredCount == plan.package.files.count {
      var reviewURL: String?
      if plan.target.mode == .reviewRequest {
        switch profile.repositoryProvider {
        case .github:
          reviewURL = try await githubExistingPullRequestURL(
            repository: repository,
            sourceBranch: plan.branchName, targetBranch: plan.target.targetBranch, token: token,
            includeClosed: true)
        case .gitlab:
          reviewURL = try await gitLabExistingMergeRequestURL(
            repository: repository,
            sourceBranch: plan.branchName, targetBranch: plan.target.targetBranch, token: token,
            includeClosed: true)
        }
      }
      return .accepted(
        RemoteRepositoryPublishResult(
          provider: profile.repositoryProvider, repositoryName: repository.displayName,
          apiBaseURL: normalizedAPIBaseURLString(repository.apiBaseURL), mode: plan.target.mode,
          branchName: plan.branchName, targetBranch: plan.target.targetBranch,
          changedPaths: plan.package.files.map(\.repositoryPath), commitSHA: head,
          remoteVersionsByPath: versions,
          reviewNumber: reviewURL.flatMap {
            reviewNumber(from: $0, provider: profile.repositoryProvider)
          },
          reviewURL: reviewURL, reviewTitle: plan.package.reviewTitle))
    }
    if originalCount == plan.package.files.count { return .unchanged }
    return .unresolved(CoreL10n.text("远端文件与原版本或发布计划不完全一致，请在仓库中协调后再次核对。"))
  }
}
