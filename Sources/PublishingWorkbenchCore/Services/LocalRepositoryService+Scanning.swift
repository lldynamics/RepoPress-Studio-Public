import Foundation

extension LocalRepositoryService {
  func scan(
    rootURL: URL,
    profile: SiteProfile,
    cancellationCheck: @escaping @Sendable () -> Bool
  ) -> RepositoryScanReport {
    let rootPath = rootURL.path
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue
    else {
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
          .init(
            severity: .error,
            title: CoreL10n.text("仓库路径不可读"),
            message: rootPath,
            field: "repository"
          )
        ]
      )
    }

    let contentRootURL = rootURL.appendingPathComponent(
      profile.contentRoot.normalizedRelativePath(), isDirectory: true)
    let assetRootURL = rootURL.appendingPathComponent(
      profile.assetRoot.normalizedRelativePath(), isDirectory: true)
    let contentRootExists = directoryExists(contentRootURL)
    let assetRootExists = directoryExists(assetRootURL)
    let detectedKind = detectSiteKind(rootURL: rootURL)
    // Linked worktrees use a `.git` file that points at the main repository,
    // while ordinary working trees use a directory. Both shapes support the
    // same Git operations below.
    let hasGitDirectory = fileExists(rootURL.appendingPathComponent(".git", isDirectory: false))
    let gitStatus =
      hasGitDirectory
      ? gitStatus(rootURL: rootURL)
      : RepositoryGitStatus(branchStatus: nil, changedFiles: [], remoteChangedFiles: [])
    let originRemote = hasGitDirectory ? gitOriginRemote(rootURL: rootURL) : nil

    var issues: [PreflightIssue] = []
    if detectedKind == nil {
      issues.append(
        .init(
          severity: .warning,
          title: CoreL10n.text("未识别静态站点类型"),
          message: CoreL10n.text("没有发现常见配置文件；仍可继续使用自定义路径规则。"),
          field: "siteKind"
        )
      )
    } else if detectedKind != profile.siteKind {
      issues.append(
        .init(
          severity: .warning,
          title: CoreL10n.text("站点类型可能不一致"),
          message: CoreL10n.format(
            "配置为 %@，扫描到 %@。",
            profile.siteKind.displayName,
            detectedKind?.displayName ?? CoreL10n.text("未知")
          ),
          field: "siteKind"
        )
      )
    }

    if !hasGitDirectory {
      issues.append(
        .init(
          severity: .warning,
          title: CoreL10n.text("未发现 .git"),
          message: CoreL10n.text("当前目录不是 Git 工作树，diff 和提交入口暂不可用。"),
          field: "repository"
        )
      )
    } else {
      issues.append(contentsOf: branchSyncIssues(gitStatus.branchStatus))
    }

    if !contentRootExists {
      issues.append(
        .init(
          severity: .error,
          title: CoreL10n.text("内容目录不存在"),
          message: profile.contentRoot,
          field: "contentRoot"
        )
      )
    }

    if !assetRootExists {
      issues.append(
        .init(
          severity: .warning,
          title: CoreL10n.text("图片目录不存在"),
          message: profile.assetRoot,
          field: "assetRoot"
        )
      )
    }

    return RepositoryScanReport(
      rootPath: rootPath,
      detectedKind: detectedKind,
      expectedKind: profile.siteKind,
      hasGitDirectory: hasGitDirectory,
      contentRootExists: contentRootExists,
      assetRootExists: assetRootExists,
      markdownFileCount: contentRootExists
        ? countFiles(
          in: contentRootURL,
          extensions: ["md", "markdown", "mdx"],
          cancellationCheck: cancellationCheck
        )
        : 0,
      imageFileCount: assetRootExists
        ? countFiles(
          in: assetRootURL,
          extensions: ImageFileSupport.supportedExtensions,
          cancellationCheck: cancellationCheck
        )
        : 0,
      branchStatus: gitStatus.branchStatus,
      originRemote: originRemote,
      changedFiles: gitStatus.changedFiles,
      remoteChangedFiles: gitStatus.remoteChangedFiles,
      preflightIssues: issues
    )
  }

  func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  func fileExists(_ url: URL) -> Bool {
    fileManager.fileExists(atPath: url.path)
  }

  /// Builds a confirmation-ready configuration proposal without changing the
  /// selected repository or persisted profile.
  public func autoConfigurationProposal(
    for rootURL: URL,
    fallbackProfile: SiteProfile
  ) -> RepositoryAutoConfigurationProposal {
    let normalizedRootURL = rootURL.standardizedFileURL
    let detection = siteKindDetection(rootURL: normalizedRootURL)
    let isGitRepository = fileExists(
      normalizedRootURL.appendingPathComponent(".git", isDirectory: false)
    )

    guard let siteKind = detection.kind else {
      return RepositoryAutoConfigurationProposal(
        detectedKind: nil,
        evidence: detection.evidence,
        isGitRepository: isGitRepository,
        contentRoot: fallbackProfile.contentRoot,
        assetRoot: fallbackProfile.assetRoot,
        frontMatterStyle: fallbackProfile.frontMatterStyle,
        markdownPathPattern: fallbackProfile.markdownPathPattern
      )
    }

    let defaults = SiteProfile.defaultPublishingDefaults(for: siteKind)
    let contentRoot = detectedContentRoot(
      rootURL: normalizedRootURL,
      siteKind: siteKind,
      defaultContentRoot: defaults.contentRoot
    )
    let assetRoot = detectedAssetRoot(
      rootURL: normalizedRootURL,
      siteKind: siteKind,
      defaultAssetRoot: defaults.assetRoot
    )
    let markdownFiles = markdownFiles(
      in: normalizedRootURL.appendingPathComponent(contentRoot, isDirectory: true))
    let inferredFrontMatterStyle = inferFrontMatterStyle(from: markdownFiles)
    let frontMatterStyle = inferredFrontMatterStyle ?? defaults.frontMatterStyle
    let markdownPathPattern = inferredMarkdownPathPattern(
      siteKind: siteKind,
      contentRoot: contentRoot,
      defaultPattern: defaults.markdownPathPattern,
      markdownFiles: markdownFiles
    )

    return RepositoryAutoConfigurationProposal(
      detectedKind: siteKind,
      evidence: detection.evidence,
      isGitRepository: isGitRepository,
      contentRoot: contentRoot,
      assetRoot: assetRoot,
      frontMatterStyle: frontMatterStyle,
      markdownPathPattern: markdownPathPattern
    )
  }

  func detectSiteKind(rootURL: URL) -> SiteKind? {
    siteKindDetection(rootURL: rootURL).kind
  }

  func siteKindDetection(rootURL: URL) -> (kind: SiteKind?, evidence: [String]) {
    if directoryExists(rootURL.appendingPathComponent("docs/.vitepress", isDirectory: true))
      || directoryExists(rootURL.appendingPathComponent(".vitepress", isDirectory: true))
    {
      return (.vitePress, [".vitepress"])
    }

    if fileExists(rootURL.appendingPathComponent("quartz.config.ts"))
      || fileExists(rootURL.appendingPathComponent("quartz.layout.ts"))
    {
      return (.quartz, ["quartz.config.ts / quartz.layout.ts"])
    }

    if directoryExists(rootURL.appendingPathComponent(".foam", isDirectory: true)) {
      return (.foam, [".foam"])
    }

    if [
      "contentlayer.config.ts",
      "contentlayer.config.js",
      "contentlayer.config.mjs",
      "contentlayer.config.cjs",
      "velite.config.ts",
      "velite.config.mts",
      "velite.config.js",
      "velite.config.mjs",
      "velite.config.cjs",
    ].contains(where: { fileExists(rootURL.appendingPathComponent($0)) }) {
      return (.nextJS, ["contentlayer.config.* / velite.config.*"])
    }

    if fileExists(rootURL.appendingPathComponent("astro.config.mjs"))
      || fileExists(rootURL.appendingPathComponent("astro.config.ts"))
      || directoryExists(rootURL.appendingPathComponent("src/content", isDirectory: true))
    {
      return (.astro, ["astro.config.* / src/content"])
    }

    if fileExists(rootURL.appendingPathComponent("hugo.toml"))
      || fileExists(rootURL.appendingPathComponent("hugo.yaml"))
      || fileExists(rootURL.appendingPathComponent("hugo.json"))
    {
      return (.hugo, ["hugo.toml / hugo.yaml / hugo.json"])
    }

    if fileExists(rootURL.appendingPathComponent("config.toml")) {
      let configURL = rootURL.appendingPathComponent("config.toml")
      let config = boundedTextContents(of: configURL) ?? ""
      let markers = tomlConfigurationMarkers(in: config)
      let hasHugoProjectShape =
        directoryExists(rootURL.appendingPathComponent("archetypes", isDirectory: true))
        || (directoryExists(rootURL.appendingPathComponent("themes", isDirectory: true))
          && directoryExists(rootURL.appendingPathComponent("layouts", isDirectory: true)))

      let hasZolaBaseURL = markers.keys.contains("base_url")
      let hasHugoBaseURL = markers.keys.contains("baseurl")
      if hasZolaBaseURL != hasHugoBaseURL {
        return hasZolaBaseURL
          ? (.zola, ["config.toml (Zola)"])
          : (.hugo, ["config.toml (Hugo)"])
      }

      let zolaScore =
        2
        * markers.keys.intersection([
          "compile_sass", "build_search_index", "generate_feeds",
        ]).count
        + markers.keys.intersection(["taxonomies"]).count
        + markers.tables.intersection(["slugify", "extra"]).count
      let hugoScore =
        2
        * markers.keys.intersection([
          "languagecode", "contentdir", "paginate",
        ]).count
        + markers.tables.intersection(["params", "permalinks", "taxonomies"]).count
        + (hasHugoProjectShape ? 1 : 0)

      if hugoScore > zolaScore {
        return (.hugo, ["config.toml (Hugo)"])
      }
      if zolaScore > hugoScore {
        return (.zola, ["config.toml (Zola)"])
      }
    }

    if fileExists(rootURL.appendingPathComponent("_config.yml")) {
      if directoryExists(rootURL.appendingPathComponent("source/_posts", isDirectory: true))
        || isHexoPackage(rootURL: rootURL)
      {
        return (.hexo, ["_config.yml + Hexo project markers"])
      }
      return (.jekyll, ["_config.yml"])
    }

    return (nil, [])
  }

  func detectedContentRoot(
    rootURL: URL,
    siteKind: SiteKind,
    defaultContentRoot: String
  ) -> String {
    if siteKind == .hugo,
      let configuredContentRoot = configuredHugoContentRoot(rootURL: rootURL),
      directoryExists(rootURL.appendingPathComponent(configuredContentRoot, isDirectory: true))
    {
      return configuredContentRoot
    }

    let candidates: [String]
    switch siteKind {
    case .astro:
      candidates = ["src/content/blog", "src/content/posts", "src/content"]
    case .hugo, .zola:
      candidates = ["content/posts", "content/post", "content/blog", "content/articles", "content"]
    case .hexo:
      candidates = ["source/_posts", "source/posts", "source"]
    case .jekyll:
      candidates = ["_posts"]
    default:
      candidates = [defaultContentRoot]
    }
    return firstExistingDirectory(in: rootURL, candidates: candidates) ?? defaultContentRoot
  }

  func detectedAssetRoot(
    rootURL: URL,
    siteKind: SiteKind,
    defaultAssetRoot: String
  ) -> String {
    let candidates: [String]
    switch siteKind {
    case .astro:
      // Astro imports `src/assets` through its build pipeline. Publishing
      // defaults use public URLs, so direct attachments must stay in `public`.
      candidates = ["public"]
    case .hugo, .zola:
      candidates = ["static", "assets"]
    case .hexo:
      candidates = ["source", "source/images"]
    case .jekyll:
      candidates = ["assets", "images"]
    default:
      candidates = [defaultAssetRoot]
    }
    return firstExistingDirectory(in: rootURL, candidates: candidates) ?? defaultAssetRoot
  }

  func firstExistingDirectory(in rootURL: URL, candidates: [String]) -> String? {
    for candidate in candidates {
      let normalizedCandidate = candidate.normalizedRelativePath()
      guard !normalizedCandidate.isEmpty,
        directoryExists(rootURL.appendingPathComponent(normalizedCandidate, isDirectory: true))
      else {
        continue
      }
      return normalizedCandidate
    }
    return nil
  }

  func configuredHugoContentRoot(rootURL: URL) -> String? {
    let configurationNames = ["hugo.toml", "hugo.yaml", "hugo.json", "config.toml"]
    let expression = try? NSRegularExpression(
      pattern: #"(?im)^\s*[\"']?contentDir[\"']?\s*(?:=|:)\s*[\"']([^\"']+)[\"']"#
    )

    for configurationName in configurationNames {
      guard let expression,
        let contents = boundedTextContents(
          of: rootURL.appendingPathComponent(configurationName, isDirectory: false)
        )
      else {
        continue
      }
      let range = NSRange(contents.startIndex..., in: contents)
      guard let match = expression.firstMatch(in: contents, range: range),
        let valueRange = Range(match.range(at: 1), in: contents)
      else {
        continue
      }
      let candidate = String(contents[valueRange]).trimmedForPublishing
      guard let normalizedCandidate = safeRelativeRepositoryPath(candidate) else { continue }
      return normalizedCandidate
    }
    return nil
  }

  func safeRelativeRepositoryPath(_ path: String) -> String? {
    let trimmedPath = path.trimmedForPublishing
    guard !trimmedPath.isEmpty,
      !trimmedPath.hasPrefix("/"),
      !trimmedPath.split(separator: "/").contains("..")
    else {
      return nil
    }
    return trimmedPath.normalizedRelativePath().nilIfEmpty
  }

  func tomlConfigurationMarkers(in contents: String) -> (keys: Set<String>, tables: Set<String>) {
    var keys: Set<String> = []
    var tables: Set<String> = []
    for rawLine in contents.split(whereSeparator: \Character.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      if line.hasPrefix("["), let closingBracket = line.firstIndex(of: "]") {
        let start = line.index(after: line.startIndex)
        let table = line[start..<closingBracket]
          .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
          .split(separator: ".")
          .first?
          .lowercased()
        if let table, !table.isEmpty {
          tables.insert(table)
        }
        continue
      }
      guard let separator = line.firstIndex(of: "=") else { continue }
      let key = line[..<separator]
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        .lowercased()
      if !key.isEmpty {
        keys.insert(key)
      }
    }
    return (keys, tables)
  }

  func isHexoPackage(rootURL: URL) -> Bool {
    guard
      let contents = boundedTextContents(
        of: rootURL.appendingPathComponent("package.json", isDirectory: false)
      ), let data = contents.data(using: .utf8),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return false
    }

    for sectionName in ["dependencies", "devDependencies"] {
      guard let dependencies = manifest[sectionName] as? [String: Any] else { continue }
      if dependencies.keys.contains(where: {
        let packageName = $0.lowercased()
        return packageName == "hexo" || packageName.hasPrefix("hexo-")
      }) {
        return true
      }
    }
    guard let scripts = manifest["scripts"] as? [String: Any] else { return false }
    return scripts.values.contains {
      guard let command = $0 as? String else { return false }
      return command.lowercased().split(whereSeparator: \Character.isWhitespace).contains("hexo")
    }
  }

  func markdownFiles(in rootURL: URL, maximumFiles: Int = 3, maximumEntries: Int = 96) -> [URL] {
    guard directoryExists(rootURL), maximumFiles > 0, maximumEntries > 0 else {
      return []
    }

    var files: [URL] = []
    var pendingDirectories = [rootURL]
    var entriesVisited = 0
    let resourceKeys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
    ]
    while !pendingDirectories.isEmpty,
      entriesVisited < maximumEntries,
      files.count < maximumFiles
    {
      let directoryURL = pendingDirectories.removeFirst()
      let children =
        (try? fileManager.contentsOfDirectory(
          at: directoryURL,
          includingPropertiesForKeys: Array(resourceKeys),
          options: []
        ))?.sorted { $0.path < $1.path } ?? []
      for childURL in children {
        guard entriesVisited < maximumEntries, files.count < maximumFiles else { break }
        entriesVisited += 1
        let name = childURL.lastPathComponent
        guard !name.hasPrefix("."), name != "node_modules",
          let values = try? childURL.resourceValues(forKeys: resourceKeys),
          values.isSymbolicLink != true
        else {
          continue
        }
        if values.isDirectory == true, values.isPackage != true {
          pendingDirectories.append(childURL)
        } else if values.isRegularFile == true,
          ["md", "markdown", "mdx"].contains(childURL.pathExtension.lowercased())
        {
          files.append(childURL)
        }
      }
    }
    return files
  }

  func inferFrontMatterStyle(from markdownFiles: [URL]) -> FrontMatterStyle? {
    for fileURL in markdownFiles {
      guard let contents = boundedTextContents(of: fileURL, maximumBytes: 64 * 1024) else {
        continue
      }
      let trimmedContents = contents.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedContents.hasPrefix("+++") {
        return .toml
      }
      if trimmedContents.hasPrefix("---") {
        return .yaml
      }
    }
    return nil
  }

  func inferredMarkdownPathPattern(
    siteKind: SiteKind,
    contentRoot: String,
    defaultPattern: String,
    markdownFiles: [URL]
  ) -> String {
    let extensionName =
      markdownFiles.first?.pathExtension.lowercased().nilIfEmpty
      ?? URL(fileURLWithPath: defaultPattern).pathExtension.nilIfEmpty
      ?? "md"
    let normalizedRoot = contentRoot.normalizedRelativePath()

    switch siteKind {
    case .zola:
      if normalizedRoot == SiteProfile.defaultPublishingDefaults(for: .zola).contentRoot,
        markdownFiles.isEmpty
      {
        return defaultPattern
      }
      return "\(normalizedRoot)/{year}/{slug}.\(extensionName)"
    case .hugo, .astro, .hexo:
      return "\(normalizedRoot)/{slug}.\(extensionName)"
    case .jekyll:
      return "\(normalizedRoot)/{year}-{month}-{day}-{slug}.\(extensionName)"
    default:
      let defaults = SiteProfile.defaultPublishingDefaults(for: siteKind)
      let defaultRoot = defaults.contentRoot.normalizedRelativePath()
      guard !defaultRoot.isEmpty,
        defaultPattern.hasPrefix(defaultRoot + "/")
      else {
        return defaultPattern
      }
      return normalizedRoot + "/" + defaultPattern.dropFirst(defaultRoot.count + 1)
    }
  }

  func boundedTextContents(of url: URL, maximumBytes: Int = 64 * 1024) -> String? {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
      let fileSize = values.fileSize,
      fileSize >= 0,
      fileSize <= maximumBytes,
      let data = try? Data(contentsOf: url, options: .mappedIfSafe)
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  func countFiles(
    in rootURL: URL,
    extensions allowedExtensions: Set<String>,
    cancellationCheck: @escaping @Sendable () -> Bool
  ) -> Int {
    guard
      let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      return 0
    }

    var count = 0
    for case let fileURL as URL in enumerator {
      if cancellationCheck() { break }
      if fileURL.lastPathComponent == "node_modules",
        (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      {
        enumerator.skipDescendants()
        continue
      }
      guard allowedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
      count += 1
    }
    return count
  }

  func branchSyncIssues(_ branchStatus: RepositoryBranchStatus?) -> [PreflightIssue] {
    guard let branchStatus else {
      return [
        .init(
          severity: .warning,
          title: CoreL10n.text("未识别 Git 分支"),
          message: CoreL10n.text("无法读取当前分支同步状态；发布前建议在终端确认 git status。"),
          field: "repository"
        )
      ]
    }

    if branchStatus.isDetached {
      return [
        .init(
          severity: .error,
          title: CoreL10n.text("当前是 Detached HEAD"),
          message: CoreL10n.text("请切回可发布分支后再写入、提交或创建 PR/MR。"),
          field: "repository"
        )
      ]
    }

    guard branchStatus.upstreamName != nil else {
      return [
        .init(
          severity: .info,
          title: CoreL10n.text("未设置上游分支"),
          message: CoreL10n.text("可以继续本地写入；创建 PR/MR 或判断远端差异前建议设置 upstream。"),
          field: "repository"
        )
      ]
    }

    if branchStatus.aheadCount > 0 && branchStatus.behindCount > 0 {
      return [
        .init(
          severity: .warning,
          title: CoreL10n.text("本地分支与远端分叉"),
          message: CoreL10n.format(
            "%@ 本地领先 %d，落后 %d；发布前建议先同步远端变更。",
            branchStatus.displayName,
            branchStatus.aheadCount,
            branchStatus.behindCount
          ),
          field: "repository"
        )
      ]
    }

    if branchStatus.behindCount > 0 {
      return [
        .init(
          severity: .warning,
          title: CoreL10n.text("本地分支落后远端"),
          message: CoreL10n.format(
            "%@ 落后远端 %d 个提交；发布前建议先拉取最新站点内容。",
            branchStatus.displayName,
            branchStatus.behindCount
          ),
          field: "repository"
        )
      ]
    }

    return []
  }

}
