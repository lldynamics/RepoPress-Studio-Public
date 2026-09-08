import Foundation

/// The durable, non-secret part of an in-progress starter site. It deliberately
/// refers back to the normal profile and draft snapshots instead of copying
/// article content, remote authorization, or Git command output.
public struct SiteStarterProgress: Codable, Hashable, Sendable {
  public enum FirstPushStage: String, Codable, Hashable, Sendable {
    case pending
    case committed
    case completed
  }

  public var profileID: UUID
  public var repositoryRootPath: String
  public var templateID: SiteStarterTemplateID
  public var initialDraftID: UUID
  public var createdFilePaths: [String]
  public var initializedGit: Bool
  public var originConfigured: Bool
  public var firstPushStage: FirstPushStage
  /// A SHA is only recorded after the local commit succeeds and before any
  /// network push starts. Crash recovery must prove a later HEAD against the
  /// complete frozen review before recording it here.
  public var localCommitSHA: String?
  public var frozenFirstPushRemoteURL: String?
  public var frozenFirstPushBranch: String?
  public var frozenFirstPushHeadCommitSHA: String?
  public var frozenFirstPushRemoteBranchCommitSHA: String?
  /// Full Codable review proof, retained for exact retry and crash recovery.
  public var frozenPushConfirmation: SiteStarterPushConfirmation?
  /// Wizard inputs that do not have a stable home in `SiteProfile`. Optional
  /// storage keeps checkpoints written before these recovery fields usable.
  public var siteDescription: String?
  public var deploymentTarget: SiteStarterDeploymentTarget?
  public var configureOriginRemote: Bool?

  public init(
    profileID: UUID,
    repositoryRootPath: String,
    templateID: SiteStarterTemplateID,
    initialDraftID: UUID,
    createdFilePaths: [String],
    initializedGit: Bool,
    originConfigured: Bool,
    firstPushStage: FirstPushStage = .pending,
    localCommitSHA: String? = nil,
    frozenFirstPushRemoteURL: String? = nil,
    frozenFirstPushBranch: String? = nil,
    frozenFirstPushHeadCommitSHA: String? = nil,
    frozenFirstPushRemoteBranchCommitSHA: String? = nil,
    frozenPushConfirmation: SiteStarterPushConfirmation? = nil,
    siteDescription: String? = nil,
    deploymentTarget: SiteStarterDeploymentTarget? = nil,
    configureOriginRemote: Bool? = nil
  ) {
    self.profileID = profileID
    self.repositoryRootPath = Self.normalizedRootPath(repositoryRootPath) ?? ""
    self.templateID = templateID
    self.initialDraftID = initialDraftID
    self.createdFilePaths = Self.normalizedPaths(createdFilePaths)
    self.initializedGit = initializedGit
    self.originConfigured = originConfigured
    self.firstPushStage = firstPushStage
    self.localCommitSHA = localCommitSHA?.trimmedForPublishing.nilIfEmpty
    self.frozenFirstPushRemoteURL = frozenFirstPushRemoteURL?.trimmedForPublishing.nilIfEmpty
    self.frozenFirstPushBranch = frozenFirstPushBranch?.trimmedForPublishing.nilIfEmpty
    self.frozenFirstPushHeadCommitSHA = frozenFirstPushHeadCommitSHA?.trimmedForPublishing.nilIfEmpty
    self.frozenFirstPushRemoteBranchCommitSHA = frozenFirstPushRemoteBranchCommitSHA?.trimmedForPublishing.nilIfEmpty
    self.frozenPushConfirmation = frozenPushConfirmation
    self.siteDescription = siteDescription
    self.deploymentTarget = deploymentTarget
    self.configureOriginRemote = configureOriginRemote
  }

  public func resumePresentation(for profile: SiteProfile) -> SiteStarterResumePresentation? {
    guard profile.id == profileID,
      let rootPath = Self.normalizedRootPath(profile.localRepositoryRootPath),
      rootPath == repositoryRootPath
    else {
      return nil
    }
    let target = deploymentTarget ?? Self.deploymentTarget(for: profile)
    let route: SiteStarterResumeRoute
    if firstPushStage == .completed || target == .none {
      route = .deployment
    } else if originConfigured {
      route = .firstPush
    } else {
      route = .github
    }
    return SiteStarterResumePresentation(
      templateID: templateID,
      rootPath: profile.localRepositoryRootPath,
      siteName: profile.name,
      siteDescription: siteDescription ?? "",
      author: profile.defaultAuthor,
      baseURL: profile.deploymentSiteURL ?? "",
      branch: profile.branch,
      githubOwner: profile.repoOwner,
      githubRepositoryName: profile.repoName,
      deploymentTarget: target,
      deploymentProjectID: profile.deploymentProjectID ?? "",
      deploymentAccountID: profile.deploymentAccountID ?? "",
      initializesGit: initializedGit,
      configuresOrigin: configureOriginRemote ?? originConfigured,
      route: route
    )
  }

