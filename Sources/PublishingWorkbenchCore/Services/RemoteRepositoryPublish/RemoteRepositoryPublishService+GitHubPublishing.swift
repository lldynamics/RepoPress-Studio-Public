import Foundation

// MARK: - GitHub publishing
extension RemoteRepositoryPublishService {
  func publishToGitHub(
    package: PublishPackage,
    repository: RemoteRepository,
    mode: RemoteRepositoryPublishMode,
    token: String,
    onProgress: (@Sendable (RemoteRepositoryPublishProgress) -> Void)? = nil
  ) async throws -> RemoteRepositoryPublishResult {
    if package.files.count > 1 {
      return try await publishMultipleFilesToGitHub(
        package: package,
        repository: repository,
        mode: mode,
        token: token,
        onProgress: onProgress
      )
    }

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
    var didCreateReviewBranch = false

    onProgress?(
      .init(
        stage: .validatingTarget,
        progress: 0.12,
        message: CoreL10n.text("检查目标分支"),
        detail: targetBranch
      )
    )

    if usesDedicatedBranch {
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
      let targetSHA = try await githubBranchSHA(repository: repository, branch: targetBranch, token: token)
      didCreateReviewBranch = try await githubCreateBranchIfNeeded(
        repository: repository,
        branch: branchName,
        sha: targetSHA,
        token: token
      )
    }

    var changedPaths: [String] = []
    var remoteVersionsByPath: [String: String] = [:]
    var reviewPendingPaths: [String] = []
    var lastCommitSHA: String?
    var reviewURL: String?
    let totalFiles = max(1, package.files.count)
    let fileByteSizes = uploadByteSizes(for: package)
    let totalSourceByteCount = totalUploadByteCount(for: package)
    var completedUploadByteCount: Int64 = 0
    do {
      for (index, file) in package.files.enumerated() {
        onProgress?(
          .init(
            stage: .uploadingFiles,
            progress: uploadProgressValue(
              completedByteCount: completedUploadByteCount,
              totalByteCount: totalSourceByteCount,
              stageStart: 0.2,
              stageEnd: 0.9,
              fallback: 0.2 + 0.7 * (Double(index) / Double(totalFiles))
            ),
            message: uploadProgressMessage(for: file, fallback: CoreL10n.text("提交文件")),
            detail: CoreL10n.format("第 %@/%@ 个文件", String(index + 1), String(package.files.count)),
            filePath: file.repositoryPath,
            completedByteCount: completedUploadByteCount,
            totalByteCount: totalSourceByteCount
          )
        )
        let existingSHA = try await githubContentSHA(
          repository: repository,
          path: file.repositoryPath,
          branch: branchName,
          token: token
        )
        let content = file.operation == .upsert ? try contentData(for: file) : nil
        let isAlreadyPublished =
          mode == .directCommit
          && file.operation == .upsert
          && content.flatMap {
            githubRemoteContentMatches(data: $0, remoteSHA: existingSHA)
          } == true
        let isVerifiedLegacyDelete =
          file.operation == .delete
          && githubLegacyDeleteContentMatches(file: file, remoteSHA: existingSHA)
        let validatesExpectedVersion = mode == .directCommit
        if validatesExpectedVersion {
          let isIdempotentMissingDelete = file.operation == .delete && existingSHA == nil
          if !isAlreadyPublished && !isVerifiedLegacyDelete && !isIdempotentMissingDelete {
            try validateExpectedRemoteVersion(
              path: file.repositoryPath,
              expected: file.expectedRemoteSHA,
              actual: existingSHA
            )
          }
        }

        if file.operation == .delete {
          if createsReview, existingSHA != nil {
            reviewPendingPaths.append(file.repositoryPath)
          }
          if let existingSHA {
            let response: GitHubContentMutationResponse = try await send(
              githubRequest(
                repository: repository,
                method: "DELETE",
                path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/contents/\(encodedRepositoryPath(file.repositoryPath))",
                token: token,
                queryItems: nil,
                body: GitHubDeleteContentsBody(
                  message: package.commitMessage,
                  branch: branchName,
                  sha: existingSHA
                )
              )
            )
            changedPaths.append(file.repositoryPath)
            lastCommitSHA = response.commit.sha
          }
        } else if isAlreadyPublished {
          if let existingSHA {
            remoteVersionsByPath[file.repositoryPath.normalizedRelativePath()] = existingSHA
          }
        } else {
          let data = try unwrapContentData(content, for: file)
          let response: GitHubContentMutationResponse = try await send(
            githubRequest(
              repository: repository,
              method: "PUT",
              path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/contents/\(encodedRepositoryPath(file.repositoryPath))",
              token: token,
              queryItems: nil,
              body: GitHubPutContentsBody(
                message: package.commitMessage,
                content: data.base64EncodedString(),
                branch: branchName,
                sha: existingSHA
              )
            )
          )
          changedPaths.append(file.repositoryPath)
          lastCommitSHA = response.commit.sha
          if let contentSHA = response.content?.sha?.trimmedForPublishing.nilIfEmpty {
            remoteVersionsByPath[file.repositoryPath.normalizedRelativePath()] = contentSHA
          }
        }

        completedUploadByteCount += fileByteSizes[index]
        onProgress?(
          .init(
            stage: .uploadingFiles,
            progress: uploadProgressValue(
              completedByteCount: completedUploadByteCount,
              totalByteCount: totalSourceByteCount,
              stageStart: 0.2,
              stageEnd: 0.9,
              fallback: 0.2 + 0.7 * (Double(index + 1) / Double(totalFiles))
            ),
            message: uploadProgressMessage(for: file, fallback: CoreL10n.text("提交文件")),
            detail: CoreL10n.format("已处理第 %@/%@ 个文件", String(index + 1), String(package.files.count)),
            filePath: file.repositoryPath,
            completedByteCount: completedUploadByteCount,
            totalByteCount: totalSourceByteCount
          )
        )
      }

      if createsReview && changedPaths.isEmpty {
        if didCreateReviewBranch {
          try await githubDeleteBranch(repository: repository, branch: branchName, token: token)
        } else {
          reviewURL = try await githubExistingPullRequestURL(
            repository: repository,
            sourceBranch: branchName,
            targetBranch: targetBranch,
            token: token
          )
        }
        return RemoteRepositoryPublishResult(
          provider: .github,
          repositoryName: repository.displayName,
          apiBaseURL: normalizedAPIBaseURLString(repository.apiBaseURL),
          mode: mode,
          branchName: branchName,
          targetBranch: targetBranch,
          changedPaths: [],
          commitSHA: nil,
          remoteVersionsByPath: remoteVersionsByPath.isEmpty ? nil : remoteVersionsByPath,
          reviewPendingPaths: reviewPendingPaths,
          reviewURL: reviewURL,
          reviewTitle: reviewDraft.title
        )
      }

      if createsReview {
        onProgress?(
          .init(
            stage: .creatingReview,
            progress: 0.92,
            message: CoreL10n.text("创建/获取 PR"),
            detail: branchName,
            completedByteCount: totalSourceByteCount,
            totalByteCount: totalSourceByteCount
          )
        )
        if !didCreateReviewBranch,
           let existingReviewURL = try await githubExistingPullRequestURL(
             repository: repository,
             sourceBranch: branchName,
             targetBranch: targetBranch,
             token: token
           ) {
          reviewURL = existingReviewURL
        } else {
          let pull: GitHubPullRequestResponse = try await send(
            githubRequest(
              repository: repository,
              method: "POST",
              path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/pulls",
              token: token,
              body: GitHubCreatePullRequestBody(
                title: reviewDraft.title,
                body: reviewDraft.body,
                head: branchName,
                base: targetBranch
              )
            )
          )
          reviewURL = pull.htmlURL
        }
      }
    } catch let error as RemoteRepositoryPublishError {
      if didCreateReviewBranch && changedPaths.isEmpty {
        do {
          try await githubDeleteBranch(repository: repository, branch: branchName, token: token)
        } catch let cleanupError {
          throw RemoteRepositoryPublishError.reviewBranchCleanupFailed(
            branchName: branchName,
            publishMessage: error.localizedDescription,
            cleanupMessage: cleanupError.localizedDescription
          )
        }
      }
      guard !changedPaths.isEmpty else {
        throw error
      }
      throw RemoteRepositoryPublishError.partialPublish(
        provider: .github,
        mode: mode,
        branchName: branchName,
        targetBranch: targetBranch,
        changedPaths: changedPaths,
        commitSHA: lastCommitSHA,
        underlyingMessage: reviewCreationFailureDescription(error, provider: .github)
      )
    } catch {
      if didCreateReviewBranch && changedPaths.isEmpty {
        do {
          try await githubDeleteBranch(repository: repository, branch: branchName, token: token)
        } catch let cleanupError {
          throw RemoteRepositoryPublishError.reviewBranchCleanupFailed(
            branchName: branchName,
            publishMessage: error.localizedDescription,
            cleanupMessage: cleanupError.localizedDescription
          )
        }
      }
      guard !changedPaths.isEmpty else {
        throw error
      }
      throw RemoteRepositoryPublishError.partialPublish(
        provider: .github,
        mode: mode,
        branchName: branchName,
        targetBranch: targetBranch,
        changedPaths: changedPaths,
        commitSHA: lastCommitSHA,
        underlyingMessage: reviewCreationFailureDescription(error, provider: .github)
      )
    }

    onProgress?(
      .init(
        stage: .completed,
        progress: 1,
        message: mode.completedProgressMessage,
        detail: CoreL10n.format("共提交 %@ 个文件", String(changedPaths.count)),
        completedByteCount: totalSourceByteCount,
        totalByteCount: totalSourceByteCount
      )
    )

    return RemoteRepositoryPublishResult(
      provider: .github,
      repositoryName: repository.displayName,
      apiBaseURL: normalizedAPIBaseURLString(repository.apiBaseURL),
      mode: mode,
      branchName: branchName,
      targetBranch: targetBranch,
      changedPaths: changedPaths,
      commitSHA: lastCommitSHA,
      remoteVersionsByPath: remoteVersionsByPath.isEmpty ? nil : remoteVersionsByPath,
      reviewPendingPaths: createsReview ? reviewPendingPaths : nil,
      reviewURL: reviewURL,
      reviewTitle: createsReview ? reviewDraft.title : nil
    )
  }

