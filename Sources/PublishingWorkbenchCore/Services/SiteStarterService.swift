import Foundation

public struct SiteStarterService: Sendable {
  typealias CreateSiteOperation = @Sendable (SiteStarterRequest) throws -> SiteStarterResult
  typealias ImportExistingSiteOperation = @Sendable (SiteStarterImportRequest) throws -> SiteStarterImportResult

  private let fileSystem: SendableFileManager
  let gitCommandRunner: GitCommandRunner
  private let createSiteOperation: CreateSiteOperation?
  private let importExistingSiteOperation: ImportExistingSiteOperation?

  var fileManager: FileManager { fileSystem.value }

  public init(
    fileManager: FileManager = .default,
    gitCommandRunner: GitCommandRunner = GitCommandRunner(timeout: 60)
  ) {
    self.fileSystem = SendableFileManager(fileManager)
    self.gitCommandRunner = gitCommandRunner
    self.createSiteOperation = nil
    self.importExistingSiteOperation = nil
  }

  /// Test seam for deterministic scheduling checks. Production callers use
  /// the public initializer above and execute the real file-system workflow.
  init(
    fileManager: FileManager = .default,
    gitCommandRunner: GitCommandRunner = GitCommandRunner(timeout: 60),
    createSiteOperation: @escaping CreateSiteOperation,
    importExistingSiteOperation: ImportExistingSiteOperation? = nil
  ) {
    self.fileSystem = SendableFileManager(fileManager)
    self.gitCommandRunner = gitCommandRunner
    self.createSiteOperation = createSiteOperation
    self.importExistingSiteOperation = importExistingSiteOperation
  }

  public func createSite(request: SiteStarterRequest) throws -> SiteStarterResult {
    if let createSiteOperation {
      return try createSiteOperation(request)
    }
    let template = try template(for: request.templateID)
    let rootURL = URL(fileURLWithPath: request.rootPath, isDirectory: true).standardizedFileURL
    let siteName = request.siteName.trimmedForPublishing.nilIfEmpty ?? "我的网站"
    let author = request.author.trimmedForPublishing
    let description = request.siteDescription.trimmedForPublishing.nilIfEmpty ?? "\(siteName) 的个人网站"
    let branch = request.branch.trimmedForPublishing.nilIfEmpty ?? "main"
    let repoName = request.githubRepositoryName.trimmedForPublishing.nilIfEmpty ?? slug(from: siteName)
    let owner = request.githubOwner.trimmedForPublishing
    let baseURL = normalizedBaseURL(request.baseURL, owner: owner, repoName: repoName)

    try prepareRootDirectory(rootURL)

    var profile = SiteProfile(
      name: siteName,
      purpose: .publishing,
      repositoryProvider: .github,
      repositoryBaseURL: RepositoryProvider.github.defaultBaseURL,
      repoOwner: owner,
      repoName: repoName,
      branch: branch,
      repositoryPublishStrategy: .direct,
      defaultAuthor: author,
      defaultTags: template.defaultTags,
      defaultCategories: template.defaultCategories
    )
    profile.applyPublishingDefaults(for: template.siteKind)
    profile.rememberLocalRepositoryRoot(rootURL)
    applyDeploymentConfiguration(
      to: &profile,
      target: request.deploymentTarget,
      siteURL: request.deploymentSiteURL.nilIfEmpty ?? baseURL,
      projectID: request.deploymentProjectID,
      accountID: request.deploymentAccountID
    )

    let draft = starterDraft(profile: profile, siteName: siteName, author: author, now: request.now)
    let files = starterFiles(
      profile: profile,
      draft: draft,
      template: template,
      siteName: siteName,
      description: description,
      author: author,
      baseURL: baseURL,
      deploymentTarget: request.deploymentTarget
    )

    var createdPaths: [String] = []
    for file in files {
      try write(file, under: rootURL)
      createdPaths.append(file.path)
    }

    var initializedGit = false
    if request.initializeGit {
      try initializeGitRepository(at: rootURL, branch: branch)
      initializedGit = true
    }

    let remoteURL = githubRemoteURL(owner: owner, repoName: repoName)
    if request.initializeGit, request.configureOriginRemote, let remoteURL {
      try addOriginRemote(remoteURL, at: rootURL)
    }

    return SiteStarterResult(
      profile: profile,
      initialDraft: draft,
      createdFilePaths: createdPaths.sorted(),
      initializedGit: initializedGit,
      configuredRemoteURL: request.configureOriginRemote ? remoteURL : nil,
      deploymentGuidePath: createdPaths.contains("DEPLOYMENT.md") ? "DEPLOYMENT.md" : nil,
      nextCommands: nextCommands(
        rootURL: rootURL,
        branch: branch,
        owner: owner,
        repoName: repoName,
        remoteURL: remoteURL,
        createdFilePaths: createdPaths
      )
    )
  }

