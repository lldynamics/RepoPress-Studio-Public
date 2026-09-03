import CryptoKit
import Foundation

extension RemoteRepositoryPublishService {
  /// Reads exactly the files in one package from the configured target branch.
  /// This shares the normal service's validated endpoint construction and HTTP
  /// transport, and performs no repository mutation.
  public func reviewRemoteArticlePublication(
    package: PublishPackage,
    profile: SiteProfile,
    mode: RemoteRepositoryPublishMode,
    token: String?
  ) async throws -> RemoteArticlePublicationReview {
    try StructuralArticlePathPolicy.validate(package: package, profile: profile)
    let normalizedPackage = try normalizedPublishPackage(package)
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)
    let targetBranchVersion: String
    switch profile.repositoryProvider {
    case .github:
      targetBranchVersion = try await githubBranchSHA(
        repository: repository, branch: repository.branch, token: token)
    case .gitlab:
      targetBranchVersion = try await gitLabBranchSHA(
        repository: repository, branch: repository.branch, token: token)
    }

    let inspection = try await preflightInspection(
      package: normalizedPackage,
      profile: profile,
      token: token,
      ref: targetBranchVersion
    )
    let currentTargetBranchVersion: String
    switch profile.repositoryProvider {
    case .github:
      currentTargetBranchVersion = try await githubBranchSHA(
        repository: repository, branch: repository.branch, token: token)
    case .gitlab:
      currentTargetBranchVersion = try await gitLabBranchSHA(
        repository: repository, branch: repository.branch, token: token)
    }
    guard currentTargetBranchVersion == targetBranchVersion else {
      throw RemoteArticlePublicationReviewError.remoteChanged
    }
    let branchName: String
    switch mode {
    case .directCommit:
      branchName = repository.branch
    case .reviewRequest:
      branchName = normalizedPackage.reviewBranchName
    case .previewBranch:
      branchName = normalizedPackage.draftPreviewBranchName
    }
    let preview = RemoteRepositoryPublishPreview(
      provider: profile.repositoryProvider,
      repositoryName: profile.repositoryDisplayName,
      mode: mode,
      branchName: branchName,
      targetBranch: repository.branch,
      changedPaths: normalizedPackage.files.map(\.repositoryPath),
      hasToken: true,
      blockingIssues: [],
      warningIssues: []
    )
    let target = RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview)
    let files = try normalizedPackage.files.map { file in
      let snapshot = inspection.snapshotsByPath[file.repositoryPath]
      let remoteData = snapshot?.content
      let localData = file.operation == .upsert ? try contentData(for: file) : nil
      let status: PublishFileDiffStatus
      switch file.operation {
      case .delete:
        status = snapshot?.exists == true ? .deleted : .unchanged
      case .upsert:
        if snapshot?.exists != true {
          status = .added
        } else if remoteData == localData {
          status = .unchanged
        } else {
          status = .modified
        }
      }
      let lineDiff: String?
      if file.kind == .markdown, status != .unchanged {
        let remoteText = remoteData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let localText = file.operation == .upsert ? (file.content ?? "") : ""
        lineDiff = LocalPublishPreviewService().unifiedDiff(old: remoteText, new: localText)
      } else {
        lineDiff = nil
      }
      return RemoteArticlePublicationReview.File(
        path: file.repositoryPath,
        kind: file.kind,
        operation: file.operation,
        status: status,
        byteSize: file.byteSize,
        contentSHA256: localData.map {
          SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        },
        remoteVersion: snapshot?.version,
        lineDiff: lineDiff
      )
    }
    return RemoteArticlePublicationReview(
      package: normalizedPackage,
      target: target,
      targetBranchVersion: targetBranchVersion,
      files: files
    )
  }

  public func contentSHA256(for file: PublishPackageFile) throws -> String? {
    guard file.operation == .upsert else { return nil }
    return SHA256.hash(data: try contentData(for: file))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
