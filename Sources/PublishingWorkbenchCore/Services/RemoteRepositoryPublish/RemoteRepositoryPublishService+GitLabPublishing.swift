import Foundation

// MARK: - GitLab publishing
extension RemoteRepositoryPublishService {
  func publishToGitLab(
    package: PublishPackage,
    repository: RemoteRepository,
    mode: RemoteRepositoryPublishMode,
    token: String,
    onProgress: (@Sendable (RemoteRepositoryPublishProgress) -> Void)? = nil
  ) async throws -> RemoteRepositoryPublishResult {
    let targetBranch = repository.branch
    let usesDedicatedBranch = mode.usesDedicatedBranch
    let createsReview = mode.createsReview
    let branchName: String = switch mode {
    case .directCommit:
      targetBranch
    case .reviewRequest:
      package.reviewBranchName
    case .previewBranch:
      package.draftPreviewBranchName
    }
    let reviewDraft = RemoteReviewDraftBuilder().build(package: package, profile: repository.profile)
    onProgress?(
      .init(
        stage: .validatingTarget,
        progress: 0.12,
        message: CoreL10n.text("检查目标分支"),
        detail: targetBranch
      )
    )
    let reviewBranchExists = usesDedicatedBranch
      ? try await {
        onProgress?(
          .init(
            stage: .creatingBranch,
            progress: 0.18,
            message: mode == .previewBranch
              ? CoreL10n.text("处理草稿预览分支")
              : CoreL10n.text("处理 PR/MR 分支"),
            detail: branchName
          )
        )
        return try await gitLabBranchExists(repository: repository, branch: branchName, token: token)
      }()
      : false
    let existenceRef = usesDedicatedBranch && reviewBranchExists ? branchName : targetBranch

    var actions: [GitLabCommitAction] = []
    var changedPaths: [String] = []
    let totalFiles = max(1, package.files.count)
    let fileByteSizes = uploadByteSizes(for: package)
    let totalSourceByteCount = totalUploadByteCount(for: package)
    var completedUploadByteCount: Int64 = 0
    var remoteVersionsByPath: [String: String] = [:]
    var reviewPendingPaths: [String] = []
    for (index, file) in package.files.enumerated() {
      onProgress?(
        .init(
          stage: .uploadingFiles,
          progress: uploadProgressValue(
            completedByteCount: completedUploadByteCount,
            totalByteCount: totalSourceByteCount,
            stageStart: 0.2,
            stageEnd: 0.85,
            fallback: 0.2 + 0.65 * (Double(index) / Double(totalFiles))
          ),
          message: uploadProgressMessage(for: file, fallback: CoreL10n.text("构建提交")),
          detail: CoreL10n.format("第 %@/%@ 个文件", String(index + 1), String(package.files.count)),
          filePath: file.repositoryPath,
          completedByteCount: completedUploadByteCount,
          totalByteCount: totalSourceByteCount
        )
      )
      let remoteState = try await gitLabFileState(
        repository: repository,
        path: file.repositoryPath,
        ref: existenceRef,
        token: token
      )
      let validationState = if createsReview
        && file.operation == .delete
        && existenceRef != targetBranch
      {
        try await gitLabFileState(
          repository: repository,
          path: file.repositoryPath,
          ref: targetBranch,
          token: token
        )
      } else {
        remoteState
      }
      let content = file.operation == .upsert ? try contentData(for: file) : nil
      let isAlreadyPublished = file.operation == .upsert
        && remoteState.exists
        && content == remoteState.content
      let isVerifiedLegacyDelete = file.operation == .delete
        && gitLabLegacyDeleteContentMatches(file: file, remoteContent: validationState.content)
      let isIdempotentMissingDelete = file.operation == .delete && !validationState.exists
      let validatesExpectedVersion = mode == .directCommit
        || (createsReview && file.operation == .delete)
      if validatesExpectedVersion
        && !isAlreadyPublished
        && !isVerifiedLegacyDelete
        && !isIdempotentMissingDelete
      {
        try validateExpectedRemoteVersion(
          path: file.repositoryPath,
          expected: file.expectedRemoteSHA,
          actual: validationState.lastCommitID
        )
      }

      if file.operation == .delete {
        if createsReview, validationState.exists {
          reviewPendingPaths.append(file.repositoryPath)
        }
        if remoteState.exists {
          actions.append(
            GitLabCommitAction(
              action: "delete",
              filePath: file.repositoryPath,
              content: nil,
              encoding: nil,
              lastCommitID: remoteState.lastCommitID
            )
          )
          changedPaths.append(file.repositoryPath)
        }
      } else if !isAlreadyPublished {
        let data = try unwrapContentData(content, for: file)
        if remoteState.content != data {
          actions.append(
            GitLabCommitAction(
              action: remoteState.exists ? "update" : "create",
              filePath: file.repositoryPath,
              content: file.kind == .markdown ? String(data: data, encoding: .utf8) ?? "" : data.base64EncodedString(),
              encoding: file.kind == .markdown ? nil : "base64",
              lastCommitID: remoteState.lastCommitID
            )
          )
          changedPaths.append(file.repositoryPath)
        }
      } else if let lastCommitID = remoteState.lastCommitID
      {
        remoteVersionsByPath[file.repositoryPath.normalizedRelativePath()] = lastCommitID
      }

      completedUploadByteCount += fileByteSizes[index]
      onProgress?(
        .init(
          stage: .uploadingFiles,
          progress: uploadProgressValue(
            completedByteCount: completedUploadByteCount,
            totalByteCount: totalSourceByteCount,
            stageStart: 0.2,
            stageEnd: 0.85,
            fallback: 0.2 + 0.65 * (Double(index + 1) / Double(totalFiles))
          ),
          message: uploadProgressMessage(for: file, fallback: CoreL10n.text("构建提交")),
          detail: CoreL10n.format("已处理第 %@/%@ 个文件", String(index + 1), String(package.files.count)),
          filePath: file.repositoryPath,
          completedByteCount: completedUploadByteCount,
          totalByteCount: totalSourceByteCount
        )
      )
    }

    guard !actions.isEmpty else {
      let existingReviewURL = createsReview && reviewBranchExists
        ? try await gitLabExistingMergeRequestURL(
          repository: repository,
          sourceBranch: branchName,
          targetBranch: targetBranch,
          token: token
        )
        : nil
      return RemoteRepositoryPublishResult(
        provider: .gitlab,
        repositoryName: repository.displayName,
        apiBaseURL: normalizedAPIBaseURLString(repository.apiBaseURL),
        mode: mode,
        branchName: branchName,
        targetBranch: targetBranch,
        changedPaths: [],
        commitSHA: nil,
        remoteVersionsByPath: remoteVersionsByPath.isEmpty ? nil : remoteVersionsByPath,
        reviewPendingPaths: createsReview ? reviewPendingPaths : nil,
        reviewURL: existingReviewURL,
        reviewTitle: createsReview ? reviewDraft.title : nil
      )
    }

    onProgress?(
      .init(
        stage: .uploadingFiles,
        progress: 0.85,
        message: CoreL10n.text("提交 Commit"),
        detail: CoreL10n.format("推送 %@ 个变更", String(actions.count)),
        completedByteCount: totalSourceByteCount,
        totalByteCount: totalSourceByteCount
      )
    )

    let commitBody = GitLabCreateCommitBody(
      branch: branchName,
      commitMessage: package.commitMessage,
      startBranch: usesDedicatedBranch && !reviewBranchExists ? targetBranch : nil,
      actions: actions
    )
    let commit: GitLabCommitResponse = try await send(
      gitLabRequest(
        repository: repository,
        method: "POST",
        path: "/projects/\(encodedPathComponent(repository.projectPath))/repository/commits",
        token: token,
        body: commitBody
      )
    )

    for file in package.files where file.operation == .upsert && changedPaths.contains(file.repositoryPath) {
      remoteVersionsByPath[file.repositoryPath.normalizedRelativePath()] = commit.id
    }
    var reviewURL: String?
    if createsReview {
      onProgress?(
        .init(
          stage: .creatingReview,
          progress: 0.92,
          message: CoreL10n.text("创建/获取 MR"),
          detail: branchName,
          completedByteCount: totalSourceByteCount,
          totalByteCount: totalSourceByteCount
        )
      )
      do {
        if let existingReviewURL = try await gitLabExistingMergeRequestURL(
          repository: repository,
          sourceBranch: branchName,
          targetBranch: targetBranch,
          token: token
        ) {
          reviewURL = existingReviewURL
        } else {
          let mergeRequest: GitLabMergeRequestResponse = try await send(
            gitLabRequest(
              repository: repository,
              method: "POST",
              path: "/projects/\(encodedPathComponent(repository.projectPath))/merge_requests",
              token: token,
              body: GitLabCreateMergeRequestBody(
                sourceBranch: branchName,
                targetBranch: targetBranch,
                title: reviewDraft.title,
                description: reviewDraft.body,
                removeSourceBranch: false
              )
            )
          )
          reviewURL = mergeRequest.webURL
        }
      } catch let error as RemoteRepositoryPublishError {
        onProgress?(
          .init(
            stage: .failed,
            progress: nil,
            message: CoreL10n.text("创建 MR 失败"),
            detail: error.localizedDescription
          )
        )
        throw RemoteRepositoryPublishError.partialPublish(
          provider: .gitlab,
          mode: mode,
          branchName: branchName,
          targetBranch: targetBranch,
          changedPaths: changedPaths,
          commitSHA: commit.id,
          underlyingMessage: reviewCreationFailureDescription(error, provider: .gitlab)
        )
      } catch {
        onProgress?(
          .init(
            stage: .failed,
            progress: nil,
            message: CoreL10n.text("创建 MR 失败"),
            detail: error.localizedDescription
          )
        )
        throw RemoteRepositoryPublishError.partialPublish(
          provider: .gitlab,
          mode: mode,
          branchName: branchName,
          targetBranch: targetBranch,
          changedPaths: changedPaths,
          commitSHA: commit.id,
          underlyingMessage: reviewCreationFailureDescription(error, provider: .gitlab)
        )
      }
    }

    onProgress?(
      .init(
        stage: .completed,
        progress: 1,
        message: CoreL10n.text("发布完成"),
        detail: CoreL10n.format("共提交 %@ 个文件", String(changedPaths.count)),
        completedByteCount: totalSourceByteCount,
        totalByteCount: totalSourceByteCount
      )
    )

    return RemoteRepositoryPublishResult(
      provider: .gitlab,
      repositoryName: repository.displayName,
      apiBaseURL: normalizedAPIBaseURLString(repository.apiBaseURL),
      mode: mode,
      branchName: branchName,
      targetBranch: targetBranch,
      changedPaths: changedPaths,
      commitSHA: commit.id,
      remoteVersionsByPath: remoteVersionsByPath.isEmpty ? nil : remoteVersionsByPath,
      reviewPendingPaths: createsReview ? reviewPendingPaths : nil,
      reviewURL: reviewURL,
      reviewTitle: createsReview ? reviewDraft.title : nil
    )
  }
}