  public func importExistingSite(request: SiteStarterImportRequest) throws -> SiteStarterImportResult {
    if let importExistingSiteOperation {
      return try importExistingSiteOperation(request)
    }
    let rootURL = URL(fileURLWithPath: request.rootPath, isDirectory: true).standardizedFileURL
    try validateExistingRootDirectory(rootURL)

    let detectedRemoteURL = optionalGitOutput(["remote", "get-url", "origin"], at: rootURL)
      .map(GitCommandRunner.redactedDiagnosticText)
    let detectedBranch = optionalGitOutput(["branch", "--show-current"], at: rootURL)
    let parsedRemote = detectedRemoteURL.flatMap(parseGitHubRemote)
    let siteName = request.siteName.trimmedForPublishing.nilIfEmpty
      ?? parsedRemote?.repo
      ?? rootURL.lastPathComponent
    let repoName = request.githubRepositoryName.trimmedForPublishing.nilIfEmpty
      ?? parsedRemote?.repo
      ?? slug(from: siteName)
    let owner = request.githubOwner.trimmedForPublishing.nilIfEmpty
      ?? parsedRemote?.owner
      ?? ""
    let branch = request.branch.trimmedForPublishing.nilIfEmpty
      ?? detectedBranch?.nilIfEmpty
      ?? "main"

    var profile = SiteProfile(
      name: siteName,
      purpose: .publishing,
      repositoryProvider: .github,
      repositoryBaseURL: RepositoryProvider.github.defaultBaseURL,
      repoOwner: owner,
      repoName: repoName,
      branch: branch,
      repositoryPublishStrategy: .direct,
      defaultAuthor: request.author.trimmedForPublishing
    )
    profile.applyPublishingDefaults(for: request.siteKind)
    profile.rememberLocalRepositoryRoot(rootURL)
    applyDeploymentConfiguration(
      to: &profile,
      target: request.deploymentTarget,
      siteURL: request.deploymentSiteURL,
      projectID: request.deploymentProjectID,
      accountID: request.deploymentAccountID
    )

    return SiteStarterImportResult(
      profile: profile,
      importedDraftCount: 0,
      updatedDraftCount: 0,
      skippedPathCount: 0,
      isGitRepository: fileManager.fileExists(atPath: rootURL.appendingPathComponent(".git", isDirectory: true).path),
      detectedRemoteURL: detectedRemoteURL,
      nextCommands: importedRepositoryNextCommands(rootURL: rootURL, branch: branch, owner: owner, repoName: repoName)
    )
  }

  /// Runs template generation, file writes, and optional Git initialization
  /// away from the main actor. The returned value is immutable and Sendable,
  /// so a store can safely decide on the main actor whether it is still current.
  public func createSiteAsync(request: SiteStarterRequest) async throws -> SiteStarterResult {
    let service = self
    return try await Task.detached(priority: .userInitiated) {
      try service.createSite(request: request)
    }.value
  }

  /// Runs directory validation and Git metadata detection away from the main
  /// actor. Article discovery is also dispatched separately by the store.
  public func importExistingSiteAsync(
    request: SiteStarterImportRequest
  ) async throws -> SiteStarterImportResult {
    let service = self
    return try await Task.detached(priority: .userInitiated) {
      try service.importExistingSite(request: request)
    }.value
  }

