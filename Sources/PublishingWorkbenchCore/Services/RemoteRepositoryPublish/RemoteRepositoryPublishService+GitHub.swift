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
      minimumWritePermission: "GitHub 需要 repository permissions.push=true，或 fine-grained token 具备 Contents: Read and write。",
      message: canWrite ? "GitHub Token 具备仓库写入权限。" : "GitHub Token 可读取仓库，但未确认写入权限。"
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
      minimumWritePermission: "GitLab 需要 Developer(30) 或更高项目/群组权限，才能通过 API commit 和创建 MR。",
      message: canWrite ? "GitLab Token 具备项目写入权限。" : "GitLab Token 可读取项目，但未确认写入权限。"
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
    let targetBranch = repository.branch
    let branchName = mode == .reviewRequest ? package.reviewBranchName : targetBranch
    let reviewDraft = RemoteReviewDraftBuilder().build(package: package, profile: repository.profile)
    var didCreateReviewBranch = false

    onProgress?(
      .init(
        stage: .validatingTarget,
        progress: 0.12,
        message: "检查目标分支",
        detail: targetBranch
      )
    )

    if mode == .reviewRequest {
      onProgress?(
        .init(
          stage: .creatingBranch,
          progress: 0.18,
          message: "处理 PR/MR 分支",
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
    var lastCommitSHA: String?
    var reviewURL: String?
    let totalFiles = max(1, package.files.count)
    do {
      for (index, file) in package.files.enumerated() {
        onProgress?(
          .init(
            stage: .uploadingFiles,
            progress: 0.2 + 0.7 * (Double(index) / Double(totalFiles)),
            message: "提交文件",
            detail: "第 \(index + 1)/\(package.files.count) 个文件",
            filePath: file.repositoryPath
          )
        )
        let existingSHA = try await githubContentSHA(
          repository: repository,
          path: file.repositoryPath,
          branch: branchName,
          token: token
        )
        if mode == .directCommit {
          try validateExpectedRemoteVersion(
            path: file.repositoryPath,
            expected: file.expectedRemoteSHA,
            actual: existingSHA
          )
        }
        let data = try contentData(for: file)
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
      }

      if mode == .reviewRequest {
        onProgress?(
          .init(
            stage: .creatingReview,
            progress: 0.92,
            message: "创建/获取 PR",
            detail: branchName
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
        underlyingMessage: error.localizedDescription
      )
    } catch {
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
        underlyingMessage: error.localizedDescription
      )
    }

    onProgress?(
      .init(
        stage: .completed,
        progress: 1,
        message: "发布完成",
        detail: "共提交 \(changedPaths.count) 个文件"
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
      reviewURL: reviewURL,
      reviewTitle: mode == .reviewRequest ? reviewDraft.title : nil
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
    let branchName = mode == .reviewRequest ? package.reviewBranchName : targetBranch
    let reviewDraft = RemoteReviewDraftBuilder().build(package: package, profile: repository.profile)
    onProgress?(
      .init(
        stage: .validatingTarget,
        progress: 0.12,
        message: "检查目标分支",
        detail: targetBranch
      )
    )
    let reviewBranchExists = mode == .reviewRequest
      ? try await {
        onProgress?(
          .init(
            stage: .creatingBranch,
            progress: 0.18,
            message: "处理 PR/MR 分支",
            detail: branchName
          )
        )
        return try await gitLabBranchExists(repository: repository, branch: branchName, token: token)
      }()
      : false
    let existenceRef = mode == .reviewRequest && reviewBranchExists ? branchName : targetBranch

    var actions: [GitLabCommitAction] = []
    let totalFiles = max(1, package.files.count)
    for (index, file) in package.files.enumerated() {
      onProgress?(
        .init(
          stage: .uploadingFiles,
          progress: 0.2 + 0.65 * (Double(index) / Double(totalFiles)),
          message: "构建提交",
          detail: "第 \(index + 1)/\(package.files.count) 个文件",
          filePath: file.repositoryPath
        )
      )
      let remoteState = try await gitLabFileState(
        repository: repository,
        path: file.repositoryPath,
        ref: existenceRef,
        token: token
      )
      if mode == .directCommit {
        try validateExpectedRemoteVersion(
          path: file.repositoryPath,
          expected: file.expectedRemoteSHA,
          actual: remoteState.lastCommitID
        )
      }
      let data = try contentData(for: file)
      actions.append(
        GitLabCommitAction(
          action: remoteState.exists ? "update" : "create",
          filePath: file.repositoryPath,
          content: file.kind == .image ? data.base64EncodedString() : String(data: data, encoding: .utf8) ?? "",
          encoding: file.kind == .image ? "base64" : nil,
          lastCommitID: remoteState.lastCommitID
        )
      )
    }

    onProgress?(
      .init(
        stage: .uploadingFiles,
        progress: 0.85,
        message: "提交 Commit",
        detail: "推送 \(actions.count) 个变更"
      )
    )

    let commitBody = GitLabCreateCommitBody(
      branch: branchName,
      commitMessage: package.commitMessage,
      startBranch: mode == .reviewRequest && !reviewBranchExists ? targetBranch : nil,
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

    let changedPaths = package.files.map(\.repositoryPath)
    var reviewURL: String?
    if mode == .reviewRequest {
      onProgress?(
        .init(
          stage: .creatingReview,
          progress: 0.92,
          message: "创建/获取 MR",
          detail: branchName
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
            message: "创建 MR 失败",
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
          underlyingMessage: error.localizedDescription
        )
      } catch {
        onProgress?(
          .init(
            stage: .failed,
            progress: nil,
            message: "创建 MR 失败",
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
          underlyingMessage: error.localizedDescription
        )
      }
    }

    onProgress?(
      .init(
        stage: .completed,
        progress: 1,
        message: "发布完成",
        detail: "共提交 \(changedPaths.count) 个文件"
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
      reviewURL: reviewURL,
      reviewTitle: mode == .reviewRequest ? reviewDraft.title : nil
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
