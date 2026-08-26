import Foundation

extension RemoteRepositoryPublishService {
  func checkGitHubAccess(
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryAccessCheck {
    let response = try await data(
      for: githubRequest(
          repository: repository,
          method: "GET",
          path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))",
          token: token
        )
    )
    try validate(response)
    let metadata = try decoder.decode(GitHubRepositoryMetadata.self, from: response.data)
    let canWrite = metadata.permissions?.push == true
      || metadata.permissions?.maintain == true
      || metadata.permissions?.admin == true
    let permissionSummary = githubPermissionSummary(metadata.permissions)
    let scopeSummary = githubScopeSummary(from: response)
    return RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: metadata.fullName ?? repository.displayName,
      apiBaseURL: normalizedAPIBaseURLString(repository.apiBaseURL),
      defaultBranch: metadata.defaultBranch,
      canRead: true,
      canWrite: canWrite,
      permissionSummary: permissionSummary,
      tokenScopeSummary: scopeSummary,
      minimumWritePermission: CoreL10n.text("GitHub 写入内容需要 Contents: Read and write；使用 PR 发布时还需要 Pull requests: Read and write。"),
      message: CoreL10n.text(canWrite ? "GitHub Token 已确认内容写入能力；PR 创建权限需在实际创建时验证。" : "GitHub Token 可读取仓库，但未确认内容写入能力。")
    )
  }

  func checkGitLabAccess(
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryAccessCheck {
    let metadata: GitLabProjectMetadata = try await send(
      gitLabRequest(
        repository: repository,
        method: "GET",
        path: "/projects/\(encodedPathComponent(repository.projectPath))",
        token: token
      )
    )
    let accessLevel = max(
      metadata.permissions?.projectAccess?.accessLevel ?? 0,
      metadata.permissions?.groupAccess?.accessLevel ?? 0
    )
    let canWrite = accessLevel >= 30
    return RemoteRepositoryAccessCheck(
      provider: .gitlab,
      repositoryName: metadata.pathWithNamespace ?? repository.displayName,
      apiBaseURL: normalizedAPIBaseURLString(repository.apiBaseURL),
      defaultBranch: metadata.defaultBranch,
      canRead: true,
      canWrite: canWrite,
      permissionSummary: gitLabPermissionSummary(metadata.permissions),
      tokenScopeSummary: nil,
      minimumWritePermission: CoreL10n.text("GitLab 需要 Developer(30) 或更高项目/群组权限，才能通过 API commit 和创建 MR。"),
      message: CoreL10n.text(canWrite ? "GitLab Token 具备项目写入权限。" : "GitLab Token 可读取项目，但未确认写入权限。")
    )
  }

  func createGitHubRepository(
    profile: SiteProfile,
    name: String,
    token: String,
    privateRepository: Bool
  ) async throws -> RemoteRepositoryCreationResult {
    let baseURL = try apiBaseURL(for: profile)
    let owner = profile.repoOwner.trimmedForPublishing
    let createPath: String

    if owner.isEmpty {
      createPath = "/user/repos"
    } else {
      let currentUser: GitHubCurrentUserResponse = try await send(
        githubRequest(baseURL: baseURL, method: "GET", path: "/user", token: token)
      )
      createPath = owner.caseInsensitiveCompare(currentUser.login) == .orderedSame
        ? "/user/repos"
        : "/orgs/\(encodedPathComponent(owner))/repos"
    }

    let created: GitHubCreatedRepositoryResponse = try await send(
      githubRequest(
        baseURL: baseURL,
        method: "POST",
        path: createPath,
        token: token,
        body: GitHubCreateRepositoryBody(
          name: name,
          description: profile.name.nilIfEmpty,
          privateRepository: privateRepository,
          autoInit: false
        )
      )
    )

    return RemoteRepositoryCreationResult(
      provider: .github,
      repositoryName: created.fullName ?? name,
      defaultBranch: created.defaultBranch,
      sshURL: created.sshURL,
      cloneURL: created.cloneURL,
      htmlURL: created.htmlURL,
      privateRepository: created.privateRepository ?? privateRepository
    )
  }

  func createGitLabProject(
    profile: SiteProfile,
    name: String,
    token: String,
    privateRepository: Bool
  ) async throws -> RemoteRepositoryCreationResult {
    let baseURL = try apiBaseURL(for: profile)
    let owner = profile.repoOwner.trimmedForPublishing
    let namespaceID: Int?

    if owner.isEmpty {
      namespaceID = nil
    } else {
      let group: GitLabGroupResponse = try await send(
        gitLabRequest(
          baseURL: baseURL,
          method: "GET",
          path: "/groups/\(encodedPathComponent(owner))",
          token: token
        )
      )
      namespaceID = group.id
    }

    let created: GitLabCreatedProjectResponse = try await send(
      gitLabRequest(
        baseURL: baseURL,
        method: "POST",
        path: "/projects",
        token: token,
        body: GitLabCreateProjectBody(
          name: name,
          path: name,
          description: profile.name.nilIfEmpty,
          visibility: privateRepository ? "private" : "public",
          namespaceID: namespaceID,
          initializeWithReadme: false
        )
      )
    )

    return RemoteRepositoryCreationResult(
      provider: .gitlab,
      repositoryName: created.pathWithNamespace ?? [owner.nilIfEmpty, name].compactMap(\.self).joined(separator: "/"),
      defaultBranch: created.defaultBranch,
      sshURL: created.sshURL,
      cloneURL: created.httpURL,
      htmlURL: created.webURL,
      privateRepository: created.visibility == "private"
    )
  }

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
        let validationSHA = if createsReview && file.operation == .delete {
          try await githubContentSHA(
            repository: repository,
            path: file.repositoryPath,
            branch: targetBranch,
            token: token
          )
        } else {
          existingSHA
        }
        let content = file.operation == .upsert ? try contentData(for: file) : nil
        let isAlreadyPublished = mode == .directCommit
          && file.operation == .upsert
          && content.flatMap { githubRemoteContentMatches(data: $0, remoteSHA: existingSHA) } == true
        let isVerifiedLegacyDelete = file.operation == .delete
          && githubLegacyDeleteContentMatches(file: file, remoteSHA: validationSHA)
        let validatesExpectedVersion = mode == .directCommit
          || (createsReview && file.operation == .delete)
        if validatesExpectedVersion {
          let isIdempotentMissingDelete = file.operation == .delete && validationSHA == nil
          if !isAlreadyPublished && !isVerifiedLegacyDelete && !isIdempotentMissingDelete {
            try validateExpectedRemoteVersion(
              path: file.repositoryPath,
              expected: file.expectedRemoteSHA,
              actual: validationSHA
            )
          }
        }

        if file.operation == .delete {
          if createsReview, validationSHA != nil {
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
        message: CoreL10n.text("发布完成"),
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

  private func unwrapContentData(_ data: Data?, for file: PublishPackageFile) throws -> Data {
    guard let data else {
      throw RemoteRepositoryPublishError.invalidSourceFile(
        path: file.repositoryPath,
        reason: "无法准备发布内容。"
      )
    }
    return data
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
        let validationSHA = if createsReview && file.operation == .delete {
          try await githubContentSHA(
            repository: repository,
            path: file.repositoryPath,
            branch: targetBranch,
            token: token
          )
        } else {
          existingSHA
        }
        let content = file.operation == .upsert ? try contentData(for: file) : nil
        let isAlreadyPublished = file.operation == .upsert
          && content.flatMap { githubRemoteContentMatches(data: $0, remoteSHA: existingSHA) } == true
        let isVerifiedLegacyDelete = file.operation == .delete
          && githubLegacyDeleteContentMatches(file: file, remoteSHA: validationSHA)
        let validatesExpectedVersion = mode == .directCommit
          || (createsReview && file.operation == .delete)
        if validatesExpectedVersion {
          let isIdempotentMissingDelete = file.operation == .delete && validationSHA == nil
          if !isAlreadyPublished && !isVerifiedLegacyDelete && !isIdempotentMissingDelete {
            try validateExpectedRemoteVersion(
              path: file.repositoryPath,
              expected: file.expectedRemoteSHA,
              actual: validationSHA
            )
          }
        }

        if file.operation == .delete {
          if createsReview, validationSHA != nil {
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
        message: CoreL10n.text("发布完成"),
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

  func rollbackGitHub(
    draft: RemoteRepositoryRollbackDraft,
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryRollbackResult {
    let commit = try await githubCommit(repository: repository, sha: draft.commitSHA, token: token)
    guard let parent = commit.parents.first?.sha.nilIfEmpty else {
      throw RemoteRepositoryPublishError.rollbackCommitHasNoParent(draft.commitSHA)
    }
    let parentCommit = try await githubCommit(repository: repository, sha: parent, token: token)

    let currentTargetSHA = try await githubBranchSHA(
      repository: repository,
      branch: draft.targetBranch,
      token: token
    )
    guard currentTargetSHA == draft.commitSHA else {
      throw RemoteRepositoryPublishError.remoteVersionConflict(
        path: "refs/heads/\(draft.targetBranch)",
        expectedSHA: draft.commitSHA,
        actualSHA: currentTargetSHA
      )
    }

    let rollbackCommit: GitHubCommitResponse = try await send(
      githubRequest(
        repository: repository,
        method: "POST",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/commits",
        token: token,
        body: GitHubCreateCommitBody(
          message: draft.commitMessage,
          tree: parentCommit.tree.sha,
          parents: [draft.commitSHA]
        )
      )
    )
    let _: GitHubReferenceResponse = try await send(
      githubRequest(
        repository: repository,
        method: "PATCH",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/refs/heads/\(encodedRepositoryPath(draft.targetBranch))",
        token: token,
        body: GitHubUpdateReferenceBody(sha: rollbackCommit.sha, force: false)
      )
    )

    return RemoteRepositoryRollbackResult(
      provider: .github,
      recordID: draft.recordID,
      targetBranch: draft.targetBranch,
      rolledBackCommitSHA: draft.commitSHA,
      rollbackCommitSHA: rollbackCommit.sha,
      changedPaths: draft.changedPaths,
      remoteURL: "https://github.com/\(repository.owner)/\(repository.name)/commit/\(rollbackCommit.sha)"
    )
  }

  func rollbackGitLab(
    draft: RemoteRepositoryRollbackDraft,
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryRollbackResult {
    let reverted: GitLabCommitResponse = try await send(
      gitLabRequest(
        repository: repository,
        method: "POST",
        path: "/projects/\(encodedPathComponent(repository.projectPath))/repository/commits/\(encodedPathComponent(draft.commitSHA))/revert",
        token: token,
        body: GitLabRevertCommitBody(branch: draft.targetBranch)
      )
    )

    return RemoteRepositoryRollbackResult(
      provider: .gitlab,
      recordID: draft.recordID,
      targetBranch: draft.targetBranch,
      rolledBackCommitSHA: draft.commitSHA,
      rollbackCommitSHA: reverted.id,
      changedPaths: draft.changedPaths,
      remoteURL: "https://gitlab.com/\(repository.projectPath)/-/commit/\(reverted.id)"
    )
  }

  func withdrawGitHubReview(
    draft: RemoteRepositoryReviewWithdrawalDraft,
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryReviewWithdrawalResult {
    let response: GitHubPullRequestStateResponse = try await send(
      githubRequest(
        repository: repository,
        method: "PATCH",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/pulls/\(draft.reviewNumber)",
        token: token,
        body: GitHubClosePullRequestBody(state: "closed")
      )
    )
    return RemoteRepositoryReviewWithdrawalResult(
      provider: .github,
      recordID: draft.recordID,
      reviewURL: response.htmlURL ?? draft.reviewURL,
      reviewNumber: draft.reviewNumber,
      state: response.state ?? "closed",
      branchName: draft.branchName,
      targetBranch: draft.targetBranch
    )
  }

  func withdrawGitLabReview(
    draft: RemoteRepositoryReviewWithdrawalDraft,
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryReviewWithdrawalResult {
    let response: GitLabMergeRequestStateResponse = try await send(
      gitLabRequest(
        repository: repository,
        method: "PUT",
        path: "/projects/\(encodedPathComponent(repository.projectPath))/merge_requests/\(draft.reviewNumber)",
        token: token,
        body: GitLabCloseMergeRequestBody(stateEvent: "close")
      )
    )
    return RemoteRepositoryReviewWithdrawalResult(
      provider: .gitlab,
      recordID: draft.recordID,
      reviewURL: response.webURL ?? draft.reviewURL,
      reviewNumber: draft.reviewNumber,
      state: response.state ?? "closed",
      branchName: draft.branchName,
      targetBranch: draft.targetBranch
    )
  }

  func githubBranchSHA(
    repository: RemoteRepository,
    branch: String,
    token: String
  ) async throws -> String {
    let ref: GitHubReferenceResponse = try await send(
      githubRequest(
        repository: repository,
        method: "GET",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/ref/heads/\(encodedRepositoryPath(branch))",
        token: token
      )
    )
    return ref.object.sha
  }

  func githubCommit(
    repository: RemoteRepository,
    sha: String,
    token: String
  ) async throws -> GitHubCommitResponse {
    try await send(
      githubRequest(
        repository: repository,
        method: "GET",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/commits/\(encodedPathComponent(sha))",
        token: token
      )
    )
  }

  func githubCreateBranch(
    repository: RemoteRepository,
    branch: String,
    sha: String,
    token: String
  ) async throws {
    let _: GitHubReferenceResponse = try await send(
      githubRequest(
        repository: repository,
        method: "POST",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/refs",
        token: token,
        body: GitHubCreateReferenceBody(ref: "refs/heads/\(branch)", sha: sha)
      )
    )
  }

  func githubCreateBranchIfNeeded(
    repository: RemoteRepository,
    branch: String,
    sha: String,
    token: String
  ) async throws -> Bool {
    do {
      try await githubCreateBranch(repository: repository, branch: branch, sha: sha, token: token)
      return true
    } catch RemoteRepositoryPublishError.httpStatus(422, let body)
      where isGitHubReferenceAlreadyExists(body) {
      return false
    }
  }

  func githubDeleteBranch(
    repository: RemoteRepository,
    branch: String,
    token: String
  ) async throws {
    let response = try await data(
      for: githubRequest(
        repository: repository,
        method: "DELETE",
        path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/git/refs/heads/\(encodedRepositoryPath(branch))",
        token: token
      )
    )
    try validate(response)
  }

  func isGitHubReferenceAlreadyExists(_ body: String) -> Bool {
    let normalized = body.lowercased()
    return normalized.contains("reference already exists")
      || normalized.contains("reference already exist")
      || normalized.contains("already exists")
  }

  func githubContentSHA(
    repository: RemoteRepository,
    path: String,
    branch: String,
    token: String
  ) async throws -> String? {
    let request = githubRequest(
      repository: repository,
      method: "GET",
      path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/contents/\(encodedRepositoryPath(path))",
      token: token,
      queryItems: [URLQueryItem(name: "ref", value: branch)]
    )
    let response = try await data(for: request)
    if response.statusCode == 404 {
      return nil
    }
    try validate(response)
    return try decoder.decode(GitHubContentResponse.self, from: response.data).sha
  }

  func githubExistingPullRequestURL(
    repository: RemoteRepository,
    sourceBranch: String,
    targetBranch: String,
    token: String
  ) async throws -> String? {
    let request = githubRequest(
      repository: repository,
      method: "GET",
      path: "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))/pulls",
      token: token,
      queryItems: [
        URLQueryItem(name: "state", value: "open"),
        URLQueryItem(name: "head", value: "\(repository.owner):\(sourceBranch)"),
        URLQueryItem(name: "base", value: targetBranch),
      ]
    )
    let response = try await data(for: request)
    try validate(response)
    return try decoder.decode([GitHubPullRequestResponse].self, from: response.data).first?.htmlURL
  }

}
