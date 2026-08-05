import Foundation

public struct RepositoryScanReport: Codable, Hashable, Sendable {
  public var rootPath: String
  public var detectedKind: SiteKind?
  public var expectedKind: SiteKind
  public var hasGitDirectory: Bool
  public var contentRootExists: Bool
  public var assetRootExists: Bool
  public var markdownFileCount: Int
  public var imageFileCount: Int
  public var branchStatus: RepositoryBranchStatus?
  public var originRemote: RepositoryRemote?
  public var changedFiles: [RepositoryChangedFile]
  public var remoteChangedFiles: [RepositoryChangedFile]
  public var preflightIssues: [PreflightIssue]
  public var scannedAt: Date

  public init(
    rootPath: String,
    detectedKind: SiteKind?,
    expectedKind: SiteKind,
    hasGitDirectory: Bool,
    contentRootExists: Bool,
    assetRootExists: Bool,
    markdownFileCount: Int,
    imageFileCount: Int,
    branchStatus: RepositoryBranchStatus? = nil,
    originRemote: RepositoryRemote? = nil,
    changedFiles: [RepositoryChangedFile],
    remoteChangedFiles: [RepositoryChangedFile] = [],
    preflightIssues: [PreflightIssue],
    scannedAt: Date = Date()
  ) {
    self.rootPath = rootPath
    self.detectedKind = detectedKind
    self.expectedKind = expectedKind
    self.hasGitDirectory = hasGitDirectory
    self.contentRootExists = contentRootExists
    self.assetRootExists = assetRootExists
    self.markdownFileCount = markdownFileCount
    self.imageFileCount = imageFileCount
    self.branchStatus = branchStatus
    self.originRemote = originRemote
    self.changedFiles = changedFiles
    self.remoteChangedFiles = remoteChangedFiles
    self.preflightIssues = preflightIssues
    self.scannedAt = scannedAt
  }

  public var statusTitle: String {
    if !preflightIssues.contains(where: { $0.severity == .error }) {
      return "仓库规则可用"
    }
    return "仓库需要处理"
  }

  public var syncStatusTitle: String {
    guard hasGitDirectory else {
      return "未发现 Git 仓库"
    }
    return branchStatus?.syncStatusTitle ?? "未识别同步状态"
  }

  public func preflightIssues(requiringDeploymentReadiness: Bool) -> [PreflightIssue] {
    guard !requiringDeploymentReadiness else {
      return preflightIssues
    }

    return preflightIssues.filter { !$0.isDeploymentReadinessIssue }
  }

  public func role(
    for changedFile: RepositoryChangedFile,
    contentRoot: String,
    assetRoot: String
  ) -> RepositoryChangedFileRole {
    Self.role(for: changedFile.path, contentRoot: contentRoot, assetRoot: assetRoot)
  }

  public func changedFiles(
    role: RepositoryChangedFileRole,
    contentRoot: String,
    assetRoot: String
  ) -> [RepositoryChangedFile] {
    changedFiles.filter {
      self.role(for: $0, contentRoot: contentRoot, assetRoot: assetRoot) == role
    }
  }

  public func changeSummary(contentRoot: String, assetRoot: String) -> RepositoryChangeSummary {
    var counts: [RepositoryChangedFileRole: Int] = [:]
    for changedFile in changedFiles {
      let role = role(for: changedFile, contentRoot: contentRoot, assetRoot: assetRoot)
      counts[role, default: 0] += 1
    }

    return RepositoryChangeSummary(
      articleCount: counts[.article, default: 0],
      imageCount: counts[.image, default: 0],
      configurationCount: counts[.configuration, default: 0],
      otherCount: counts[.other, default: 0]
    )
  }

  public func changeQueueSections(contentRoot: String, assetRoot: String) -> [RepositoryChangeQueueSection] {
    RepositoryChangedFileRole.allCases.compactMap { role in
      let files = changedFiles(role: role, contentRoot: contentRoot, assetRoot: assetRoot)
      guard !files.isEmpty else { return nil }
      return RepositoryChangeQueueSection(role: role, files: files)
    }
  }

  public func remoteChangedFilesForRole(
    role: RepositoryChangedFileRole,
    contentRoot: String,
    assetRoot: String
  ) -> [RepositoryChangedFile] {
    remoteChangedFiles.filter {
      Self.role(for: $0.path, contentRoot: contentRoot, assetRoot: assetRoot) == role
    }
  }

  public func remoteChangeSummary(contentRoot: String, assetRoot: String) -> RepositoryChangeSummary {
    var counts: [RepositoryChangedFileRole: Int] = [:]
    for changedFile in remoteChangedFiles {
      let role = Self.role(for: changedFile.path, contentRoot: contentRoot, assetRoot: assetRoot)
      counts[role, default: 0] += 1
    }

    return RepositoryChangeSummary(
      articleCount: counts[.article, default: 0],
      imageCount: counts[.image, default: 0],
      configurationCount: counts[.configuration, default: 0],
      otherCount: counts[.other, default: 0]
    )
  }

  public func remoteChangeQueueSections(contentRoot: String, assetRoot: String) -> [RepositoryChangeQueueSection] {
    RepositoryChangedFileRole.allCases.compactMap { role in
      let files = remoteChangedFilesForRole(role: role, contentRoot: contentRoot, assetRoot: assetRoot)
      guard !files.isEmpty else { return nil }
      return RepositoryChangeQueueSection(role: role, files: files)
    }
  }

  private static func role(
    for path: String,
    contentRoot: String,
    assetRoot: String
  ) -> RepositoryChangedFileRole {
    let normalizedPath = effectiveChangedPath(path).normalizedRelativePath()
    let contentRoot = contentRoot.normalizedRelativePath()
    let privateContentRoot = SiteProfile.privateContentRoot.normalizedRelativePath()
    let assetRoot = assetRoot.normalizedRelativePath()
    let pathExtension = (normalizedPath as NSString).pathExtension.lowercased()

    if (isWithin(normalizedPath, root: contentRoot) || isWithin(normalizedPath, root: privateContentRoot)),
       ["md", "markdown", "mdx"].contains(pathExtension) {
      return .article
    }

    if isWithin(normalizedPath, root: assetRoot), ImageFileSupport.supportedExtensions.contains(pathExtension) {
      return .image
    }

    if isConfigurationPath(normalizedPath) {
      return .configuration
    }

    return .other
  }

  private static func effectiveChangedPath(_ path: String) -> String {
    path.components(separatedBy: " -> ").last?.trimmedForPublishing ?? path.trimmedForPublishing
  }

  private static func isWithin(_ path: String, root: String) -> Bool {
    guard !root.isEmpty else { return false }
    return path == root || path.hasPrefix(root + "/")
  }

  private static func isConfigurationPath(_ path: String) -> Bool {
    let filename = URL(fileURLWithPath: path).lastPathComponent.lowercased()
    let knownFilenames: Set<String> = [
      "_config.yml",
      "_config.yaml",
      "astro.config.mjs",
      "astro.config.ts",
      "config.toml",
      "config.yaml",
      "config.yml",
      "hugo.toml",
      "hugo.yaml",
      "hugo.json",
      "package.json",
      "pnpm-lock.yaml",
      "package-lock.json",
      "yarn.lock",
    ]
    return knownFilenames.contains(filename) || filename.contains("config.")
  }
}
extension PreflightIssue {
  var isDeploymentReadinessIssue: Bool {
    switch field {
    case "siteKind", "contentRoot", "assetRoot":
      return true
    default:
      return false
    }
  }
}
