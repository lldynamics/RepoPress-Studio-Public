import Foundation

// MARK: - Provider access checks
extension RemoteRepositoryPublishService {
  func checkGitHubAccess(
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryAccessCheck {
    let response = try await data(
      for: githubRequest(
        repository: repository,
        method: "GET",
        path:
          "/repos/\(encodedPathComponent(repository.owner))/\(encodedPathComponent(repository.name))",
        token: token
      )
    )
    try validate(response)
    let metadata = try decoder.decode(GitHubRepositoryMetadata.self, from: response.data)
    let canWrite =
      metadata.permissions?.push == true
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
      tokenWriteVerification: .unverified,
      permissionSummary: permissionSummary,
      tokenScopeSummary: scopeSummary,
      minimumWritePermission: CoreL10n.text(
        "此检查只通过 GET /repos 确认账号的仓库角色，未逐项验证 Token 的实际 API 权限。GitHub 写入内容需要 Contents: Read and write；使用 PR 发布还需要 Pull requests: Read and write；合并检查还需要 Checks: Read-only 与 Commit statuses: Read-only。"
      ),
      message: CoreL10n.text(
        canWrite
          ? "GitHub GET /repos 检测到账号具有仓库写入角色；Contents、Pull requests、Checks 和 Commit statuses 的 Token API 权限仍会在实际请求时验证。"
          : "GitHub GET /repos 可读取仓库，但未检测到账号写入角色；也未逐项验证 Token 的实际 API 权限。")
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
    let hasWriteRole = accessLevel >= 30
    let scopeInspection: GitLabTokenScopeInspection
    if hasWriteRole {
      scopeInspection = try await inspectGitLabCurrentToken(repository: repository, token: token)
    } else {
      scopeInspection = .notRequested
    }

    let canWrite: Bool
    let tokenWriteVerification: RemoteRepositoryTokenWriteVerification
    let tokenScopeSummary: String?
    let message: String

    if !hasWriteRole {
      canWrite = false
      tokenWriteVerification = .insufficient
      tokenScopeSummary = nil
      message = CoreL10n.text(
        "GitLab Token 可读取项目，但账号角色低于 Developer(30)，无法执行仓库 API 写入。"
      )
    } else {
      switch scopeInspection {
      case .available(let tokenMetadata):
        tokenScopeSummary = gitLabTokenScopeSummary(tokenMetadata)
        if !tokenMetadata.isUsable {
          canWrite = false
          tokenWriteVerification = .insufficient
          message = CoreL10n.text(
            "GitLab 已检测到 Developer 或更高角色，但 Token 已失效、被撤销或过期，无法执行仓库 API 写入。"
          )
        } else if tokenMetadata.normalizedScopes.contains("api") {
          canWrite = true
          tokenWriteVerification = .verified
          message = CoreL10n.text(
            "GitLab 已验证 Developer 或更高角色，且当前 Token 具备 api scope，可执行本应用的仓库 API 写入。"
          )
        } else {
          canWrite = false
          tokenWriteVerification = .insufficient
          message = CoreL10n.text(
            "GitLab 已检测到 Developer 或更高角色，但 Token 缺少 api scope。write_repository 只授权 Git-over-HTTP，不授权本应用使用的 REST API commit 和 MR。"
          )
        }
      case .unavailable:
        // Project and group access tokens are not guaranteed to expose the
        // personal-token self endpoint. Preserve the historical ability to
        // try the real mutation while reporting the evidence as incomplete.
        canWrite = true
        tokenWriteVerification = .unverified
        tokenScopeSummary = CoreL10n.text(
          "GitLab 未提供可验证的当前 Token scope；项目角色不等于 API scope。"
        )
        message = CoreL10n.text(
          "GitLab 已检测到 Developer 或更高角色，但未能验证 Token 的 api scope；实际写入请求仍会校验权限。"
        )
      case .notRequested:
        // Covered by the role check above.
        canWrite = false
        tokenWriteVerification = .insufficient
        tokenScopeSummary = nil
        message = CoreL10n.text("GitLab Token 未确认仓库 API 写入权限。")
      }
    }

    return RemoteRepositoryAccessCheck(
      provider: .gitlab,
      repositoryName: metadata.pathWithNamespace ?? repository.displayName,
      apiBaseURL: normalizedAPIBaseURLString(repository.apiBaseURL),
      defaultBranch: metadata.defaultBranch,
      canRead: true,
      canWrite: canWrite,
      tokenWriteVerification: tokenWriteVerification,
      permissionSummary: gitLabPermissionSummary(metadata.permissions),
      tokenScopeSummary: tokenScopeSummary,
      minimumWritePermission: CoreL10n.text(
        "GitLab 需要 Developer(30) 或更高项目/群组权限，且 Token 需要 api scope，才能通过 REST API commit 和创建 MR。write_repository 只用于 Git-over-HTTP。"
      ),
      message: message
    )
  }

  private func inspectGitLabCurrentToken(
    repository: RemoteRepository,
    token: String
  ) async throws -> GitLabTokenScopeInspection {
    do {
      let response = try await data(
        for: gitLabRequest(
          repository: repository,
          method: "GET",
          path: "/personal_access_tokens/self",
          token: token
        )
      )
      guard (200..<300).contains(response.statusCode) else {
        return .unavailable
      }
      guard let metadata = try? decoder.decode(GitLabCurrentTokenMetadata.self, from: response.data)
      else {
        return .unavailable
      }
      return .available(metadata)
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      return .unavailable
    }
  }

  private func gitLabTokenScopeSummary(_ metadata: GitLabCurrentTokenMetadata) -> String {
    let scopes =
      metadata.normalizedScopes.isEmpty
      ? CoreL10n.text("无")
      : metadata.normalizedScopes.sorted().joined(separator: ", ")
    let active = metadata.isUsable ? CoreL10n.text("有效") : CoreL10n.text("不可用")
    if let expiresAt = metadata.expiresAt?.trimmedForPublishing.nilIfEmpty {
      return CoreL10n.format("GitLab Token scopes: %@；状态：%@；到期：%@。", scopes, active, expiresAt)
    }
    return CoreL10n.format("GitLab Token scopes: %@；状态：%@。", scopes, active)
  }
}

private enum GitLabTokenScopeInspection {
  case available(GitLabCurrentTokenMetadata)
  case unavailable
  case notRequested
}
