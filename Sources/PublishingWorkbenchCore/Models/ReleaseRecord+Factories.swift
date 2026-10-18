import Foundation

extension ReleaseRecord {
  public static func localWrite(
    package: PublishPackage,
    profile: SiteProfile,
    writtenPaths: [String],
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    return ReleaseRecord(
      kind: .localWrite,
      title: "写入本地仓库：\(package.title)",
      summary: "已写入 \(writtenPaths.count) 个文件到工作树。",
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: package.draftID,
      draftTitle: package.title,
      draftSummary: package.draftSummary,
      draftCoverAltText: package.draftCoverAltText,
      publicPath: package.publicPath,
      publicURLText: package.publicURLText,
      sourceDocumentDigest: package.sourceDocumentDigest,
      markdownPath: package.markdownPath,
      changedPaths: writtenPaths,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: profile.branch,
      createdAt: createdAt
    )
  }

  public static func batchLocalWrite(
    profile: SiteProfile,
    items: [BatchPublishPlanItem],
    writtenPaths: [String],
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    return ReleaseRecord(
      kind: .batchLocalWrite,
      title: "批量写入本地仓库：\(profile.name)",
      summary: "已写入 \(items.count) 篇文章、\(writtenPaths.count) 个文件到工作树。",
      siteProfileID: profile.id,
      siteName: profile.name,
      changedPaths: writtenPaths,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: profile.branch,
      batchItems: items.map { ReleaseRecordBatchItem(planItem: $0, changedPaths: writtenPaths) },
      createdAt: createdAt
    )
  }

  public static func remotePublish(
    package: PublishPackage,
    profile: SiteProfile,
    result: RemoteRepositoryPublishResult,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    let kind: ReleaseRecordKind =
      switch result.mode {
      case .directCommit: .remoteDirectCommit
      case .reviewRequest: .remoteReviewRequest
      case .previewBranch: .remotePreviewBranch
      }
    let recordDisplayName = kind.displayName
    return ReleaseRecord(
      kind: kind,
      title: "\(recordDisplayName)：\(package.title)",
      summary:
        "\(result.provider.displayName) · \(result.branchName) · \(result.changedPaths.count) 个文件"
        + (result.commitSHA.map { " · \(String($0.prefix(8)))" } ?? ""),
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: package.draftID,
      draftTitle: package.title,
      draftSummary: package.draftSummary,
      draftCoverAltText: package.draftCoverAltText,
      publicPath: package.publicPath,
      publicURLText: package.publicURLText,
      sourceDocumentDigest: package.sourceDocumentDigest,
      markdownPath: package.markdownPath,
      changedPaths: result.changedPaths,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: result.branchName,
      targetBranch: result.targetBranch,
      commitSHA: result.commitSHA,
      reviewNumber: result.reviewNumber,
      reviewURL: result.reviewURL,
      reviewTitle: result.reviewTitle,
      createdAt: createdAt
    )
  }

  public static func batchRemotePublish(
    profile: SiteProfile,
    items: [BatchPublishPlanItem],
    cleanupCount: Int = 0,
    result: RemoteRepositoryPublishResult,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    let kind: ReleaseRecordKind =
      switch result.mode {
      case .directCommit: .remoteDirectCommit
      case .reviewRequest: .remoteReviewRequest
      case .previewBranch: .remotePreviewBranch
      }
    let recordDisplayName = kind.displayName
    let operationSummary: String
    if cleanupCount == 0 {
      operationSummary = "\(items.count) 篇文章"
    } else if items.isEmpty {
      operationSummary = "下线 \(cleanupCount) 篇"
    } else {
      operationSummary = "发布 \(items.count) 篇 · 下线 \(cleanupCount) 篇"
    }
    return ReleaseRecord(
      kind: kind,
      title: "批量\(recordDisplayName)：\(profile.name)",
      summary:
        "\(result.provider.displayName) · \(operationSummary) · \(result.changedPaths.count) 个文件"
        + (result.commitSHA.map { " · \(String($0.prefix(8)))" } ?? ""),
      siteProfileID: profile.id,
      siteName: profile.name,
      changedPaths: result.changedPaths,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: result.branchName,
      targetBranch: result.targetBranch,
      commitSHA: result.commitSHA,
      reviewNumber: result.reviewNumber,
      reviewURL: result.reviewURL,
      reviewTitle: result.reviewTitle,
      batchItems: items.map {
        ReleaseRecordBatchItem(planItem: $0, changedPaths: result.changedPaths)
      },
      createdAt: createdAt
    )
  }

  public static func remotePublishFailure(
    package: PublishPackage,
    profile: SiteProfile,
    mode: RemoteRepositoryPublishMode,
    errorMessage: String,
    changedPaths: [String]? = nil,
    commitSHA: String? = nil,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    let branchName: String =
      switch mode {
      case .directCommit:
        profile.branch.nilIfEmpty ?? "main"
      case .reviewRequest:
        package.reviewBranchName
      case .previewBranch:
        package.draftPreviewBranchName
      }
    return ReleaseRecord(
      kind: .remotePublishFailure,
      title: "\(mode.displayName)失败：\(package.title)",
      summary: errorMessage,
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: package.draftID,
      draftTitle: package.title,
      draftSummary: package.draftSummary,
      draftCoverAltText: package.draftCoverAltText,
      publicPath: package.publicPath,
      publicURLText: package.publicURLText,
      sourceDocumentDigest: package.sourceDocumentDigest,
      markdownPath: package.markdownPath,
      changedPaths: changedPaths ?? package.files.map(\.repositoryPath),
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: branchName,
      targetBranch: profile.branch.nilIfEmpty ?? "main",
      commitSHA: commitSHA,
      createdAt: createdAt
    )
  }

