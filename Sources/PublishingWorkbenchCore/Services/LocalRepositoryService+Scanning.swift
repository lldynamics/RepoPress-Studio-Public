import Foundation

extension LocalRepositoryService {
  func scan(
    rootURL: URL,
    profile: SiteProfile,
    cancellationCheck: @escaping @Sendable () -> Bool
  ) -> RepositoryScanReport {
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
          .init(
            severity: .error,
            title: CoreL10n.text("仓库路径不可读"),
            message: rootPath,
            field: "repository"
          )
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
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  func fileExists(_ url: URL) -> Bool {
    fileManager.fileExists(atPath: url.path)
  }

  func detectSiteKind(rootURL: URL) -> SiteKind? {
    if directoryExists(rootURL.appendingPathComponent("docs/.vitepress", isDirectory: true))
      || directoryExists(rootURL.appendingPathComponent(".vitepress", isDirectory: true)) {
      return .vitePress
    }

    if fileExists(rootURL.appendingPathComponent("quartz.config.ts"))
      || fileExists(rootURL.appendingPathComponent("quartz.layout.ts")) {
      return .quartz
    }

    if directoryExists(rootURL.appendingPathComponent(".foam", isDirectory: true)) {
      return .foam
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
      return .nextJS
    }

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

  func countFiles(
    in rootURL: URL,
    extensions allowedExtensions: Set<String>,
    cancellationCheck: @escaping @Sendable () -> Bool
  ) -> Int {
    guard let enumerator = fileManager.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return 0
    }

    var count = 0
    for case let fileURL as URL in enumerator {
      if cancellationCheck() { break }
      if fileURL.lastPathComponent == "node_modules",
         (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
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