  public func resumedResult(
    activeProfile: SiteProfile,
    drafts: [ArticleDraft],
    fileManager: FileManager = .default
  ) -> SiteStarterResult? {
    guard activeProfile.id == profileID,
      let rootURL = activeProfile.localRepositoryRootURL,
      Self.normalizedRootPath(rootURL.path) == repositoryRootPath,
      !repositoryRootPath.isEmpty,
      fileManager.fileExists(atPath: rootURL.path),
      (!initializedGit || fileManager.fileExists(
        atPath: rootURL.appendingPathComponent(".git", isDirectory: true).path
      )),
      let draft = drafts.first(where: { $0.id == initialDraftID && $0.siteProfileID == profileID }),
      !createdFilePaths.isEmpty
    else {
      return nil
    }

    let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    guard createdFilePaths.allSatisfy({ relativePath in
      guard Self.isSafeRelativePath(relativePath) else { return false }
      let fileURL = resolvedRoot.appendingPathComponent(relativePath).standardizedFileURL
        .resolvingSymlinksInPath()
      return fileURL.path.hasPrefix(resolvedRoot.path + "/")
        && fileManager.fileExists(atPath: fileURL.path)
    }) else {
      return nil
    }

    return SiteStarterResult(
      profile: activeProfile,
      initialDraft: draft,
      createdFilePaths: createdFilePaths,
      initializedGit: initializedGit,
      configuredRemoteURL: originConfigured ? Self.expectedRemoteURL(for: activeProfile) : nil,
      deploymentGuidePath: createdFilePaths.contains("DEPLOYMENT.md") ? "DEPLOYMENT.md" : nil,
      nextCommands: []
    )
  }

  public static func normalizedRootPath(_ path: String) -> String? {
    let trimmed = path.trimmedForPublishing
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: trimmed, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }

  public static func normalizedPaths(_ paths: [String]) -> [String] {
    Array(Set(paths.map { $0.trimmedForPublishing }))
      .filter(isSafeRelativePath)
      .sorted()
  }

  public static func isSafeRelativePath(_ path: String) -> Bool {
    return !path.isEmpty
      && !path.hasPrefix("/")
      && !path.split(separator: "/").contains("..")
      && !path.split(separator: "/").contains(".")
  }

  private static func expectedRemoteURL(for profile: SiteProfile) -> String? {
    let owner = profile.repoOwner.trimmedForPublishing
    let repository = profile.repoName.trimmedForPublishing
    guard !owner.isEmpty, !repository.isEmpty else { return nil }
    return "git@github.com:\(owner)/\(repository).git"
  }

  private static func deploymentTarget(for profile: SiteProfile) -> SiteStarterDeploymentTarget {
    guard let provider = profile.deploymentProvider else { return .none }
    switch provider {
    case .githubPages:
      return .githubPages
    case .netlify:
      return .netlify
    case .vercel:
      return .vercel
    case .cloudflarePages:
      return .cloudflarePages
    case .gitlabPages, .custom:
      return .none
    }
  }
}

public enum SiteStarterResumeRoute: Hashable, Sendable {
  case github
  case firstPush
  case deployment
}

/// A value-only projection that lets each wizard window restore its own scene
/// state without relying on another window's `SceneStorage` values.
public struct SiteStarterResumePresentation: Hashable, Sendable {
  public var templateID: SiteStarterTemplateID
  public var rootPath: String
  public var siteName: String
  public var siteDescription: String
  public var author: String
  public var baseURL: String
  public var branch: String
  public var githubOwner: String
  public var githubRepositoryName: String
  public var deploymentTarget: SiteStarterDeploymentTarget
  public var deploymentProjectID: String
  public var deploymentAccountID: String
  public var initializesGit: Bool
  public var configuresOrigin: Bool
  public var route: SiteStarterResumeRoute

  public init(
    templateID: SiteStarterTemplateID,
    rootPath: String,
    siteName: String,
    siteDescription: String,
    author: String,
    baseURL: String,
    branch: String,
    githubOwner: String,
    githubRepositoryName: String,
    deploymentTarget: SiteStarterDeploymentTarget,
    deploymentProjectID: String,
    deploymentAccountID: String,
    initializesGit: Bool,
    configuresOrigin: Bool,
    route: SiteStarterResumeRoute
  ) {
    self.templateID = templateID
    self.rootPath = rootPath
    self.siteName = siteName
    self.siteDescription = siteDescription
    self.author = author
    self.baseURL = baseURL
    self.branch = branch
    self.githubOwner = githubOwner
    self.githubRepositoryName = githubRepositoryName
    self.deploymentTarget = deploymentTarget
    self.deploymentProjectID = deploymentProjectID
    self.deploymentAccountID = deploymentAccountID
    self.initializesGit = initializesGit
    self.configuresOrigin = configuresOrigin
    self.route = route
  }
}
