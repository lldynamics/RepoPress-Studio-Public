import Foundation

public struct SiteStarterService: Sendable {
  typealias CreateSiteOperation = @Sendable (SiteStarterRequest) throws -> SiteStarterResult
  typealias ImportExistingSiteOperation = @Sendable (SiteStarterImportRequest) throws -> SiteStarterImportResult

  private let fileSystem: SendableFileManager
  private let gitCommandRunner: GitCommandRunner
  private let createSiteOperation: CreateSiteOperation?
  private let importExistingSiteOperation: ImportExistingSiteOperation?

  private var fileManager: FileManager { fileSystem.value }

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

  public func configureGitHubOriginRemoteAsync(profile: SiteProfile) async throws -> String {
    guard let rootURL = profile.localRepositoryRootURL else {
      throw SiteStarterError.missingRepositoryRoot
    }
    guard fileManager.fileExists(atPath: rootURL.appendingPathComponent(".git", isDirectory: true).path) else {
      throw SiteStarterError.notGitRepository(rootURL.path)
    }
    guard let remoteURL = githubRemoteURL(
      owner: profile.repoOwner.trimmedForPublishing,
      repoName: profile.repoName.trimmedForPublishing
    ) else {
      throw SiteStarterError.missingOriginRemote
    }

    let existingRemote = await gitCommandRunner.runAsync(
      ["remote", "get-url", "origin"],
      rootURL: rootURL
    )
    let arguments = existingRemote.terminationStatus == 0
      ? ["remote", "set-url", "origin", remoteURL]
      : ["remote", "add", "origin", remoteURL]
    let result = await gitCommandRunner.runAsync(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      throw SiteStarterError.gitFailed(result.output)
    }
    return remoteURL
  }

  public func commitAndPushStarterSite(
    profile: SiteProfile,
    createdFilePaths: [String],
    commitMessage: String = "Initial site"
  ) throws -> SiteStarterPushResult {
    guard let rootURL = profile.localRepositoryRootURL else {
      throw SiteStarterError.missingRepositoryRoot
    }
    guard fileManager.fileExists(atPath: rootURL.appendingPathComponent(".git", isDirectory: true).path) else {
      throw SiteStarterError.notGitRepository(rootURL.path)
    }

    let branch = profile.branch.trimmedForPublishing.nilIfEmpty ?? "main"
    let remoteURL = GitCommandRunner.redactedDiagnosticText(
      try runGitOutput(["remote", "get-url", "origin"], at: rootURL)
    ).trimmedForPublishing
    guard !remoteURL.isEmpty else {
      throw SiteStarterError.missingOriginRemote
    }

    let starterPaths = try validatedStarterPaths(createdFilePaths)
    try rejectUnrelatedStagedChanges(starterPaths: starterPaths, at: rootURL)

    var outputChunks: [String] = []
    outputChunks.append(
      GitCommandRunner.redactedDiagnosticText(
        try runGitOutput(["add", "--"] + starterPaths, at: rootURL)
      )
    )
    let committedPaths = try runGitOutput(["diff", "--cached", "--name-only"], at: rootURL)
      .split(separator: "\n")
      .map { String($0).trimmedForPublishing }
      .filter { !$0.isEmpty }
    guard !committedPaths.isEmpty else {
      throw SiteStarterError.noStarterChanges
    }

    outputChunks.append(
      GitCommandRunner.redactedDiagnosticText(
        try runGitOutput(["commit", "-m", commitMessage], at: rootURL)
      )
    )
    let commitSHA = try runGitOutput(["rev-parse", "HEAD"], at: rootURL).trimmedForPublishing
    outputChunks.append(
      GitCommandRunner.redactedDiagnosticText(
        try runGitOutput(["push", "-u", "origin", branch], at: rootURL)
      )
    )

    return SiteStarterPushResult(
      rootPath: rootURL.path,
      branch: branch,
      remoteURL: remoteURL,
      commitSHA: commitSHA,
      committedPaths: committedPaths,
      output: outputChunks.map { $0.trimmedForPublishing }.filter { !$0.isEmpty }.joined(separator: "\n")
    )
  }

  public func commitAndPushStarterSiteAsync(
    profile: SiteProfile,
    createdFilePaths: [String],
    commitMessage: String = "Initial site"
  ) async throws -> SiteStarterPushResult {
    guard let rootURL = profile.localRepositoryRootURL else {
      throw SiteStarterError.missingRepositoryRoot
    }
    let didStartAccessing = rootURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }
    guard fileManager.fileExists(atPath: rootURL.appendingPathComponent(".git", isDirectory: true).path) else {
      throw SiteStarterError.notGitRepository(rootURL.path)
    }

