import Foundation

public enum RepositoryChangeKind: String, Codable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case untracked
  case other

  public var displayName: String {
    switch self {
    case .added:
      return "新增"
    case .modified:
      return "修改"
    case .deleted:
      return "删除"
    case .renamed:
      return "重命名"
    case .untracked:
      return "未跟踪"
    case .other:
      return "其他"
    }
  }
}

public struct RepositoryChangedFile: Identifiable, Codable, Hashable, Sendable {
  public var id: String { status + path }
  public var status: String
  public var path: String
  public var kind: RepositoryChangeKind
  public var lineDiff: String?

  public init(
    status: String,
    path: String,
    kind: RepositoryChangeKind,
    lineDiff: String? = nil
  ) {
    self.status = status
    self.path = path
    self.kind = kind
    self.lineDiff = lineDiff
  }

  public var displayPath: String {
    path.components(separatedBy: " -> ").last?.trimmedForPublishing ?? path.trimmedForPublishing
  }
}

public struct RepositoryFileSnapshot: Codable, Hashable, Sendable {
  public var refName: String
  public var repositoryPath: String
  public var repositorySHA: String?
  public var content: String

  public init(
    refName: String,
    repositoryPath: String,
    content: String,
    repositorySHA: String? = nil
  ) {
    self.refName = refName
    self.repositoryPath = repositoryPath
    self.content = content
    self.repositorySHA = repositorySHA
  }
}

public enum RepositoryFetchStatus: String, Codable, Hashable, Sendable {
  case succeeded
  case skipped
  case failed
}

public struct RepositoryFetchResult: Codable, Hashable, Sendable {
  public var status: RepositoryFetchStatus
  public var remoteName: String?
  public var upstreamName: String?
  public var message: String

  public init(
    status: RepositoryFetchStatus,
    remoteName: String?,
    upstreamName: String?,
    message: String
  ) {
    self.status = status
    self.remoteName = remoteName
    self.upstreamName = upstreamName
    self.message = message
  }
}

public enum RepositoryChangedFileRole: String, Codable, CaseIterable, Sendable {
  case article
  case image
  case configuration
  case other

  public var displayName: String {
    switch self {
    case .article:
      return "文章"
    case .image:
      return "图片"
    case .configuration:
      return "配置"
    case .other:
      return "其他"
    }
  }

  public var queueTitle: String {
    switch self {
    case .article:
      return "文章变更"
    case .image:
      return "图片变更"
    case .configuration:
      return "配置变更"
    case .other:
      return "其他变更"
    }
  }

  public var systemImage: String {
    switch self {
    case .article:
      return "doc.text"
    case .image:
      return "photo"
    case .configuration:
      return "gearshape"
    case .other:
      return "ellipsis.circle"
    }
  }

  public var isPublishRelevant: Bool {
    switch self {
    case .article, .image, .configuration:
      return true
    case .other:
      return false
    }
  }
}

public struct RepositoryChangeQueueSection: Identifiable, Codable, Hashable, Sendable {
  public var id: String { role.rawValue }
  public var role: RepositoryChangedFileRole
  public var files: [RepositoryChangedFile]

  public init(role: RepositoryChangedFileRole, files: [RepositoryChangedFile]) {
    self.role = role
    self.files = files
  }

  public var title: String {
    role.queueTitle
  }

  public var subtitle: String {
    role.isPublishRelevant ? "会影响发布输出" : "不直接影响文章发布"
  }

  public var count: Int {
    files.count
  }
}

public struct RepositoryChangeSummary: Codable, Hashable, Sendable {
  public var articleCount: Int
  public var imageCount: Int
  public var configurationCount: Int
  public var otherCount: Int

  public init(
    articleCount: Int,
    imageCount: Int,
    configurationCount: Int,
    otherCount: Int
  ) {
    self.articleCount = articleCount
    self.imageCount = imageCount
    self.configurationCount = configurationCount
    self.otherCount = otherCount
  }

  public var totalCount: Int {
    articleCount + imageCount + configurationCount + otherCount
  }

  public var publishRelevantCount: Int {
    articleCount + imageCount + configurationCount
  }

  public func count(for role: RepositoryChangedFileRole) -> Int {
    switch role {
    case .article:
      return articleCount
    case .image:
      return imageCount
    case .configuration:
      return configurationCount
    case .other:
      return otherCount
    }
  }
}

