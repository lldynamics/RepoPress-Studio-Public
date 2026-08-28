import Foundation

extension RemoteRepositoryPublishService {
  public func checkAccess(
    profile: SiteProfile,
    token: String?
  ) async throws -> RemoteRepositoryAccessCheck {
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)

    var check: RemoteRepositoryAccessCheck
    switch profile.repositoryProvider {
    case .github:
      check = try await checkGitHubAccess(repository: repository, token: token)
    case .gitlab:
      check = try await checkGitLabAccess(repository: repository, token: token)
    }
    check.targetBranch = repository.branch
    check.publishStrategy = profile.repositoryPublishStrategy
    return check
  }

  public func createRepository(
    profile: SiteProfile,
    token: String?,
    privateRepository: Bool = true
  ) async throws -> RemoteRepositoryCreationResult {
    let token = try requiredToken(token)
    let name = profile.repoName.trimmedForPublishing
    guard !name.isEmpty else {
      throw RemoteRepositoryPublishError.missingRepositoryName
    }

    switch profile.repositoryProvider {
    case .github:
      return try await createGitHubRepository(
        profile: profile,
        name: name,
        token: token,
        privateRepository: privateRepository
      )
    case .gitlab:
      return try await createGitLabProject(
        profile: profile,
        name: name,
        token: token,
        privateRepository: privateRepository
      )
    }
  }

  public func publish(
    package: PublishPackage,
    profile: SiteProfile,
    mode: RemoteRepositoryPublishMode,
    token: String?,
    onProgress: (@Sendable (RemoteRepositoryPublishProgress) -> Void)? = nil
  ) async throws -> RemoteRepositoryPublishResult {
    let package = try normalizedPublishPackage(package)
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)

    onProgress?(
      .init(
        stage: .preparing,
        progress: 0.05,
        message: CoreL10n.text("开始发布"),
        detail: CoreL10n.text("已解析发布参数")
      )
    )

    let result: RemoteRepositoryPublishResult
    switch profile.repositoryProvider {
    case .github:
      result = try await publishToGitHub(
        package: package,
        repository: repository,
        mode: mode,
        token: token,
        onProgress: onProgress
      )
    case .gitlab:
      result = try await publishToGitLab(
        package: package,
        repository: repository,
        mode: mode,
        token: token,
        onProgress: onProgress
      )
    }
    return try result.validatedForSuccess()
  }

  public func rollback(
    draft: RemoteRepositoryRollbackDraft,
    profile: SiteProfile,
    token: String?
  ) async throws -> RemoteRepositoryRollbackResult {
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)

    switch profile.repositoryProvider {
    case .github:
      return try await rollbackGitHub(draft: draft, repository: repository, token: token)
    case .gitlab:
      return try await rollbackGitLab(draft: draft, repository: repository, token: token)
    }
  }

  public func withdrawReview(
    draft: RemoteRepositoryReviewWithdrawalDraft,
    profile: SiteProfile,
    token: String?
  ) async throws -> RemoteRepositoryReviewWithdrawalResult {
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)

    switch profile.repositoryProvider {
    case .github:
      return try await withdrawGitHubReview(draft: draft, repository: repository, token: token)
    case .gitlab:
      return try await withdrawGitLabReview(draft: draft, repository: repository, token: token)
    }
  }
}
