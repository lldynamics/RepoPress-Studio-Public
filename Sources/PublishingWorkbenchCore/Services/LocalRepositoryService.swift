import Foundation

public struct LocalRepositoryService: @unchecked Sendable {
  let fileManager: FileManager
  let gitCommandRunner: GitCommandRunner

  public init(
    fileManager: FileManager = .default,
    gitCommandRunner: GitCommandRunner = GitCommandRunner()
  ) {
    self.fileManager = fileManager
    self.gitCommandRunner = gitCommandRunner
  }

  public func scan(profile: SiteProfile) -> RepositoryScanReport {
    scan(profile: profile, cancellationCheck: { false })
  }

  func scan(
    profile: SiteProfile,
    cancellationCheck: @escaping @Sendable () -> Bool
  ) -> RepositoryScanReport {
    guard let report = profile.withLocalRepositoryRootAccess({ rootURL in
      scan(
        rootURL: rootURL,
        profile: profile,
        cancellationCheck: cancellationCheck
      )
    }) else {
      return RepositoryScanReport(
        rootPath: "",
        detectedKind: nil,
        expectedKind: profile.siteKind,
        hasGitDirectory: false,
        contentRootExists: false,
        assetRootExists: false,
        markdownFileCount: 0,
        imageFileCount: 0,
        branchStatus: nil,
        changedFiles: [],
        remoteChangedFiles: [],
        preflightIssues: [
          .init(
            severity: .warning,
            title: CoreL10n.text("未选择本地仓库"),
            message: CoreL10n.text("请选择 Zola/Hugo/Astro/Jekyll/Hexo 仓库根目录。"),
            field: "repository"
          )
        ]
      )
    }

    return report
  }

  public func localBranches(profile: SiteProfile) -> [RepositoryBranch] {
    guard let branches = profile.withLocalRepositoryRootAccess({ rootURL in
      self.localBranches(rootURL: rootURL)
    }) else {
      return []
    }
    return branches
  }

  public func switchLocalBranch(profile: SiteProfile, to branchName: String) throws {
    let branchName = branchName.trimmedForPublishing
    guard isValidBranchName(branchName) else {
      throw LocalRepositoryServiceError.invalidBranchName
    }

    guard let result = try profile.withLocalRepositoryRootAccess({ rootURL in
      try self.requireCleanWorkingTree(rootURL: rootURL)
      return self.runGitCommand(["switch", "--", branchName], rootURL: rootURL)
    }) else {
      throw LocalRepositoryServiceError.repositoryUnavailable
    }
    guard result.terminationStatus == 0 else {
      throw LocalRepositoryServiceError.commandFailed(terminated: result.terminationStatus, output: result.output)
    }
  }

  public func createAndSwitchLocalBranch(
    profile: SiteProfile,
    branchName: String,
    from sourceBranch: String?
  ) throws {
    let branchName = branchName.trimmedForPublishing
    guard isValidBranchName(branchName) else {
      throw LocalRepositoryServiceError.invalidBranchName
    }
    let sourceBranch = sourceBranch?.trimmedForPublishing.nilIfEmpty
    if let sourceBranch, !isValidBranchName(sourceBranch) {
      throw LocalRepositoryServiceError.invalidBranchName
    }

    guard let result = try profile.withLocalRepositoryRootAccess({ rootURL in
      try self.requireCleanWorkingTree(rootURL: rootURL)
      var arguments = ["switch", "-c", branchName]
      if let sourceBranch {
        arguments.append(sourceBranch)
      }
      return self.runGitCommand(arguments, rootURL: rootURL)
    }) else {
      throw LocalRepositoryServiceError.repositoryUnavailable
    }
    guard result.terminationStatus == 0 else {
      throw LocalRepositoryServiceError.commandFailed(terminated: result.terminationStatus, output: result.output)
    }
  }

  private func requireCleanWorkingTree(rootURL: URL) throws {
    let result = runGitCommand(
      ["status", "--porcelain", "--untracked-files=normal"],
      rootURL: rootURL
    )
    guard result.terminationStatus == 0 else {
      throw LocalRepositoryServiceError.commandFailed(
        terminated: result.terminationStatus,
        output: result.output
      )
    }
    guard result.standardOutput.trimmedForPublishing.isEmpty else {
      throw LocalRepositoryServiceError.workingTreeHasChanges
    }
  }

  private func isValidBranchName(_ name: String) -> Bool {
    !name.isEmpty
      && !name.hasPrefix("-")
      && !name.hasSuffix(".")
      && !name.hasSuffix("/")
      && !name.contains("..")
      && !name.contains("@{")
      && !name.unicodeScalars.contains(where: { scalar in
        scalar.value < 0x20 || scalar.value == 0x7F
      })
      && name.rangeOfCharacter(from: CharacterSet(charactersIn: " ~^:?*[\\")) == nil
  }

  public func recentCommits(profile: SiteProfile, limit: Int = 20) -> [RepositoryCommitInfo] {
    let normalizedLimit = max(1, limit)
    guard let commits = profile.withLocalRepositoryRootAccess({ rootURL in
      self.recentCommits(rootURL: rootURL, limit: normalizedLimit)
    }) else {
      return []
    }
    return commits
  }

  public func ignoredRepositoryPaths(profile: SiteProfile, paths: [String]) -> [String] {
    let safeInputPaths = Set(
      paths
        .map { $0.components(separatedBy: " -> ").last?.trimmedForPublishing ?? $0.trimmedForPublishing }
        .map { $0.normalizedRelativePath() }
        .filter { !$0.isEmpty }
    )
      .sorted()

    guard !safeInputPaths.isEmpty else {
      return []
    }

    guard let ignored = profile.withLocalRepositoryRootAccess({ rootURL in
      self.ignoredRepositoryPaths(rootURL: rootURL, paths: safeInputPaths)
    }) else {
      return []
    }

    return ignored
  }

  public func remoteFileSnapshot(profile: SiteProfile, repositoryPath: String) -> RepositoryFileSnapshot? {
    profile.withLocalRepositoryRootAccess { rootURL -> [RepositoryFileSnapshot] in
      guard let snapshot = remoteFileSnapshot(
        rootURL: rootURL,
        repositoryPath: repositoryPath,
        repositoryProvider: profile.repositoryProvider
      ) else {
        return []
      }
      return [snapshot]
    }
    .flatMap(\.first)
  }

  public func fetchUpstream(profile: SiteProfile) -> RepositoryFetchResult {
    guard let result = profile.withLocalRepositoryRootAccess({ rootURL in
      fetchUpstream(rootURL: rootURL)
    }) else {
      return RepositoryFetchResult(
        status: .skipped,
        remoteName: nil,
        upstreamName: nil,
        message: "未选择本地仓库，跳过远端 fetch。"
      )
    }
    return result
  }

}
