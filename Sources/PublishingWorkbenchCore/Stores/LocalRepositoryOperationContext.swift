import Foundation

struct LocalRepositoryIdentity: Equatable, Sendable {
  let rootPath: String

  init?(profile: SiteProfile) {
    guard let rootURL = profile.localRepositoryRootURL else { return nil }
    self.init(rootURL: rootURL)
  }

  init?(rootPath: String) {
    let trimmedRootPath = rootPath.trimmedForPublishing
    guard !trimmedRootPath.isEmpty else { return nil }
    self.init(rootURL: URL(fileURLWithPath: trimmedRootPath, isDirectory: true))
  }

  private init(rootURL: URL) {
    rootPath = rootURL
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }
}

struct LocalRepositoryOperationContext: Equatable {
  let id: UUID
  let profileID: UUID
  let repositoryIdentity: LocalRepositoryIdentity?

  init(profile: SiteProfile) {
    id = UUID()
    profileID = profile.id
    repositoryIdentity = LocalRepositoryIdentity(profile: profile)
  }

  func stillMatches(_ profile: SiteProfile) -> Bool {
    profile.id == profileID
      && LocalRepositoryIdentity(profile: profile) == repositoryIdentity
  }
}

struct RemoteRepositoryOperationContext: Equatable, Sendable {
  let id: UUID
  let profileID: UUID
  let provider: RepositoryProvider
  let repositoryBaseURL: String
  let repositoryOwner: String
  let repositoryName: String
  let branch: String

  init(profile: SiteProfile) {
    id = UUID()
    profileID = profile.id
    provider = profile.repositoryProvider
    repositoryBaseURL = Self.normalized(profile.repositoryBaseURL)
    repositoryOwner = profile.repoOwner.trimmedForPublishing
    repositoryName = profile.repoName.trimmedForPublishing
    branch = profile.branch.trimmedForPublishing
  }

  func stillMatches(_ profile: SiteProfile?) -> Bool {
    guard let profile else { return false }
    return profile.id == profileID
      && profile.repositoryProvider == provider
      && Self.normalized(profile.repositoryBaseURL) == repositoryBaseURL
      && profile.repoOwner.trimmedForPublishing == repositoryOwner
      && profile.repoName.trimmedForPublishing == repositoryName
      && profile.branch.trimmedForPublishing == branch
  }

  private static func normalized(_ value: String) -> String {
    value.trimmedForPublishing.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}