public struct RepositoryBranchStatus: Codable, Hashable, Sendable {
  public var branchName: String?
  public var upstreamName: String?
  public var aheadCount: Int
  public var behindCount: Int
  public var isDetached: Bool

  public init(
    branchName: String?,
    upstreamName: String?,
    aheadCount: Int = 0,
    behindCount: Int = 0,
    isDetached: Bool = false
  ) {
    self.branchName = branchName
    self.upstreamName = upstreamName
    self.aheadCount = aheadCount
    self.behindCount = behindCount
    self.isDetached = isDetached
  }

  public var displayName: String {
    if isDetached {
      return "Detached HEAD"
    }
    return branchName ?? "未识别分支"
  }

  public var syncStatusTitle: String {
    if upstreamName == nil {
      return "未设置上游分支"
    }
    if aheadCount == 0 && behindCount == 0 {
      return "已与远端同步"
    }
    if aheadCount > 0 && behindCount > 0 {
      return "本地领先 \(aheadCount)，落后 \(behindCount)"
    }
    if aheadCount > 0 {
      return "本地领先 \(aheadCount)"
    }
    return "落后远端 \(behindCount)"
  }
}

public struct RepositoryBranch: Identifiable, Codable, Hashable, Sendable {
  public var id: String { name }
  public var name: String
  public var isCurrent: Bool
  public var upstreamName: String?

  public init(name: String, isCurrent: Bool = false, upstreamName: String? = nil) {
    self.name = name
    self.isCurrent = isCurrent
    self.upstreamName = upstreamName
  }
}

public struct RepositoryCommitInfo: Identifiable, Codable, Hashable, Sendable {
  public var id: String { sha }
  public var sha: String
  public var shortSHA: String
  public var author: String
  public var date: Date
  public var message: String

  public init(sha: String, shortSHA: String, author: String, date: Date, message: String) {
    self.sha = sha
    self.shortSHA = shortSHA
    self.author = author
    self.date = date
    self.message = message
  }
}

public enum LocalRepositoryServiceError: Error, LocalizedError, Sendable {
  case repositoryUnavailable
  case invalidBranchName
  case workingTreeHasChanges
  case commandFailed(terminated: Int32, output: String)

  public var errorDescription: String? {
    switch self {
    case .repositoryUnavailable:
      return "未找到可用的本地仓库路径。"
    case .invalidBranchName:
      return "分支名无效。"
    case .workingTreeHasChanges:
      return "工作区存在未提交变更。请先提交、暂存处理或还原这些变更，再切换分支。"
    case .commandFailed(let terminated, let output):
      let normalizedOutput = output.isEmpty ? "请检查分支与权限设置。" : output
      return "Git 命令执行失败（退出码：\(terminated)）：\(normalizedOutput)"
    }
  }
}

public struct RepositoryRemote: Codable, Hashable, Sendable {
  public var remoteURL: String
  public var provider: RepositoryProvider
  public var repositoryBaseURL: String
  public var owner: String
  public var name: String

  public init(
    remoteURL: String,
    provider: RepositoryProvider,
    repositoryBaseURL: String,
    owner: String,
    name: String
  ) {
    self.remoteURL = remoteURL
    self.provider = provider
    self.repositoryBaseURL = repositoryBaseURL
    self.owner = owner
    self.name = name
  }

  public var displayName: String {
    "\(provider.displayName) \(owner)/\(name)"
  }
}