  public static func batchRemotePublishFailure(
    package: PublishPackage,
    profile: SiteProfile,
    items: [BatchPublishPlanItem],
    cleanupCount: Int = 0,
    mode: RemoteRepositoryPublishMode,
    errorMessage: String,
    changedPaths: [String]? = nil,
    commitSHA: String? = nil,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    let branchName: String =
      switch mode {
      case .directCommit:
        profile.branch.nilIfEmpty ?? "main"
      case .reviewRequest:
        package.reviewBranchName
      case .previewBranch:
        package.draftPreviewBranchName
      }
    let operationSummary: String
    if cleanupCount == 0 {
      operationSummary = "\(items.count) 篇文章未完成线上发布"
    } else if items.isEmpty {
      operationSummary = "\(cleanupCount) 篇文章下线未完成"
    } else {
      operationSummary = "发布 \(items.count) 篇、下线 \(cleanupCount) 篇未完成"
    }
    return ReleaseRecord(
      kind: .remotePublishFailure,
      title: "批量\(mode.displayName)失败：\(profile.name)",
      summary: "\(operationSummary)：\(errorMessage)",
      siteProfileID: profile.id,
      siteName: profile.name,
      changedPaths: changedPaths ?? package.files.map(\.repositoryPath),
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: branchName,
      targetBranch: profile.branch.nilIfEmpty ?? "main",
      commitSHA: commitSHA,
      batchItems: items.map {
        ReleaseRecordBatchItem(
          planItem: $0, changedPaths: changedPaths ?? package.files.map(\.repositoryPath))
      },
      createdAt: createdAt
    )
  }

  public static func resumedRemoteReview(
    original: ReleaseRecord,
    profile: SiteProfile,
    result: RemoteRepositoryPublishResult
  ) -> ReleaseRecord {
    var recovered = original
    recovered.kind = .remoteReviewRequest
    recovered.title = "恢复线上 PR/MR：\(original.siteName ?? profile.name)"
    recovered.summary = "已从部分完成的远端分支继续创建 PR/MR：\(result.branchName) -> \(result.targetBranch)"
    recovered.repositoryProvider = result.provider
    recovered.repositoryBaseURL = profile.repositoryBaseURL
    recovered.repoOwner = profile.repoOwner
    recovered.repoName = profile.repoName
    recovered.branchName = result.branchName
    recovered.targetBranch = result.targetBranch
    recovered.commitSHA = result.commitSHA ?? original.commitSHA
    recovered.acceptedReviewHeadCommitSHA = nil
    recovered.acceptedReviewHeadAt = nil
    recovered.reviewNumber = result.reviewNumber
    recovered.reviewURL = result.reviewURL
    recovered.reviewTitle = result.reviewTitle
    recovered.reviewStatus = nil
    return recovered
  }

  public static func remoteRollback(
    original: ReleaseRecord,
    profile: SiteProfile,
    result: RemoteRepositoryRollbackResult,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    ReleaseRecord(
      kind: .remoteRollback,
      title: CoreL10n.format("线上回滚：%@", original.draftTitle ?? original.title),
      summary: CoreL10n.format(
        "%@ · %@ · 回滚 %@ -> %@", result.provider.displayName, result.targetBranch,
        String(result.rolledBackCommitSHA.prefix(8)), String(result.rollbackCommitSHA.prefix(8))),
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: original.draftID,
      draftTitle: original.draftTitle,
      draftSummary: original.draftSummary,
      draftCoverAltText: original.draftCoverAltText,
      publicPath: original.publicPath,
      publicURLText: original.publicURLText,
      sourceDocumentDigest: original.sourceDocumentDigest,
      markdownPath: original.markdownPath,
      changedPaths: result.changedPaths,
      repositoryProvider: result.provider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: result.targetBranch,
      targetBranch: result.targetBranch,
      commitSHA: result.rollbackCommitSHA,
      reviewURL: result.remoteURL,
      reviewTitle: CoreL10n.format("回滚 %@", original.draftTitle ?? original.title),
      batchItems: original.batchItems,
      createdAt: createdAt
    )
  }

  public static func remoteReviewWithdrawal(
    original: ReleaseRecord,
    profile: SiteProfile,
    result: RemoteRepositoryReviewWithdrawalResult,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    ReleaseRecord(
      kind: .remoteReviewWithdrawal,
      title: CoreL10n.format("线上 Review 撤回：%@", original.draftTitle ?? original.title),
      summary: "\(result.provider.displayName) · #\(result.reviewNumber) · \(result.state)",
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: original.draftID,
      draftTitle: original.draftTitle,
      draftSummary: original.draftSummary,
      draftCoverAltText: original.draftCoverAltText,
      publicPath: original.publicPath,
      publicURLText: original.publicURLText,
      sourceDocumentDigest: original.sourceDocumentDigest,
      markdownPath: original.markdownPath,
      changedPaths: original.changedPaths,
      repositoryProvider: result.provider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: result.branchName,
      targetBranch: result.targetBranch,
      commitSHA: original.commitSHA,
      reviewURL: result.reviewURL,
      reviewTitle: CoreL10n.format(
        "已关闭 %@", original.reviewTitle ?? original.draftTitle ?? original.title),
      batchItems: original.batchItems,
      createdAt: createdAt
    )
  }

}