    let branch = profile.branch.trimmedForPublishing.nilIfEmpty ?? "main"
    let remoteURL = GitCommandRunner.redactedDiagnosticText(
      try await runGitOutputAsync(["remote", "get-url", "origin"], at: rootURL)
    ).trimmedForPublishing
    guard !remoteURL.isEmpty else {
      throw SiteStarterError.missingOriginRemote
    }

    let starterPaths = try validatedStarterPaths(createdFilePaths)
    try await rejectUnrelatedStagedChangesAsync(starterPaths: starterPaths, at: rootURL)

    var outputChunks: [String] = []
    outputChunks.append(
      GitCommandRunner.redactedDiagnosticText(
        try await runGitOutputAsync(["add", "--"] + starterPaths, at: rootURL)
      )
    )
    let committedPaths = try await runGitOutputAsync(["diff", "--cached", "--name-only"], at: rootURL)
      .split(separator: "\n")
      .map { String($0).trimmedForPublishing }
      .filter { !$0.isEmpty }
    guard !committedPaths.isEmpty else {
      throw SiteStarterError.noStarterChanges
    }

    outputChunks.append(
      GitCommandRunner.redactedDiagnosticText(
        try await runGitOutputAsync(["commit", "-m", commitMessage], at: rootURL)
      )
    )
    let commitSHA = try (await runGitOutputAsync(["rev-parse", "HEAD"], at: rootURL)).trimmedForPublishing
    outputChunks.append(
      GitCommandRunner.redactedDiagnosticText(
        try await runGitOutputAsync(["push", "-u", "origin", branch], at: rootURL)
      )
    )