private struct RepositoryGitStatus {
  var branchStatus: RepositoryBranchStatus?
  var changedFiles: [RepositoryChangedFile]
  var remoteChangedFiles: [RepositoryChangedFile]
}

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
    let assetRoot = assetRoot.normalizedRelativePath()
    let pathExtension = (normalizedPath as NSString).pathExtension.lowercased()

    if isWithin(normalizedPath, root: contentRoot), ["md", "markdown", "mdx"].contains(pathExtension) {
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

private extension PreflightIssue {
  var isDeploymentReadinessIssue: Bool {
    switch field {
    case "siteKind", "contentRoot", "assetRoot":
      return true
    default:
      return false
    }
  }
}

public struct LocalRepositoryService: @unchecked Sendable {
  private let fileManager: FileManager
  private let gitCommandRunner: GitCommandRunner

  public init(
    fileManager: FileManager = .default,
    gitCommandRunner: GitCommandRunner = GitCommandRunner()
  ) {
    self.fileManager = fileManager
    self.gitCommandRunner = gitCommandRunner
  }

  public func scan(profile: SiteProfile) -> RepositoryScanReport {
    guard let report = profile.withLocalRepositoryRootAccess({ rootURL in
      scan(rootURL: rootURL, profile: profile)
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
          .init(severity: .warning, title: "未选择本地仓库", message: "请选择 Zola/Hugo/Astro/Jekyll/Hexo 仓库根目录。", field: "repository")
        ]
      )
    }

    return report
  }

  public func hasGitIgnoreFile(profile: SiteProfile) -> Bool {
    guard let result = profile.withLocalRepositoryRootAccess({ rootURL in
      fileManager.fileExists(atPath: rootURL.appendingPathComponent(".gitignore").path)
    }) else {
      return false
    }
    return result
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

  public func createLocalBranch(profile: SiteProfile, branchName: String, from sourceBranch: String?) throws {
    let branchName = branchName.trimmedForPublishing
    guard isValidBranchName(branchName) else {
      throw LocalRepositoryServiceError.invalidBranchName
    }

    let sourceBranch = sourceBranch?.trimmedForPublishing.nilIfEmpty
    if let sourceBranch, !isValidBranchName(sourceBranch) {
      throw LocalRepositoryServiceError.invalidBranchName
    }
    guard let result = profile.withLocalRepositoryRootAccess({ rootURL in
      var arguments = ["branch", branchName]
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
    guard result.output.trimmedForPublishing.isEmpty else {
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

  private func scan(rootURL: URL, profile: SiteProfile) -> RepositoryScanReport {
    let rootPath = rootURL.path
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
      return RepositoryScanReport(
        rootPath: rootPath,
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
          .init(severity: .error, title: "仓库路径不可读", message: rootPath, field: "repository")
        ]
      )
    }

    let contentRootURL = rootURL.appendingPathComponent(profile.contentRoot.normalizedRelativePath(), isDirectory: true)
    let assetRootURL = rootURL.appendingPathComponent(profile.assetRoot.normalizedRelativePath(), isDirectory: true)
    let contentRootExists = directoryExists(contentRootURL)
    let assetRootExists = directoryExists(assetRootURL)
    let detectedKind = detectSiteKind(rootURL: rootURL)
    let hasGitDirectory = directoryExists(rootURL.appendingPathComponent(".git", isDirectory: true))
    let gitStatus = hasGitDirectory
      ? gitStatus(rootURL: rootURL)
      : RepositoryGitStatus(branchStatus: nil, changedFiles: [], remoteChangedFiles: [])
    let originRemote = hasGitDirectory ? gitOriginRemote(rootURL: rootURL) : nil

    var issues: [PreflightIssue] = []
    if detectedKind == nil {
      issues.append(.init(severity: .warning, title: "未识别静态站点类型", message: "没有发现常见配置文件；仍可继续使用自定义路径规则。", field: "siteKind"))
    } else if detectedKind != profile.siteKind {
      issues.append(.init(severity: .warning, title: "站点类型可能不一致", message: "配置为 \(profile.siteKind.displayName)，扫描到 \(detectedKind?.displayName ?? "未知")。", field: "siteKind"))
    }

    if !hasGitDirectory {
      issues.append(.init(severity: .warning, title: "未发现 .git", message: "当前目录不是 Git 工作树，diff 和提交入口暂不可用。", field: "repository"))
    } else {
      issues.append(contentsOf: branchSyncIssues(gitStatus.branchStatus))
    }

    if !contentRootExists {
      issues.append(.init(severity: .error, title: "内容目录不存在", message: profile.contentRoot, field: "contentRoot"))
    }

    if !assetRootExists {
      issues.append(.init(severity: .warning, title: "图片目录不存在", message: profile.assetRoot, field: "assetRoot"))
    }

    return RepositoryScanReport(
      rootPath: rootPath,
      detectedKind: detectedKind,
      expectedKind: profile.siteKind,
      hasGitDirectory: hasGitDirectory,
      contentRootExists: contentRootExists,
      assetRootExists: assetRootExists,
      markdownFileCount: contentRootExists ? countFiles(in: contentRootURL, extensions: ["md", "markdown", "mdx"]) : 0,
      imageFileCount: assetRootExists ? countFiles(in: assetRootURL, extensions: ImageFileSupport.supportedExtensions) : 0,
      branchStatus: gitStatus.branchStatus,
      originRemote: originRemote,
      changedFiles: gitStatus.changedFiles,
      remoteChangedFiles: gitStatus.remoteChangedFiles,
      preflightIssues: issues
    )
  }

  private func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  private func fileExists(_ url: URL) -> Bool {
    fileManager.fileExists(atPath: url.path)
  }

  private func detectSiteKind(rootURL: URL) -> SiteKind? {
    if fileExists(rootURL.appendingPathComponent("astro.config.mjs"))
      || fileExists(rootURL.appendingPathComponent("astro.config.ts"))
      || directoryExists(rootURL.appendingPathComponent("src/content", isDirectory: true)) {
      return .astro
    }

    if fileExists(rootURL.appendingPathComponent("hugo.toml"))
      || fileExists(rootURL.appendingPathComponent("hugo.yaml"))
      || fileExists(rootURL.appendingPathComponent("hugo.json")) {
      return .hugo
    }

    if fileExists(rootURL.appendingPathComponent("config.toml"))
      && directoryExists(rootURL.appendingPathComponent("content", isDirectory: true)) {
      return .zola
    }

    if fileExists(rootURL.appendingPathComponent("_config.yml")) {
      return fileExists(rootURL.appendingPathComponent("package.json")) ? .hexo : .jekyll
    }

    return nil
  }

  private func countFiles(in rootURL: URL, extensions allowedExtensions: Set<String>) -> Int {
    guard let enumerator = fileManager.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return 0
    }

    var count = 0
    for case let fileURL as URL in enumerator {
      guard allowedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
      count += 1
    }
    return count
  }

  private func branchSyncIssues(_ branchStatus: RepositoryBranchStatus?) -> [PreflightIssue] {
    guard let branchStatus else {
      return [
        .init(
          severity: .warning,
          title: "未识别 Git 分支",
          message: "无法读取当前分支同步状态；发布前建议在终端确认 git status。",
          field: "repository"
        )
      ]
    }

    if branchStatus.isDetached {
      return [
        .init(
          severity: .error,
          title: "当前是 Detached HEAD",
          message: "请切回可发布分支后再写入、提交或创建 PR/MR。",
          field: "repository"
        )
      ]
    }

    guard branchStatus.upstreamName != nil else {
      return [
        .init(
          severity: .info,
          title: "未设置上游分支",
          message: "可以继续本地写入；创建 PR/MR 或判断远端差异前建议设置 upstream。",
          field: "repository"
        )
      ]
    }

    if branchStatus.aheadCount > 0 && branchStatus.behindCount > 0 {
      return [
        .init(
          severity: .warning,
          title: "本地分支与远端分叉",
          message: "\(branchStatus.displayName) 本地领先 \(branchStatus.aheadCount)，落后 \(branchStatus.behindCount)；发布前建议先同步远端变更。",
          field: "repository"
        )
      ]
    }

    if branchStatus.behindCount > 0 {
      return [
        .init(
          severity: .warning,
          title: "本地分支落后远端",
          message: "\(branchStatus.displayName) 落后远端 \(branchStatus.behindCount) 个提交；发布前建议先拉取最新站点内容。",
          field: "repository"
        )
      ]
    }

    return []
  }

  private func gitStatus(rootURL: URL) -> RepositoryGitStatus {
    let result = gitCommandRunner.run(["status", "--porcelain=v1", "--branch"], rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      return RepositoryGitStatus(branchStatus: nil, changedFiles: [], remoteChangedFiles: [])
    }

    let output = result.output
    guard !output.isEmpty else {
      return RepositoryGitStatus(branchStatus: nil, changedFiles: [], remoteChangedFiles: [])
    }

    var branchStatus: RepositoryBranchStatus?
    var changedFiles: [RepositoryChangedFile] = []

    for line in output.split(separator: "\n").map(String.init) {
      if line.hasPrefix("## ") {
        branchStatus = parseBranchStatusLine(line)
        continue
      }

      guard line.count >= 4 else { continue }
      let status = String(line.prefix(2))
      let pathStart = line.index(line.startIndex, offsetBy: 3)
      let path = String(line[pathStart...])
      let kind = changeKind(status: status)
      var changedFile = RepositoryChangedFile(status: status, path: path, kind: kind)
      changedFile.lineDiff = diffForChangedFile(changedFile, rootURL: rootURL)
      changedFiles.append(changedFile)
    }

    let remoteChangedFiles = branchStatus?.upstreamName.flatMap {
      self.remoteChangedFiles(rootURL: rootURL, upstreamName: $0)
    } ?? []

    return RepositoryGitStatus(
      branchStatus: branchStatus,
      changedFiles: changedFiles,
      remoteChangedFiles: remoteChangedFiles
    )
  }

  private func remoteChangedFiles(rootURL: URL, upstreamName: String) -> [RepositoryChangedFile] {
    guard let output = runGitOutput(
      ["diff", "--name-status", "HEAD...\(upstreamName)", "--"],
      rootURL: rootURL
    ) else {
      return []
    }

    return parseNameStatus(output).map { file in
      var changedFile = file
      changedFile.lineDiff = remoteDiffForChangedFile(file, upstreamName: upstreamName, rootURL: rootURL)
      return changedFile
    }
  }

  private func remoteDiffForChangedFile(
    _ file: RepositoryChangedFile,
    upstreamName: String,
    rootURL: URL
  ) -> String? {
    runGitDiff(["diff", "HEAD...\(upstreamName)", "--", file.displayPath], rootURL: rootURL)
  }

  private func remoteFileSnapshot(
    rootURL: URL,
    repositoryPath: String,
    repositoryProvider: RepositoryProvider
  ) -> RepositoryFileSnapshot? {
    let status = gitStatus(rootURL: rootURL)
    guard let upstreamName = status.branchStatus?.upstreamName?.nilIfEmpty,
          let safePath = safeRepositoryFilePath(repositoryPath),
          let content = runGitOutput(["show", "\(upstreamName):\(safePath)"], rootURL: rootURL) else {
      return nil
    }
    let repositorySHA = remoteFileVersionSHA(
      rootURL: rootURL,
      upstreamName: upstreamName,
      repositoryPath: safePath,
      repositoryProvider: repositoryProvider
    )

    return RepositoryFileSnapshot(
      refName: upstreamName,
      repositoryPath: safePath,
      content: content,
      repositorySHA: repositorySHA
    )
  }

  private func remoteFileVersionSHA(
    rootURL: URL,
    upstreamName: String,
    repositoryPath: String,
    repositoryProvider: RepositoryProvider
  ) -> String? {
    switch repositoryProvider {
    case .github:
      return runGitOutput(["rev-parse", "\(upstreamName):\(repositoryPath)"], rootURL: rootURL)?
        .trimmedForPublishing
        .nilIfEmpty
    case .gitlab:
      return runGitOutput(["log", "-n", "1", "--format=%H", upstreamName, "--", repositoryPath], rootURL: rootURL)?
        .trimmedForPublishing
        .nilIfEmpty
    }
  }

  private func safeRepositoryFilePath(_ repositoryPath: String) -> String? {
    let displayPath = repositoryPath.components(separatedBy: " -> ").last?.trimmedForPublishing ?? repositoryPath.trimmedForPublishing
    guard !displayPath.isEmpty,
          !displayPath.hasPrefix("/"),
          !displayPath.contains("\\"),
          !displayPath.contains("://") else {
      return nil
    }

    let normalizedPath = displayPath.normalizedRelativePath()
    guard !normalizedPath.isEmpty,
          !normalizedPath.split(separator: "/").contains("..") else {
      return nil
    }

    return normalizedPath
  }

  private func parseNameStatus(_ output: String) -> [RepositoryChangedFile] {
    output.split(separator: "\n").compactMap { line -> RepositoryChangedFile? in
      let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard let status = parts.first?.nilIfEmpty, parts.count >= 2 else {
        return nil
      }

      let path: String
      if status.hasPrefix("R"), parts.count >= 3 {
        path = "\(parts[1]) -> \(parts[2])"
      } else {
        path = parts[1]
      }

      return RepositoryChangedFile(status: status, path: path, kind: changeKind(status: status))
    }
  }

  private func gitOriginRemote(rootURL: URL) -> RepositoryRemote? {
    guard let remoteURL = runGitOutput(["remote", "get-url", "origin"], rootURL: rootURL)?
      .trimmedForPublishing
      .nilIfEmpty else {
      return nil
    }

    return parseRepositoryRemote(remoteURL)
  }

  private func fetchUpstream(rootURL: URL) -> RepositoryFetchResult {
    let status = gitStatus(rootURL: rootURL)
    guard let upstreamName = status.branchStatus?.upstreamName?.nilIfEmpty else {
      return RepositoryFetchResult(
        status: .skipped,
        remoteName: nil,
        upstreamName: nil,
        message: "当前分支未设置 upstream，跳过远端 fetch。"
      )
    }
    guard let remoteName = remoteName(fromUpstreamName: upstreamName) else {
      return RepositoryFetchResult(
        status: .skipped,
        remoteName: nil,
        upstreamName: upstreamName,
        message: "无法从 upstream \(upstreamName) 识别 remote 名称，跳过远端 fetch。"
      )
    }

    let result = runGitCommand(["fetch", "--prune", remoteName], rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      let detail = result.output.nilIfEmpty.map { "：\($0)" } ?? ""
      return RepositoryFetchResult(
        status: .failed,
        remoteName: remoteName,
        upstreamName: upstreamName,
        message: "fetch \(remoteName) 失败\(detail)"
      )
    }

    return RepositoryFetchResult(
      status: .succeeded,
      remoteName: remoteName,
      upstreamName: upstreamName,
      message: "已 fetch \(remoteName)，upstream \(upstreamName) 已刷新。"
    )
  }

  private func remoteName(fromUpstreamName upstreamName: String) -> String? {
    let trimmed = upstreamName.trimmedForPublishing
    guard !trimmed.isEmpty,
          !trimmed.hasPrefix("/"),
          !trimmed.contains("\\"),
          !trimmed.contains(".."),
          !trimmed.contains("://"),
          let slashIndex = trimmed.firstIndex(of: "/") else {
      return nil
    }
    let remote = String(trimmed[..<slashIndex]).trimmedForPublishing
    guard !remote.isEmpty,
          remote.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
      return nil
    }
    return remote
  }

  private func localBranches(rootURL: URL) -> [RepositoryBranch] {
    guard let output = runGitOutput(["branch", "--format=%(refname:short)|%(HEAD)|%(upstream:short)"], rootURL: rootURL) else {
      return []
    }

    let branches = output
      .split(separator: "\n")
      .compactMap { parseBranchListLine(String($0)) }

    if branches.contains(where: { $0.isCurrent }) {
      return branches
    }

    if let current = runGitOutput(["branch", "--show-current"], rootURL: rootURL)?.trimmedForPublishing,
       let index = branches.firstIndex(where: { $0.name == current }) {
      var withCurrent = branches
      withCurrent[index].isCurrent = true
      return withCurrent
    }

    return branches
  }

  private func parseBranchListLine(_ line: String) -> RepositoryBranch? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    let parts = trimmed.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    guard let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
      return nil
    }

    let head = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let upstream = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty : nil
    let isCurrent = head == "*"
    return RepositoryBranch(name: name, isCurrent: isCurrent, upstreamName: upstream)
  }

  private func recentCommits(rootURL: URL, limit: Int) -> [RepositoryCommitInfo] {
    let format = "%H\t%an\t%ad\t%s"
    guard let output = runGitOutput(
      ["log", "-n", "\(limit)", "--date=iso", "--pretty=format:\(format)"],
      rootURL: rootURL
    ) else {
      return []
    }

    return output
      .split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap { parseRecentCommitLine(String($0)) }
  }

  private func parseRecentCommitLine(_ line: String) -> RepositoryCommitInfo? {
    let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 4 else {
      return nil
    }

    let sha = parts[0].trimmedForPublishing
    let author = parts[1].trimmedForPublishing
    let dateText = parts[2].trimmedForPublishing
    let message = parts[3].trimmedForPublishing

    guard !sha.isEmpty, !author.isEmpty, !message.isEmpty else {
      return nil
    }

    return RepositoryCommitInfo(
      sha: sha,
      shortSHA: String(sha.prefix(8)),
      author: author,
      date: parseGitDate(dateText),
      message: message
    )
  }

  private func parseGitDate(_ text: String) -> Date {
    let trimmedText = text.trimmedForPublishing
    guard !trimmedText.isEmpty else {
      return Date()
    }

    let strictISO8601 = ISO8601DateFormatter()
    strictISO8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = strictISO8601.date(from: trimmedText) {
      return date
    }

    strictISO8601.formatOptions = [.withInternetDateTime]
    if let date = strictISO8601.date(from: trimmedText) {
      return date
    }

    return Date()
  }

  private func ignoredRepositoryPaths(rootURL: URL, paths: [String]) -> [String] {
    let result = runGitCommand(["check-ignore", "--stdin", "-z"], rootURL: rootURL, inputLines: paths)
    guard result.terminationStatus == 0 || result.terminationStatus == 1 else {
      return []
    }

    let output = result.output
    guard !output.isEmpty else {
      return []
    }

    return output
      .split(separator: "\0")
      .map { String($0) }
      .filter { !$0.isEmpty }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private func runGitCommand(
    _ arguments: [String],
    rootURL: URL,
    inputLines: [String]? = nil
  ) -> (terminationStatus: Int32, output: String) {
    let result = gitCommandRunner.run(arguments, rootURL: rootURL, inputLines: inputLines)
    return (result.terminationStatus, result.output)
  }

  private func runGitOutput(_ arguments: [String], rootURL: URL) -> String? {
    let result = gitCommandRunner.run(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      return nil
    }
    return result.output
  }

  private func parseRepositoryRemote(_ remoteURL: String) -> RepositoryRemote? {
    let trimmed = remoteURL.trimmedForPublishing
    guard let remotePath = remotePathComponents(from: trimmed) else {
      return nil
    }

    let pathComponents = remotePath.path
      .split(separator: "/")
      .map(String.init)
      .filter { !$0.isEmpty }
    guard pathComponents.count >= 2,
          let provider = repositoryProvider(forHost: remotePath.host) else {
      return nil
    }

    var repositoryName = pathComponents.last ?? ""
    if repositoryName.hasSuffix(".git") {
      repositoryName.removeLast(4)
    }
    let owner = pathComponents.dropLast().joined(separator: "/")
    guard !owner.isEmpty, !repositoryName.isEmpty else {
      return nil
    }

    return RepositoryRemote(
      remoteURL: sanitizedRepositoryRemoteURL(
        trimmed,
        host: remotePath.host,
        path: remotePath.path
      ),
      provider: provider,
      repositoryBaseURL: repositoryBaseURL(provider: provider, host: remotePath.host),
      owner: owner,
      name: repositoryName
    )
  }

  private func remotePathComponents(from remoteURL: String) -> (host: String, path: String)? {
    if !remoteURL.contains("://"),
       let colonIndex = scpHostPathSeparator(in: remoteURL) {
      let hostPart = String(remoteURL[..<colonIndex])
      let host = hostPart.components(separatedBy: "@").last ?? hostPart
      let pathStart = remoteURL.index(after: colonIndex)
      return (host: host, path: String(remoteURL[pathStart...]))
    }

    guard let url = URL(string: remoteURL),
          let host = url.host?.nilIfEmpty else {
      return nil
    }
    return (host: host, path: url.path)
  }

  private func scpHostPathSeparator(in remoteURL: String) -> String.Index? {
    let searchStart = remoteURL.lastIndex(of: "@").map { remoteURL.index(after: $0) }
      ?? remoteURL.startIndex
    return remoteURL[searchStart...].firstIndex(of: ":")
  }

  private func sanitizedRepositoryRemoteURL(
    _ remoteURL: String,
    host: String,
    path: String
  ) -> String {
    if remoteURL.contains("://"), var components = URLComponents(string: remoteURL) {
      components.user = nil
      components.password = nil
      components.query = nil
      components.fragment = nil
      if let sanitized = components.string?.nilIfEmpty {
        return sanitized
      }
    }

    // SCP-style remotes have no standard URL representation. Retain only the
    // host and repository path so usernames, passwords, and token-like user
    // fields can never reach the model or selectable UI text.
    return "\(host):\(path)"
  }

  private func repositoryProvider(forHost host: String) -> RepositoryProvider? {
    let lowercaseHost = host.lowercased()
    if lowercaseHost.contains("github") {
      return .github
    }
    if lowercaseHost.contains("gitlab") {
      return .gitlab
    }
    return nil
  }

  private func repositoryBaseURL(provider: RepositoryProvider, host: String) -> String {
    switch provider {
    case .github:
      return host.lowercased() == "github.com" ? RepositoryProvider.github.defaultBaseURL : "https://\(host)"
    case .gitlab:
      return "https://\(host)"
    }
  }

  private func parseBranchStatusLine(_ line: String) -> RepositoryBranchStatus? {
    let text = line.replacingOccurrences(of: "## ", with: "")
    if text.hasPrefix("HEAD ") || text == "HEAD (no branch)" {
      return RepositoryBranchStatus(branchName: nil, upstreamName: nil, isDetached: true)
    }

    if text.hasPrefix("No commits yet on ") {
      let branch = text.replacingOccurrences(of: "No commits yet on ", with: "")
      return RepositoryBranchStatus(branchName: branch.nilIfEmpty, upstreamName: nil)
    }

    let parts = text.components(separatedBy: "...")
    guard let branchName = parts.first?.nilIfEmpty else {
      return nil
    }

    guard parts.count > 1 else {
      return RepositoryBranchStatus(branchName: branchName, upstreamName: nil)
    }

    let upstreamAndSync = parts[1]
    if let bracketStart = upstreamAndSync.firstIndex(of: "[") {
      let upstream = String(upstreamAndSync[..<bracketStart]).trimmedForPublishing.nilIfEmpty
      let syncText = String(upstreamAndSync[bracketStart...])
      return RepositoryBranchStatus(
        branchName: branchName,
        upstreamName: upstream,
        aheadCount: parseSyncCount(label: "ahead", in: syncText),
        behindCount: parseSyncCount(label: "behind", in: syncText)
      )
    }

    return RepositoryBranchStatus(
      branchName: branchName,
      upstreamName: upstreamAndSync.trimmedForPublishing.nilIfEmpty
    )
  }

  private func parseSyncCount(label: String, in text: String) -> Int {
    let pattern = #"\#(label) ([0-9]+)"#
    guard
      let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
      let range = Range(match.range(at: 1), in: text)
    else {
      return 0
    }
    return Int(text[range]) ?? 0
  }

  private func changeKind(status: String) -> RepositoryChangeKind {
    if status == "??" { return .untracked }
    if status.contains("A") { return .added }
    if status.contains("M") { return .modified }
    if status.contains("D") { return .deleted }
    if status.contains("R") { return .renamed }
    return .other
  }

  private func diffForChangedFile(_ file: RepositoryChangedFile, rootURL: URL) -> String? {
    if file.kind == .untracked {
      return runGitDiff(["diff", "--no-index", "--", "/dev/null", file.displayPath], rootURL: rootURL)
    }

    let stagedDiff = runGitDiff(["diff", "--cached", "--", file.displayPath], rootURL: rootURL)
    let unstagedDiff = runGitDiff(["diff", "--", file.displayPath], rootURL: rootURL)
    let combined = [stagedDiff, unstagedDiff]
      .compactMap { $0?.trimmedForPublishing.nilIfEmpty }
      .joined(separator: "\n")
    return limitedDiff(combined)
  }

  private func runGitDiff(_ arguments: [String], rootURL: URL) -> String? {
    let result = gitCommandRunner.run(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 || result.terminationStatus == 1 else {
      return nil
    }
    return limitedDiff(result.output)
  }

  private func limitedDiff(_ diff: String) -> String? {
    let trimmed = diff.trimmedForPublishing
    guard !trimmed.isEmpty else {
      return nil
    }

    let maxLineCount = 160
    let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.count > maxLineCount else {
      return trimmed
    }

    return (Array(lines.prefix(maxLineCount)) + ["... diff 已截断，仅显示前 \(maxLineCount) 行 ..."])
      .joined(separator: "\n")
  }
}
