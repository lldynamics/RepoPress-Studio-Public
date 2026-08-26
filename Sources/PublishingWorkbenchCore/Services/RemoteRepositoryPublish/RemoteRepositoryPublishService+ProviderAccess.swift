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
}