  private func publishMultipleFilesToGitHub(
    package: PublishPackage,
    repository: RemoteRepository,
    mode: RemoteRepositoryPublishMode,
    token: String,
    onProgress: (@Sendable (RemoteRepositoryPublishProgress) -> Void)?
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
    var didCreateReviewBranch = false
    var didUpdateReference = false
    var changedPaths: [String] = []
    var remoteVersionsByPath: [String: String] = [:]
    var reviewPendingPaths: [String] = []
    var commitSHA: String?
    var reviewURL: String?
    let totalSourceByteCount = totalUploadByteCount(for: package)

    onProgress?(
      .init(
        stage: .validatingTarget,
        progress: 0.12,
        message: CoreL10n.text("检查目标分支"),
        detail: targetBranch
      )
    )

    let baseCommitSHA: String
    if usesDedicatedBranch {
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
      let targetSHA = try await githubBranchSHA(repository: repository, branch: targetBranch, token: token)
      didCreateReviewBranch = try await githubCreateBranchIfNeeded(
        repository: repository,
        branch: branchName,
        sha: targetSHA,
        token: token
      )
      baseCommitSHA = didCreateReviewBranch
        ? targetSHA
        : try await githubBranchSHA(repository: repository, branch: branchName, token: token)
    } else {
      baseCommitSHA = try await githubBranchSHA(
        repository: repository,
        branch: branchName,
        token: token
      )
    }

    do {
      let baseCommit = try await githubCommit(repository: repository, sha: baseCommitSHA, token: token)
      var treeEntries: [GitHubTreeEntry] = []
      let totalFiles = max(1, package.files.count)
      let fileByteSizes = uploadByteSizes(for: package)
      var completedUploadByteCount: Int64 = 0

      for (index, file) in package.files.enumerated() {
        onProgress?(
          .init(
            stage: .uploadingFiles,
            progress: uploadProgressValue(
              completedByteCount: completedUploadByteCount,
              totalByteCount: totalSourceByteCount,
              stageStart: 0.2,
              stageEnd: 0.75,
              fallback: 0.2 + 0.55 * (Double(index) / Double(totalFiles))
            ),
            message: uploadProgressMessage(for: file, fallback: CoreL10n.text("构建原子提交")),
            detail: CoreL10n.format("第 %@/%@ 个文件", String(index + 1), String(package.files.count)),
            filePath: file.repositoryPath,
            completedByteCount: completedUploadByteCount,
            totalByteCount: totalSourceByteCount
          )
        )
        let existingSHA = try await githubContentSHA(
          repository: repository,
          path: file.repositoryPath,
          branch: branchName,
          token: token
        )
        let content = file.operation == .upsert ? try contentData(for: file) : nil
        let isAlreadyPublished =
          file.operation == .upsert
          && content.flatMap {
            githubRemoteContentMatches(data: $0, remoteSHA: existingSHA)
          } == true
        let isVerifiedLegacyDelete =
          file.operation == .delete
          && githubLegacyDeleteContentMatches(file: file, remoteSHA: existingSHA)
        let validatesExpectedVersion = mode == .directCommit
        if validatesExpectedVersion {
          let isIdempotentMissingDelete = file.operation == .delete && existingSHA == nil
          if !isAlreadyPublished && !isVerifiedLegacyDelete && !isIdempotentMissingDelete {
            try validateExpectedRemoteVersion(
              path: file.repositoryPath,
              expected: file.expectedRemoteSHA,
              actual: existingSHA
            )
          }
        }

        if file.operation == .delete {
          if createsReview, existingSHA != nil {
            reviewPendingPaths.append(file.repositoryPath)
          }
          if existingSHA != nil {
            treeEntries.append(GitHubTreeEntry(path: file.repositoryPath, sha: nil))
            changedPaths.append(file.repositoryPath)
          }
        } else if isAlreadyPublished {
          if let existingSHA {
            remoteVersionsByPath[file.repositoryPath.normalizedRelativePath()] = existingSHA
          }
        } else {
          let content = try unwrapContentData(content, for: file)
          let blob: GitHubBlobResponse = try await send(
            githubRequest(
              repository: repository,
              method: "POST",
              path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/blobs",
              token: token,
              body: GitHubCreateBlobBody(
                content: content.base64EncodedString(),
                encoding: "base64"
              )
            )
          )
          if existingSHA != blob.sha {
            treeEntries.append(GitHubTreeEntry(path: file.repositoryPath, sha: blob.sha))
            changedPaths.append(file.repositoryPath)
            remoteVersionsByPath[file.repositoryPath.normalizedRelativePath()] = blob.sha
          } else {
            remoteVersionsByPath[file.repositoryPath.normalizedRelativePath()] = existingSHA ?? blob.sha
          }
        }

        completedUploadByteCount += fileByteSizes[index]
        onProgress?(
          .init(
            stage: .uploadingFiles,
            progress: uploadProgressValue(
              completedByteCount: completedUploadByteCount,
              totalByteCount: totalSourceByteCount,
              stageStart: 0.2,
              stageEnd: 0.75,
              fallback: 0.2 + 0.55 * (Double(index + 1) / Double(totalFiles))
            ),
            message: uploadProgressMessage(for: file, fallback: CoreL10n.text("构建原子提交")),
            detail: CoreL10n.format("已处理第 %@/%@ 个文件", String(index + 1), String(package.files.count)),
            filePath: file.repositoryPath,
            completedByteCount: completedUploadByteCount,
            totalByteCount: totalSourceByteCount
          )
        )
      }

      guard !treeEntries.isEmpty else {
        let existingReviewURL: String?
        if didCreateReviewBranch {
          try await githubDeleteBranch(repository: repository, branch: branchName, token: token)
          existingReviewURL = nil
        } else if createsReview {
          existingReviewURL = try await githubExistingPullRequestURL(
            repository: repository,
            sourceBranch: branchName,
            targetBranch: targetBranch,
            token: token
          )
        } else {
          existingReviewURL = nil
        }
        return RemoteRepositoryPublishResult(
          provider: .github,
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
          progress: 0.78,
          message: CoreL10n.text("提交原子变更"),
          detail: CoreL10n.format("一次提交 %@ 个文件", String(treeEntries.count)),
          completedByteCount: totalSourceByteCount,
          totalByteCount: totalSourceByteCount
        )
      )
      let tree: GitHubTreeResponse = try await send(
        githubRequest(
          repository: repository,
          method: "POST",
          path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/trees",
          token: token,
          body: GitHubCreateTreeBody(baseTree: baseCommit.tree.sha, tree: treeEntries)
        )
      )
      let commit: GitHubCommitResponse = try await send(
        githubRequest(
          repository: repository,
          method: "POST",
          path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/commits",
          token: token,
          body: GitHubCreateCommitBody(
            message: package.commitMessage,
            tree: tree.sha,
            parents: [baseCommitSHA]
          )
        )
      )
      let _: GitHubReferenceResponse = try await send(
        githubRequest(
          repository: repository,
          method: "PATCH",
          path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/refs/heads/\(encodedRepositoryPath(branchName))",
          token: token,
          body: GitHubUpdateReferenceBody(sha: commit.sha, force: false)
        )
      )
      didUpdateReference = true
      commitSHA = commit.sha

      if createsReview {
        onProgress?(
          .init(
            stage: .creatingReview,
            progress: 0.92,
            message: CoreL10n.text("创建/获取 PR"),
            detail: branchName,
            completedByteCount: totalSourceByteCount,
            totalByteCount: totalSourceByteCount
          )
        )
        if !didCreateReviewBranch,
           let existingReviewURL = try await githubExistingPullRequestURL(
             repository: repository,
             sourceBranch: branchName,
             targetBranch: targetBranch,
             token: token
           ) {
          reviewURL = existingReviewURL
        } else {
          let pull: GitHubPullRequestResponse = try await send(
            githubRequest(
              repository: repository,
              method: "POST",
              path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/pulls",
              token: token,
              body: GitHubCreatePullRequestBody(
                title: reviewDraft.title,
                body: reviewDraft.body,
                head: branchName,
                base: targetBranch
              )
            )
          )
          reviewURL = pull.htmlURL
        }
      }
    } catch {
      if didCreateReviewBranch && !didUpdateReference {
        do {
          try await githubDeleteBranch(repository: repository, branch: branchName, token: token)
        } catch let cleanupError {
          throw RemoteRepositoryPublishError.reviewBranchCleanupFailed(
            branchName: branchName,
            publishMessage: error.localizedDescription,
            cleanupMessage: cleanupError.localizedDescription
          )
        }
      }
      guard didUpdateReference else { throw error }
      throw RemoteRepositoryPublishError.partialPublish(
        provider: .github,
        mode: mode,
        branchName: branchName,
        targetBranch: targetBranch,
        changedPaths: changedPaths,
        commitSHA: commitSHA,
        underlyingMessage: reviewCreationFailureDescription(error, provider: .github)
      )
    }

    onProgress?(
      .init(
        stage: .completed,
        progress: 1,
        message: mode.completedProgressMessage,
        detail: CoreL10n.format("一次提交 %@ 个文件", String(changedPaths.count)),
        completedByteCount: totalSourceByteCount,
        totalByteCount: totalSourceByteCount
      )
    )
    return RemoteRepositoryPublishResult(
      provider: .github,
      repositoryName: repository.displayName,
      apiBaseURL: normalizedAPIBaseURLString(repository.apiBaseURL),
      mode: mode,
      branchName: branchName,
      targetBranch: targetBranch,
      changedPaths: changedPaths,
      commitSHA: commitSHA,
      remoteVersionsByPath: remoteVersionsByPath.isEmpty ? nil : remoteVersionsByPath,
      reviewPendingPaths: createsReview ? reviewPendingPaths : nil,
      reviewURL: reviewURL,
      reviewTitle: createsReview ? reviewDraft.title : nil
    )
  }
}