  private func prepareRootDirectory(_ rootURL: URL) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw SiteStarterError.rootIsNotDirectory(rootURL.path)
      }
      let existing = try fileManager.contentsOfDirectory(atPath: rootURL.path)
        .filter { $0 != ".DS_Store" }
      guard existing.isEmpty else {
        throw SiteStarterError.rootDirectoryNotEmpty(rootURL.path)
      }
    } else {
      try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
  }

  private func validateExistingRootDirectory(_ rootURL: URL) throws {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw SiteStarterError.rootIsNotDirectory(rootURL.path)
    }
  }

  private func starterDraft(
    profile: SiteProfile,
    siteName: String,
    author: String,
    now: Date
  ) -> ArticleDraft {
    let title = "欢迎来到 \(siteName)"
    let slug = "welcome"
    let body = """
    # \(title)

    这是 \(siteName) 的第一篇内容。你可以在 Mac 版发布控制台里继续编辑正文、补充 Front Matter、插入图片，然后通过发布检查推送到网站。

    ## 下一步

    - 修改这篇文章的标题和摘要
    - 添加封面图和图片 alt
    - 打开本地预览确认效果
    - 通过部署页推送到 GitHub Pages
    """

    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: title,
      date: now,
      slug: slug,
      tags: profile.defaultTags,
      categories: profile.defaultCategories,
      authors: author.isEmpty ? [] : [author],
      draft: false,
      summary: "由 Site Starter 生成的第一篇内容。",
      bodyMarkdown: body
    )
    let repositoryPath = profile.markdownPath(for: draft)
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: repositoryPath,
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    return draft
  }

  private func write(_ file: StarterFile, under rootURL: URL) throws {
    guard isSafeRelativePath(file.path) else {
      throw SiteStarterError.unsafePath(file.path)
    }
    let url = rootURL.appendingPathComponent(file.path)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try file.contents.write(to: url, atomically: true, encoding: .utf8)
  }

  private func applyDeploymentConfiguration(
    to profile: inout SiteProfile,
    target: SiteStarterDeploymentTarget,
    siteURL: String,
    projectID: String,
    accountID: String
  ) {
    profile.deploymentProvider = target.deploymentProvider
    profile.deploymentSiteURL = siteURL.trimmedForPublishing.nilIfEmpty
    profile.deploymentProjectID = projectID.trimmedForPublishing.nilIfEmpty
    profile.deploymentAccountID = accountID.trimmedForPublishing.nilIfEmpty
  }

  private func normalizedBaseURL(_ baseURL: String, owner: String, repoName: String) -> String {
    if let value = baseURL.trimmedForPublishing.nilIfEmpty {
      return value
    }
    guard !owner.isEmpty, !repoName.isEmpty else {
      return "https://example.com"
    }
    return "https://\(owner).github.io/\(repoName)"
  }

  private func slug(from text: String) -> String {
    SlugService.slug(from: text).nilIfEmpty ?? "my-site"
  }
}

public enum SiteStarterError: LocalizedError, Equatable {
  case unknownTemplate(String)
  case rootIsNotDirectory(String)
  case rootDirectoryNotEmpty(String)
  case unsafePath(String)
  case missingRepositoryRoot
  case notGitRepository(String)
  case missingOriginRemote
  case missingStarterFileManifest
  case unrelatedStagedChanges([String])
  case noStarterChanges
  case gitFailed(String)

  public var errorDescription: String? {
    switch self {
    case let .unknownTemplate(templateID):
      return CoreL10n.format("未知站点模板：%@", templateID)
    case let .rootIsNotDirectory(path):
      return CoreL10n.format("目标路径不是文件夹：%@", path)
    case let .rootDirectoryNotEmpty(path):
      return CoreL10n.format("目标文件夹不是空文件夹：%@", path)
    case let .unsafePath(path):
      return CoreL10n.format("模板包含不安全路径：%@", path)
    case .missingRepositoryRoot:
      return CoreL10n.text("当前 Starter 没有本地仓库路径。")
    case let .notGitRepository(path):
      return CoreL10n.format("当前目录不是 Git 仓库：%@", path)
    case .missingOriginRemote:
      return CoreL10n.text("当前 Starter 仓库没有 origin remote。")
    case .missingStarterFileManifest:
      return CoreL10n.text("缺少 Starter 生成文件清单，已停止提交以避免暂存无关文件。")
    case let .unrelatedStagedChanges(paths):
      return CoreL10n.format(
        "暂存区包含 Starter 清单外的文件，已停止提交：%@",
        paths.joined(separator: CoreL10n.text("、"))
      )
    case .noStarterChanges:
      return CoreL10n.text("没有可提交和推送的 Starter 文件变化。")
    case let .gitFailed(message):
      return CoreL10n.format("Git 操作失败：%@", message)
    }
  }
}