    return SiteStarterPushResult(
      rootPath: rootURL.path,
      branch: branch,
      remoteURL: remoteURL,
      commitSHA: commitSHA,
      committedPaths: committedPaths,
      output: outputChunks.map { $0.trimmedForPublishing }.filter { !$0.isEmpty }.joined(separator: "\n")
    )
  }

  private func template(for id: SiteStarterTemplateID) throws -> SiteStarterTemplate {
    guard let template = SiteStarterTemplate.builtIn.first(where: { $0.id == id }) else {
      throw SiteStarterError.unknownTemplate(id.rawValue)
    }
    return template
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
    draft.repositoryPath = profile.markdownPath(for: draft)
    return draft
  }

  private func starterFiles(
    profile: SiteProfile,
    draft: ArticleDraft,
    siteName: String,
    description: String,
    author: String,
    baseURL: String,
    deploymentTarget: SiteStarterDeploymentTarget
  ) -> [StarterFile] {
    zolaFiles(
      profile: profile,
      draft: draft,
      siteName: siteName,
      description: description,
      author: author,
      baseURL: baseURL,
      deploymentTarget: deploymentTarget
    )
  }

  private func zolaFiles(
    profile: SiteProfile,
    draft: ArticleDraft,
    siteName: String,
    description: String,
    author: String,
    baseURL: String,
    deploymentTarget: SiteStarterDeploymentTarget
  ) -> [StarterFile] {
    var files = [
      StarterFile(
        path: "config.toml",
        contents: """
        base_url = "\(baseURL)"
        title = "\(escapedTOML(siteName))"
        description = "\(escapedTOML(description))"
        default_language = "zh-Hans"
        compile_sass = false
        build_search_index = true
        generate_feeds = true

        [markdown]
        highlight_code = true
        smart_punctuation = true

        [extra]
        author = "\(escapedTOML(author))"
        """
      ),
      StarterFile(path: ".gitignore", contents: "public/\n.DS_Store\n"),
      StarterFile(path: "content/_index.md", contents: zolaSectionFrontMatter(siteName: siteName, sortBy: "date")),
      StarterFile(path: draft.repositoryPath?.nilIfEmpty ?? "content/posts/welcome.md", contents: FrontMatterRenderer().renderDocument(draft: draft, profile: profile)),
      StarterFile(path: "templates/base.html", contents: zolaBaseTemplate(siteName: siteName)),
      StarterFile(path: "templates/index.html", contents: zolaIndexTemplate()),
      StarterFile(path: "templates/section.html", contents: zolaSectionTemplate()),
      StarterFile(path: "templates/page.html", contents: zolaPageTemplate()),
      StarterFile(path: "static/css/site.css", contents: starterCSS()),
      StarterFile(path: "README.md", contents: readme(siteName: siteName, kind: "Zola", buildCommand: "zola build")),
      StarterFile(path: "DEPLOYMENT.md", contents: deploymentGuide(siteName: siteName, kind: "Zola", branch: profile.branch, target: deploymentTarget)),
    ]

    if deploymentTarget == .githubPages {
      files.append(StarterFile(path: ".github/workflows/pages.yml", contents: zolaGitHubPagesWorkflow(branch: profile.branch)))
    }
    files.append(contentsOf: deploymentConfigFiles(target: deploymentTarget, siteName: siteName))
    return files
  }

  private func write(_ file: StarterFile, under rootURL: URL) throws {
    guard isSafeRelativePath(file.path) else {
      throw SiteStarterError.unsafePath(file.path)
    }
    let url = rootURL.appendingPathComponent(file.path)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try file.contents.write(to: url, atomically: true, encoding: .utf8)
  }

  private func initializeGitRepository(at rootURL: URL, branch: String) throws {
    do {
      try runGit(["init", "-b", branch], at: rootURL)
    } catch {
      try runGit(["init"], at: rootURL)
      try runGit(["checkout", "-B", branch], at: rootURL)
    }
  }

  private func addOriginRemote(_ remoteURL: String, at rootURL: URL) throws {
    do {
      try runGit(["remote", "add", "origin", remoteURL], at: rootURL)
    } catch {
      try runGit(["remote", "set-url", "origin", remoteURL], at: rootURL)
    }
  }

  private func runGit(_ arguments: [String], at rootURL: URL) throws {
    _ = try runGitOutput(arguments, at: rootURL)
  }

  private func runGitOutput(_ arguments: [String], at rootURL: URL) throws -> String {
    let result = gitCommandRunner.run(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      throw SiteStarterError.gitFailed(result.output)
    }
    return result.standardOutput
  }

  private func runGitOutputAsync(_ arguments: [String], at rootURL: URL) async throws -> String {
    let result = await gitCommandRunner.runAsync(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      throw SiteStarterError.gitFailed(result.output)
    }
    return result.standardOutput
  }

  private func validatedStarterPaths(_ paths: [String]) throws -> [String] {
    let normalized = Array(Set(paths.map { $0.trimmedForPublishing }))
      .filter { !$0.isEmpty }
      .sorted()
    guard !normalized.isEmpty else {
      throw SiteStarterError.missingStarterFileManifest
    }
    for path in normalized where !isSafeRelativePath(path) {
      throw SiteStarterError.unsafePath(path)
    }
    return normalized
  }

  private func rejectUnrelatedStagedChanges(starterPaths: [String], at rootURL: URL) throws {
    let stagedPaths = try runGitOutput(["diff", "--cached", "--name-only"], at: rootURL)
      .split(separator: "\n")
      .map { String($0).trimmedForPublishing }
      .filter { !$0.isEmpty }
    let unrelatedPaths = stagedPaths.filter { !starterPaths.contains($0) }
    guard unrelatedPaths.isEmpty else {
      throw SiteStarterError.unrelatedStagedChanges(unrelatedPaths.sorted())
    }
  }

  private func rejectUnrelatedStagedChangesAsync(starterPaths: [String], at rootURL: URL) async throws {
    let stagedPaths = try await runGitOutputAsync(["diff", "--cached", "--name-only"], at: rootURL)
      .split(separator: "\n")
      .map { String($0).trimmedForPublishing }
      .filter { !$0.isEmpty }
    let unrelatedPaths = stagedPaths.filter { !starterPaths.contains($0) }
    guard unrelatedPaths.isEmpty else {
      throw SiteStarterError.unrelatedStagedChanges(unrelatedPaths.sorted())
    }
  }

  private func optionalGitOutput(_ arguments: [String], at rootURL: URL) -> String? {
    (try? runGitOutput(arguments, at: rootURL))?.nilIfEmpty
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

  private func parseGitHubRemote(_ remoteURL: String) -> (owner: String, repo: String)? {
    let trimmed = remoteURL.trimmedForPublishing
    let patterns = [
      #"^git@github\.com:([^/]+)/(.+?)(?:\.git)?$"#,
      #"^github\.com:([^/]+)/(.+?)(?:\.git)?$"#,
      #"^https://github\.com/([^/]+)/(.+?)(?:\.git)?$"#,
      #"^ssh://git@github\.com/([^/]+)/(.+?)(?:\.git)?$"#,
    ]

    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
              in: trimmed,
              range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            ),
            match.numberOfRanges == 3,
            let ownerRange = Range(match.range(at: 1), in: trimmed),
            let repoRange = Range(match.range(at: 2), in: trimmed) else {
        continue
      }
      return (
        owner: String(trimmed[ownerRange]),
        repo: String(trimmed[repoRange]).replacingOccurrences(of: ".git", with: "")
      )
    }
    return nil
  }

  private func nextCommands(
    rootURL: URL,
    branch: String,
    owner: String,
    repoName: String,
    remoteURL: String?,
    createdFilePaths: [String]
  ) -> [String] {
    let addCommand = (["git", "add", "--"] + createdFilePaths.sorted())
      .map(posixShellQuote)
      .joined(separator: " ")
    var commands = [
      "cd \(posixShellQuote(rootURL.path))",
      addCommand,
      "git commit -m \(posixShellQuote("Initial site"))",
    ]

    if remoteURL == nil, !owner.isEmpty, !repoName.isEmpty {
      commands.append("git remote add origin \(posixShellQuote("git@github.com:\(owner)/\(repoName).git"))")
    }
    if !owner.isEmpty, !repoName.isEmpty {
      commands.append("git push -u origin \(posixShellQuote(branch))")
    } else {
      commands.append("gh repo create <owner>/<repo> --private --source . --remote origin --push")
    }
    return commands
  }

  private func importedRepositoryNextCommands(
    rootURL: URL,
    branch: String,
    owner: String,
    repoName: String
  ) -> [String] {
    var commands = [
      "cd \(posixShellQuote(rootURL.path))",
      "git status --short",
    ]
    if !owner.isEmpty, !repoName.isEmpty {
      commands.append("git push -u origin \(posixShellQuote(branch))")
    } else {
      commands.append("确认远程仓库后再执行 git push")
    }
    return commands
  }

  private func githubRemoteURL(owner: String, repoName: String) -> String? {
    guard !owner.isEmpty, !repoName.isEmpty else { return nil }
    return "git@github.com:\(owner)/\(repoName).git"
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

  private func isSafeRelativePath(_ path: String) -> Bool {
    !path.isEmpty
      && !path.hasPrefix("/")
      && !path.split(separator: "/").contains("..")
  }

  private func slug(from text: String) -> String {
    SlugService.slug(from: text).nilIfEmpty ?? "my-site"
  }

  private func escapedTOML(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

}

private struct StarterFile {
  var path: String
  var contents: String
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

private func zolaSectionFrontMatter(siteName: String, sortBy: String) -> String {
  """
  +++
  title = "\(siteName)"
  sort_by = "\(sortBy)"
  template = "index.html"
  page_template = "page.html"
  +++

  """
}

private func zolaBaseTemplate(siteName: String) -> String {
  """
  <!doctype html>
  <html lang="zh-Hans">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{% block title %}\(siteName){% endblock title %}</title>
    <link rel="stylesheet" href="{{ get_url(path="css/site.css") }}">
  </head>
  <body>
    <header class="site-header">
      <a class="brand" href="{{ get_url(path="/") }}">\(siteName)</a>
    </header>
    <main class="site-main">
      {% block content %}{% endblock content %}
    </main>
  </body>
  </html>
  """
}

private func zolaIndexTemplate() -> String {
  return """
  {% extends "base.html" %}
  {% block content %}
  <section class="intro">
    <h1>{{ section.title }}</h1>
    <p>{{ config.description }}</p>
  </section>
  <section>
    <h2>最新文章</h2>
    <div class="post-list">
      {% for page in section.pages %}
      <article>
        <a href="{{ page.permalink | safe }}">{{ page.title }}</a>
        <p>{{ page.summary | default(value="") }}</p>
      </article>
      {% endfor %}
    </div>
  </section>
  {% endblock content %}
  """
}

private func zolaSectionTemplate() -> String {
  """
  {% extends "index.html" %}
  """
}

private func zolaPageTemplate() -> String {
  """
  {% extends "base.html" %}
  {% block title %}{{ page.title }} · {{ config.title }}{% endblock title %}
  {% block content %}
  <article class="post">
    <h1>{{ page.title }}</h1>
    <p class="meta">{{ page.date }}</p>
    {{ page.content | safe }}
  </article>
  {% endblock content %}
  """
}

private func starterCSS() -> String {
  """
  :root {
    color-scheme: light dark;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  }
  body {
    margin: 0;
    color: CanvasText;
    background: Canvas;
  }
  .site-header {
    border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
    padding: 18px clamp(20px, 6vw, 72px);
  }
  .brand {
    color: inherit;
    font-weight: 700;
    text-decoration: none;
  }
  .site-main {
    max-width: 760px;
    padding: 42px clamp(20px, 6vw, 72px);
  }
  h1 {
    font-size: clamp(2rem, 4vw, 3.25rem);
    line-height: 1.1;
  }
  a {
    color: LinkText;
  }
  .post-list article {
    border-top: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
    padding: 18px 0;
  }
  .meta {
    color: color-mix(in srgb, CanvasText 58%, transparent);
  }
  """
}

private func readme(siteName: String, kind: String, buildCommand: String) -> String {
  """
  # \(siteName)

  这个站点由 PersonalSitePublisherMac 的 Site Starter 生成。

  ## 本地预览

  - \(kind): `\(buildCommand)`

  ## 使用现成主题

  Site Starter 只维护这一套 Zola 写作起点；如果你想使用其他视觉主题，建议直接克隆主题仓库，再导入已有站点：

  ```bash
  git clone <主题仓库地址> <本地站点目录>
  ```

  回到工作台选择“导入已有站点”。导入会保留主题文件，只读取已有站点的内容和 Git 信息。

  ## 后续发布

  在 Mac 版发布控制台中写文章、检查 Front Matter 和图片，再通过同步/部署工作区推送到 GitHub Pages。
  """
}

private func deploymentGuide(siteName: String, kind: String, branch: String) -> String {
  """
  # \(siteName) 部署说明

  已生成 GitHub Pages 工作流。第一次推送后，在 GitHub 仓库的 Settings > Pages 中选择 GitHub Actions 作为部署来源。

  ## 第一次推送

  ```bash
  git add .
  git commit -m 'Initial site'
  git push -u origin \(posixShellQuote(branch))
  ```

  ## 后续发布

  在发布控制台完成写作、发布检查、Diff 确认和提交后，推送到 `\(branch)` 分支即可触发 GitHub Pages 构建。

  ## 构建器

  当前模板：\(kind)
  """
}

private func deploymentGuide(
  siteName: String,
  kind: String,
  branch: String,
  target: SiteStarterDeploymentTarget
) -> String {
  let targetLine = target == .none ? "暂不绑定外部部署平台。" : "部署目标：\(target.displayName)。"
  return deploymentGuide(siteName: siteName, kind: kind, branch: branch) + "\n\n\(targetLine)\n"
}

private func deploymentConfigFiles(
  target: SiteStarterDeploymentTarget,
  siteName: String
) -> [StarterFile] {
  switch target {
  case .netlify:
    return [
      StarterFile(
        path: "netlify.toml",
        contents: """
        [build]
        command = "zola build"
        publish = "public"
        """
      ),
    ]
  case .vercel:
    return [
      StarterFile(
        path: "vercel.json",
        contents: """
        {
          "name": "\(SlugService.slug(from: siteName).nilIfEmpty ?? "starter-site")",
          "buildCommand": "zola build",
          "outputDirectory": "public"
        }
        """
      ),
    ]
  case .cloudflarePages:
    return [
      StarterFile(
        path: "wrangler.toml",
        contents: """
        name = "\(SlugService.slug(from: siteName).nilIfEmpty ?? "starter-site")"
        pages_build_output_dir = "public"
        compatibility_date = "2026-07-08"
        """
      ),
    ]
  case .githubPages, .none:
    return []
  }
}

private func zolaGitHubPagesWorkflow(branch: String) -> String {
  """
  name: Deploy Zola site to GitHub Pages

  on:
    push:
      branches: [\(branch)]
    workflow_dispatch:

  permissions:
    contents: read
    pages: write
    id-token: write

  concurrency:
    group: pages
    cancel-in-progress: false

  jobs:
    build:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - uses: taiki-e/install-action@v2
          with:
            tool: zola
        - run: zola build
        - uses: actions/upload-pages-artifact@v3
          with:
            path: public

    deploy:
      environment:
        name: github-pages
        url: ${{ steps.deployment.outputs.page_url }}
      runs-on: ubuntu-latest
      needs: build
      steps:
        - id: deployment
          uses: actions/deploy-pages@v4
  """
}
