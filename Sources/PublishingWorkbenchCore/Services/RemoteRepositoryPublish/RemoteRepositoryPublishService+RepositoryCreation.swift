import Foundation

// MARK: - Provider repository creation
extension RemoteRepositoryPublishService {
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
}
