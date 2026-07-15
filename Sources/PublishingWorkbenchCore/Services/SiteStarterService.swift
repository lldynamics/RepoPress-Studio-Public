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

    let draft = starterDraft(profile: profile, template: template, siteName: siteName, author: author, now: request.now)
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
      nextCommands: nextCommands(rootURL: rootURL, branch: branch, owner: owner, repoName: repoName, remoteURL: remoteURL)
    )
  }

  public func importExistingSite(request: SiteStarterImportRequest) throws -> SiteStarterImportResult {
    if let importExistingSiteOperation {
      return try importExistingSiteOperation(request)
    }
    let rootURL = URL(fileURLWithPath: request.rootPath, isDirectory: true).standardizedFileURL
    try validateExistingRootDirectory(rootURL)

    let detectedRemoteURL = optionalGitOutput(["remote", "get-url", "origin"], at: rootURL)
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

  public func commitAndPushStarterSite(
    profile: SiteProfile,
    commitMessage: String = "Initial site"
  ) throws -> SiteStarterPushResult {
    guard let rootURL = profile.localRepositoryRootURL else {
      throw SiteStarterError.missingRepositoryRoot
    }
    guard fileManager.fileExists(atPath: rootURL.appendingPathComponent(".git", isDirectory: true).path) else {
      throw SiteStarterError.notGitRepository(rootURL.path)
    }

    let branch = profile.branch.trimmedForPublishing.nilIfEmpty ?? "main"
    let remoteURL = try runGitOutput(["remote", "get-url", "origin"], at: rootURL)
      .trimmedForPublishing
    guard !remoteURL.isEmpty else {
      throw SiteStarterError.missingOriginRemote
    }

    var outputChunks: [String] = []
    outputChunks.append(try runGitOutput(["add", "."], at: rootURL))
    let committedPaths = try runGitOutput(["diff", "--cached", "--name-only"], at: rootURL)
      .split(separator: "\n")
      .map { String($0).trimmedForPublishing }
      .filter { !$0.isEmpty }
    guard !committedPaths.isEmpty else {
      throw SiteStarterError.noStarterChanges
    }

    outputChunks.append(try runGitOutput(["commit", "-m", commitMessage], at: rootURL))
    let commitSHA = try runGitOutput(["rev-parse", "HEAD"], at: rootURL).trimmedForPublishing
    outputChunks.append(try runGitOutput(["push", "-u", "origin", branch], at: rootURL))

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
    let remoteURL = try (await runGitOutputAsync(["remote", "get-url", "origin"], at: rootURL)).trimmedForPublishing
    guard !remoteURL.isEmpty else {
      throw SiteStarterError.missingOriginRemote
    }

    var outputChunks: [String] = []
    outputChunks.append(try await runGitOutputAsync(["add", "."], at: rootURL))
    let committedPaths = try await runGitOutputAsync(["diff", "--cached", "--name-only"], at: rootURL)
      .split(separator: "\n")
      .map { String($0).trimmedForPublishing }
      .filter { !$0.isEmpty }
    guard !committedPaths.isEmpty else {
      throw SiteStarterError.noStarterChanges
    }

    outputChunks.append(try await runGitOutputAsync(["commit", "-m", commitMessage], at: rootURL))
    let commitSHA = try (await runGitOutputAsync(["rev-parse", "HEAD"], at: rootURL)).trimmedForPublishing
    outputChunks.append(try await runGitOutputAsync(["push", "-u", "origin", branch], at: rootURL))

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
    template: SiteStarterTemplate,
    siteName: String,
    author: String,
    now: Date
  ) -> ArticleDraft {
    let title = template.id == .zolaPortfolio ? "关于我" : "欢迎来到 \(siteName)"
    let slug = template.id == .zolaPortfolio ? "about" : "welcome"
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
    template: SiteStarterTemplate,
    siteName: String,
    description: String,
    author: String,
    baseURL: String,
    deploymentTarget: SiteStarterDeploymentTarget
  ) -> [StarterFile] {
    switch template.siteKind {
    case .zola:
      return zolaFiles(
        profile: profile,
        draft: draft,
        template: template,
        siteName: siteName,
        description: description,
        author: author,
        baseURL: baseURL,
        deploymentTarget: deploymentTarget
      )
    case .jekyll:
      return jekyllFiles(
        profile: profile,
        draft: draft,
        siteName: siteName,
        description: description,
        author: author,
        baseURL: baseURL,
        deploymentTarget: deploymentTarget
      )
    case .astro:
      return astroFiles(
        profile: profile,
        draft: draft,
        siteName: siteName,
        description: description,
        author: author,
        baseURL: baseURL,
        deploymentTarget: deploymentTarget
      )
    case .hugo:
      return hugoFiles(
        profile: profile,
        draft: draft,
        siteName: siteName,
        description: description,
        author: author,
        baseURL: baseURL,
        deploymentTarget: deploymentTarget
      )
    case .hexo:
      return hexoFiles(
        profile: profile,
        draft: draft,
        siteName: siteName,
        description: description,
        author: author,
        baseURL: baseURL,
        deploymentTarget: deploymentTarget
      )
    }
  }

  private func zolaFiles(
    profile: SiteProfile,
    draft: ArticleDraft,
    template: SiteStarterTemplate,
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
      StarterFile(path: "templates/index.html", contents: zolaIndexTemplate(template: template)),
      StarterFile(path: "templates/section.html", contents: zolaSectionTemplate()),
      StarterFile(path: "templates/page.html", contents: zolaPageTemplate()),
      StarterFile(path: "static/css/site.css", contents: starterCSS()),
      StarterFile(path: "README.md", contents: readme(siteName: siteName, kind: "Zola", buildCommand: buildCommand(for: .zola))),
      StarterFile(path: "DEPLOYMENT.md", contents: deploymentGuide(siteName: siteName, kind: "Zola", branch: profile.branch, target: deploymentTarget)),
    ]

    if deploymentTarget == .githubPages {
      files.append(StarterFile(path: ".github/workflows/pages.yml", contents: zolaGitHubPagesWorkflow(branch: profile.branch)))
    }
    files.append(contentsOf: deploymentConfigFiles(target: deploymentTarget, siteKind: .zola, siteName: siteName))
    return files
  }

  private func jekyllFiles(
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
        path: "_config.yml",
        contents: """
        title: "\(escapedYAML(siteName))"
        description: "\(escapedYAML(description))"
        author: "\(escapedYAML(author))"
        url: "\(escapedYAML(baseURL))"
        lang: zh-Hans
        theme: null
        markdown: kramdown
        permalink: /:year/:month/:day/:title/

        defaults:
          - scope:
              path: ""
              type: "posts"
            values:
              layout: "post"
        """
      ),
      StarterFile(path: "Gemfile", contents: "source \"https://rubygems.org\"\n\ngem \"jekyll\", \"~> 4.3\"\n"),
      StarterFile(path: ".gitignore", contents: "_site/\n.sass-cache/\n.jekyll-cache/\n.DS_Store\n"),
      StarterFile(path: "index.md", contents: jekyllHome(siteName: siteName, description: description)),
      StarterFile(path: draft.repositoryPath?.nilIfEmpty ?? "_posts/welcome.md", contents: FrontMatterRenderer().renderDocument(draft: draft, profile: profile)),
      StarterFile(path: "_layouts/default.html", contents: jekyllDefaultLayout(siteName: siteName)),
      StarterFile(path: "_layouts/post.html", contents: jekyllPostLayout()),
      StarterFile(path: "assets/css/style.css", contents: starterCSS()),
      StarterFile(path: "README.md", contents: readme(siteName: siteName, kind: "Jekyll", buildCommand: buildCommand(for: .jekyll))),
      StarterFile(path: "DEPLOYMENT.md", contents: deploymentGuide(siteName: siteName, kind: "Jekyll", branch: profile.branch, target: deploymentTarget)),
    ]

    if deploymentTarget == .githubPages {
      files.append(StarterFile(path: ".github/workflows/pages.yml", contents: jekyllGitHubPagesWorkflow(branch: profile.branch)))
    }
    files.append(contentsOf: deploymentConfigFiles(target: deploymentTarget, siteKind: .jekyll, siteName: siteName))
    return files
  }

  private func astroFiles(
    profile: SiteProfile,
    draft: ArticleDraft,
    siteName: String,
    description: String,
    author: String,
    baseURL: String,
    deploymentTarget: SiteStarterDeploymentTarget
  ) -> [StarterFile] {
    var files = [
      StarterFile(path: "package.json", contents: nodePackageJSON(siteName: siteName, scripts: ["dev": "astro dev", "build": "astro build", "preview": "astro preview"], dependencies: ["@astrojs/mdx": "latest", "astro": "latest"])),
      StarterFile(path: "astro.config.mjs", contents: astroConfig(baseURL: baseURL)),
      StarterFile(path: "src/pages/index.astro", contents: astroIndex(siteName: siteName, description: description)),
      StarterFile(path: draft.repositoryPath?.nilIfEmpty ?? "src/content/blog/welcome.mdx", contents: FrontMatterRenderer().renderDocument(draft: draft, profile: profile)),
      StarterFile(path: "src/styles/site.css", contents: starterCSS()),
      StarterFile(path: ".gitignore", contents: "dist/\nnode_modules/\n.DS_Store\n"),
      StarterFile(path: "README.md", contents: readme(siteName: siteName, kind: "Astro", buildCommand: buildCommand(for: .astro))),
      StarterFile(path: "DEPLOYMENT.md", contents: deploymentGuide(siteName: siteName, kind: "Astro", branch: profile.branch, target: deploymentTarget)),
    ]
    if deploymentTarget == .githubPages {
      files.append(StarterFile(path: ".github/workflows/pages.yml", contents: genericGitHubPagesWorkflow(branch: profile.branch, siteKind: .astro)))
    }
    files.append(contentsOf: deploymentConfigFiles(target: deploymentTarget, siteKind: .astro, siteName: siteName))
    return files
  }

  private func hugoFiles(
    profile: SiteProfile,
    draft: ArticleDraft,
    siteName: String,
    description: String,
    author: String,
    baseURL: String,
    deploymentTarget: SiteStarterDeploymentTarget
  ) -> [StarterFile] {
    var files = [
      StarterFile(path: "hugo.toml", contents: hugoConfig(siteName: siteName, description: description, author: author, baseURL: baseURL)),
      StarterFile(path: "layouts/_default/baseof.html", contents: hugoBaseLayout(siteName: siteName)),
      StarterFile(path: "layouts/index.html", contents: hugoIndexLayout()),
      StarterFile(path: "layouts/_default/single.html", contents: hugoSingleLayout()),
      StarterFile(path: draft.repositoryPath?.nilIfEmpty ?? "content/posts/welcome.md", contents: FrontMatterRenderer().renderDocument(draft: draft, profile: profile)),
      StarterFile(path: "static/css/site.css", contents: starterCSS()),
      StarterFile(path: ".gitignore", contents: "public/\nresources/_gen/\n.DS_Store\n"),
      StarterFile(path: "README.md", contents: readme(siteName: siteName, kind: "Hugo", buildCommand: buildCommand(for: .hugo))),
      StarterFile(path: "DEPLOYMENT.md", contents: deploymentGuide(siteName: siteName, kind: "Hugo", branch: profile.branch, target: deploymentTarget)),
    ]
    if deploymentTarget == .githubPages {
      files.append(StarterFile(path: ".github/workflows/pages.yml", contents: genericGitHubPagesWorkflow(branch: profile.branch, siteKind: .hugo)))
    }
    files.append(contentsOf: deploymentConfigFiles(target: deploymentTarget, siteKind: .hugo, siteName: siteName))
    return files
  }

  private func hexoFiles(
    profile: SiteProfile,
    draft: ArticleDraft,
    siteName: String,
    description: String,
    author: String,
    baseURL: String,
    deploymentTarget: SiteStarterDeploymentTarget
  ) -> [StarterFile] {
    var files = [
      StarterFile(path: "package.json", contents: nodePackageJSON(siteName: siteName, scripts: ["build": "hexo generate", "clean": "hexo clean", "server": "hexo server"], dependencies: ["hexo": "latest", "hexo-renderer-marked": "latest"])),
      StarterFile(path: "_config.yml", contents: hexoConfig(siteName: siteName, description: description, author: author, baseURL: baseURL)),
      StarterFile(path: "themes/starter/layout/layout.ejs", contents: hexoLayout(siteName: siteName)),
      StarterFile(path: "themes/starter/source/css/site.css", contents: starterCSS()),
      StarterFile(path: draft.repositoryPath?.nilIfEmpty ?? "source/_posts/welcome.md", contents: FrontMatterRenderer().renderDocument(draft: draft, profile: profile)),
      StarterFile(path: ".gitignore", contents: "public/\nnode_modules/\n.DS_Store\n"),
      StarterFile(path: "README.md", contents: readme(siteName: siteName, kind: "Hexo", buildCommand: buildCommand(for: .hexo))),
      StarterFile(path: "DEPLOYMENT.md", contents: deploymentGuide(siteName: siteName, kind: "Hexo", branch: profile.branch, target: deploymentTarget)),
    ]
    if deploymentTarget == .githubPages {
      files.append(StarterFile(path: ".github/workflows/pages.yml", contents: genericGitHubPagesWorkflow(branch: profile.branch, siteKind: .hexo)))
    }
    files.append(contentsOf: deploymentConfigFiles(target: deploymentTarget, siteKind: .hexo, siteName: siteName))
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
    return result.output
  }

  private func runGitOutputAsync(_ arguments: [String], at rootURL: URL) async throws -> String {
    let result = await gitCommandRunner.runAsync(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      throw SiteStarterError.gitFailed(result.output)
    }
    return result.output
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
    remoteURL: String?
  ) -> [String] {
    var commands = [
      "cd \(posixShellQuote(rootURL.path))",
      "git add .",
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

  private func escapedYAML(_ text: String) -> String {
    escapedTOML(text)
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
  case noStarterChanges
  case gitFailed(String)

  public var errorDescription: String? {
    switch self {
    case let .unknownTemplate(templateID):
      return "未知站点模板：\(templateID)"
    case let .rootIsNotDirectory(path):
      return "目标路径不是文件夹：\(path)"
    case let .rootDirectoryNotEmpty(path):
      return "目标文件夹不是空文件夹：\(path)"
    case let .unsafePath(path):
      return "模板包含不安全路径：\(path)"
    case .missingRepositoryRoot:
      return "当前 Starter 没有本地仓库路径。"
    case let .notGitRepository(path):
      return "当前目录不是 Git 仓库：\(path)"
    case .missingOriginRemote:
      return "当前 Starter 仓库没有 origin remote。"
    case .noStarterChanges:
      return "没有可提交和推送的 Starter 文件变化。"
    case let .gitFailed(message):
      return "Git 操作失败：\(message)"
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

private func zolaIndexTemplate(template: SiteStarterTemplate) -> String {
  let heading = template.id == .zolaPortfolio ? "作品与记录" : "最新文章"
  return """
  {% extends "base.html" %}
  {% block content %}
  <section class="intro">
    <h1>{{ section.title }}</h1>
    <p>{{ config.description }}</p>
  </section>
  <section>
    <h2>\(heading)</h2>
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

private func jekyllHome(siteName: String, description: String) -> String {
  """
  ---
  layout: default
  title: \(siteName)
  ---

  # \(siteName)

  \(description)

  {% for post in site.posts %}
  - [{{ post.title }}]({{ post.url | relative_url }}) - {{ post.date | date: "%Y-%m-%d" }}
  {% endfor %}
  """
}

private func jekyllDefaultLayout(siteName: String) -> String {
  """
  <!doctype html>
  <html lang="zh-Hans">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{ page.title }} · \(siteName)</title>
    <link rel="stylesheet" href="{{ '/assets/css/style.css' | relative_url }}">
  </head>
  <body>
    <header class="site-header">
      <a class="brand" href="{{ '/' | relative_url }}">\(siteName)</a>
    </header>
    <main class="site-main">
      {{ content }}
    </main>
  </body>
  </html>
  """
}

private func jekyllPostLayout() -> String {
  """
  ---
  layout: default
  ---
  <article class="post">
    <h1>{{ page.title }}</h1>
    <p class="meta">{{ page.date | date: "%Y-%m-%d" }}</p>
    {{ content }}
  </article>
  """
}

private func nodePackageJSON(siteName: String, scripts: [String: String], dependencies: [String: String]) -> String {
  let scriptsText = scripts.keys.sorted().map { key in
    "    \"\(key)\": \"\(scripts[key] ?? "")\""
  }.joined(separator: ",\n")
  let dependenciesText = dependencies.keys.sorted().map { key in
    "    \"\(key)\": \"\(dependencies[key] ?? "")\""
  }.joined(separator: ",\n")
  return """
  {
    "name": "\(SlugService.slug(from: siteName).nilIfEmpty ?? "starter-site")",
    "version": "0.1.0",
    "private": true,
    "scripts": {
  \(scriptsText)
    },
    "dependencies": {
  \(dependenciesText)
    }
  }
  """
}

private func astroConfig(baseURL: String) -> String {
  """
  import { defineConfig } from 'astro/config';
  import mdx from '@astrojs/mdx';

  export default defineConfig({
    site: '\(baseURL)',
    integrations: [mdx()]
  });
  """
}

private func astroIndex(siteName: String, description: String) -> String {
  """
  ---
  import '../styles/site.css';
  ---
  <html lang="zh-Hans">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width" />
      <title>\(siteName)</title>
    </head>
    <body>
      <header class="site-header">
        <a class="brand" href="/">\(siteName)</a>
      </header>
      <main class="site-main">
        <h1>\(siteName)</h1>
        <p>\(description)</p>
        <section class="post-list">
          <article>
            <a href="/blog/welcome/">欢迎文章</a>
            <p>从第一篇内容开始扩展你的 Astro 网站。</p>
          </article>
        </section>
      </main>
    </body>
  </html>
  """
}

private func hugoConfig(siteName: String, description: String, author: String, baseURL: String) -> String {
  """
  baseURL = '\(baseURL)'
  languageCode = 'zh-Hans'
  title = '\(siteName)'

  [params]
  description = '\(description)'
  author = '\(author)'
  """
}

private func hugoBaseLayout(siteName: String) -> String {
  """
  <!doctype html>
  <html lang="zh-Hans">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{ block "title" . }}\(siteName){{ end }}</title>
    <link rel="stylesheet" href="/css/site.css">
  </head>
  <body>
    <header class="site-header"><a class="brand" href="/">\(siteName)</a></header>
    <main class="site-main">{{ block "main" . }}{{ end }}</main>
  </body>
  </html>
  """
}

private func hugoIndexLayout() -> String {
  """
  {{ define "main" }}
  <section class="intro">
    <h1>{{ .Site.Title }}</h1>
    <p>{{ .Site.Params.description }}</p>
  </section>
  <section class="post-list">
    {{ range first 10 .Site.RegularPages }}
    <article>
      <a href="{{ .RelPermalink }}">{{ .Title }}</a>
      <p>{{ .Summary }}</p>
    </article>
    {{ end }}
  </section>
  {{ end }}
  """
}

private func hugoSingleLayout() -> String {
  """
  {{ define "title" }}{{ .Title }} · {{ .Site.Title }}{{ end }}
  {{ define "main" }}
  <article class="post">
    <h1>{{ .Title }}</h1>
    <p class="meta">{{ .Date.Format "2006-01-02" }}</p>
    {{ .Content }}
  </article>
  {{ end }}
  """
}

private func hexoConfig(siteName: String, description: String, author: String, baseURL: String) -> String {
  """
  title: \(siteName)
  subtitle: ''
  description: \(description)
  keywords:
  author: \(author)
  language: zh-Hans
  timezone: ''
  url: \(baseURL)
  root: /
  permalink: :year/:month/:day/:title/
  theme: starter
  """
}

private func hexoLayout(siteName: String) -> String {
  """
  <!doctype html>
  <html lang="zh-Hans">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title><%= page.title || config.title %> · \(siteName)</title>
    <link rel="stylesheet" href="/css/site.css">
  </head>
  <body>
    <header class="site-header"><a class="brand" href="/"><%= config.title %></a></header>
    <main class="site-main">
      <%- body %>
    </main>
  </body>
  </html>
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

private func buildCommand(for siteKind: SiteKind) -> String {
  switch siteKind {
  case .zola:
    return "zola build"
  case .astro:
    return "npm run build"
  case .hugo:
    return "hugo --minify"
  case .hexo:
    return "npm run build"
  case .jekyll:
    return "bundle exec jekyll build"
  }
}

private func deploymentConfigFiles(
  target: SiteStarterDeploymentTarget,
  siteKind: SiteKind,
  siteName: String
) -> [StarterFile] {
  switch target {
  case .netlify:
    return [
      StarterFile(
        path: "netlify.toml",
        contents: """
        [build]
        command = "\(buildCommand(for: siteKind))"
        publish = "\(publishDirectory(for: siteKind))"
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
          "buildCommand": "\(buildCommand(for: siteKind))",
          "outputDirectory": "\(publishDirectory(for: siteKind))"
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
        pages_build_output_dir = "\(publishDirectory(for: siteKind))"
        compatibility_date = "2026-07-08"
        """
      ),
    ]
  case .githubPages, .none:
    return []
  }
}

private func publishDirectory(for siteKind: SiteKind) -> String {
  switch siteKind {
  case .astro:
    return "dist"
  case .jekyll:
    return "_site"
  case .zola, .hugo, .hexo:
    return "public"
  }
}

private func genericGitHubPagesWorkflow(branch: String, siteKind: SiteKind) -> String {
  let command = buildCommand(for: siteKind)
  let setupStep: String
  switch siteKind {
  case .astro, .hexo:
    setupStep = """
        - uses: actions/setup-node@v4
          with:
            node-version: 22
        - run: npm install
    """
  case .hugo:
    setupStep = """
        - uses: peaceiris/actions-hugo@v3
          with:
            hugo-version: latest
    """
  case .zola:
    setupStep = """
        - uses: taiki-e/install-action@v2
          with:
            tool: zola
    """
  case .jekyll:
    setupStep = """
        - uses: ruby/setup-ruby@v1
          with:
            bundler-cache: true
    """
  }
  return """
  name: Deploy static site to GitHub Pages

  on:
    push:
      branches: [\(branch)]
    workflow_dispatch:

  permissions:
    contents: read
    pages: write
    id-token: write

  jobs:
    build:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
  \(setupStep)
        - run: \(command)
        - uses: actions/upload-pages-artifact@v3
          with:
            path: \(publishDirectory(for: siteKind))

    deploy:
      runs-on: ubuntu-latest
      needs: build
      steps:
        - uses: actions/deploy-pages@v4
  """
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

private func jekyllGitHubPagesWorkflow(branch: String) -> String {
  """
  name: Deploy Jekyll site to GitHub Pages

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
        - uses: actions/configure-pages@v5
        - uses: actions/jekyll-build-pages@v1
          with:
            source: ./
            destination: ./_site
        - uses: actions/upload-pages-artifact@v3
          with:
            path: ./_site

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
