import XCTest
@testable import PublishingWorkbenchCore

final class LocalRepositoryServiceTests: XCTestCase {
  func testSwitchLocalBranchChangesTheCheckedOutBranch() throws {
    let (rootURL, profile) = try makeBranchOperationRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try git(["branch", "release"], rootURL: rootURL)

    try LocalRepositoryService().switchLocalBranch(profile: profile, to: "release")

    XCTAssertEqual(try git(["branch", "--show-current"], rootURL: rootURL), "release")
  }

  func testSwitchLocalBranchRejectsDirtyWorkingTree() throws {
    let (rootURL, profile) = try makeBranchOperationRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try git(["branch", "release"], rootURL: rootURL)
    try "changed\n".write(
      to: rootURL.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )

    XCTAssertThrowsError(
      try LocalRepositoryService().switchLocalBranch(profile: profile, to: "release")
    ) { error in
      guard let serviceError = error as? LocalRepositoryServiceError,
            case .workingTreeHasChanges = serviceError else {
        return XCTFail("Expected workingTreeHasChanges, got \(error)")
      }
    }
    XCTAssertEqual(try git(["branch", "--show-current"], rootURL: rootURL), "main")
  }

  func testCreateAndSwitchLocalBranchIsAtomic() throws {
    let (rootURL, profile) = try makeBranchOperationRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try LocalRepositoryService().createAndSwitchLocalBranch(
      profile: profile,
      branchName: "review/article",
      from: "main"
    )

    XCTAssertEqual(try git(["branch", "--show-current"], rootURL: rootURL), "review/article")
    XCTAssertEqual(try git(["rev-parse", "review/article"], rootURL: rootURL), try git(["rev-parse", "main"], rootURL: rootURL))
  }

  func testIgnoredRepositoryPathsUsesNULTerminatedStandardInput() throws {
    let (rootURL, profile) = try makeBranchOperationRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try ".build/\n".write(
      to: rootURL.appendingPathComponent(".gitignore"),
      atomically: true,
      encoding: .utf8
    )

    let ignored = LocalRepositoryService().ignoredRepositoryPaths(
      profile: profile,
      paths: [".build/cache/artifact", "content/posts/article.md"]
    )

    XCTAssertEqual(ignored, [".build/cache/artifact"])
  }

  func testDetectsZolaRepositoryShapeAndCountsFiles() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "base_url = \"https://example.com\"".write(
      to: rootURL.appendingPathComponent("config.toml"),
      atomically: true,
      encoding: .utf8
    )
    try "# Hello".write(
      to: rootURL.appendingPathComponent("content/posts/hello.md"),
      atomically: true,
      encoding: .utf8
    )
    try Data([0, 1, 2]).write(to: rootURL.appendingPathComponent("static/images/cover.png"))
    try Data([3, 4]).write(to: rootURL.appendingPathComponent("static/images/icon.SVG"))
    try Data([5, 6]).write(to: rootURL.appendingPathComponent("static/images/photo.HEIC"))
    try Data([7, 8]).write(to: rootURL.appendingPathComponent("static/images/raw.psd"))

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    profile.assetRoot = "static"

    let report = LocalRepositoryService().scan(profile: profile)

    XCTAssertEqual(report.detectedKind, .zola)
    XCTAssertTrue(report.contentRootExists)
    XCTAssertTrue(report.assetRootExists)
    XCTAssertEqual(report.markdownFileCount, 1)
    XCTAssertEqual(report.imageFileCount, 3)
  }

  func testAutoConfigurationRecognizesSupportedFrameworkFixtures() throws {
    let fixtures = [
      AutoConfigurationFixture(
        name: "Hugo",
        directories: ["content/blog", "static"],
        files: [
          "config.toml": """
          # base_url in a comment must not make this look like Zola.
          baseURL = "https://example.com"
          contentDir = "content/blog"
          description = "mentions compile_sass only as text"
          [taxonomies]
          tag = "tags"
          """,
          "content/blog/hello.md": "+++\ntitle = \"Hello\"\n+++",
        ],
        expectedKind: .hugo,
        expectedContentRoot: "content/blog",
        expectedAssetRoot: "static",
        expectedFrontMatterStyle: .toml,
        expectedMarkdownPathPattern: "content/blog/{slug}.md"
      ),
      AutoConfigurationFixture(
        name: "Zola",
        directories: ["content/posts"],
        files: [
          "config.toml": "base_url = \"https://example.com\"\nbuild_search_index = true",
          "content/posts/hello.md": "---\ntitle: Hello\n---",
        ],
        expectedKind: .zola,
        expectedContentRoot: "content/posts",
        expectedAssetRoot: "static",
        expectedFrontMatterStyle: .yaml,
        expectedMarkdownPathPattern: "content/posts/{year}/{slug}.md"
      ),
      AutoConfigurationFixture(
        name: "Astro",
        directories: ["src/content/blog", "public"],
        files: [
          "astro.config.mjs": "export default {}",
          "src/content/blog/hello.mdx": "---\ntitle: Hello\n---",
        ],
        expectedKind: .astro,
        expectedContentRoot: "src/content/blog",
        expectedAssetRoot: "public",
        expectedFrontMatterStyle: .yaml,
        expectedMarkdownPathPattern: "src/content/blog/{slug}.mdx"
      ),
      AutoConfigurationFixture(
        name: "Jekyll",
        directories: ["_posts"],
        files: [
          "_config.yml": "title: Test",
          "package.json": #"{"devDependencies":{"sass":"^1.0.0"}}"#,
        ],
        expectedKind: .jekyll,
        expectedContentRoot: "_posts",
        expectedAssetRoot: "assets",
        expectedFrontMatterStyle: .yaml,
        expectedMarkdownPathPattern: "_posts/{year}-{month}-{day}-{slug}.md"
      ),
      AutoConfigurationFixture(
        name: "Hexo",
        directories: ["source/_posts"],
        files: [
          "_config.yml": "title: Test",
          "package.json": #"{"dependencies":{"hexo":"^7.0.0"}}"#,
        ],
        expectedKind: .hexo,
        expectedContentRoot: "source/_posts",
        expectedAssetRoot: "source",
        expectedFrontMatterStyle: .yaml,
        expectedMarkdownPathPattern: "source/_posts/{slug}.md"
      ),
    ]

    let service = LocalRepositoryService()
    for fixture in fixtures {
      let rootURL = try makeAutoConfigurationRepository(named: fixture.name)
      defer { try? FileManager.default.removeItem(at: rootURL) }
      for directory in fixture.directories {
        try FileManager.default.createDirectory(
          at: rootURL.appendingPathComponent(directory, isDirectory: true),
          withIntermediateDirectories: true
        )
      }
      for (path, contents) in fixture.files {
        let fileURL = rootURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(
          at: fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
      }

      let proposal = service.autoConfigurationProposal(
        for: rootURL,
        fallbackProfile: .defaultProfile
      )

      XCTAssertEqual(proposal.detectedKind, fixture.expectedKind, fixture.name)
      XCTAssertTrue(proposal.isGitRepository, fixture.name)
      XCTAssertEqual(proposal.contentRoot, fixture.expectedContentRoot, fixture.name)
      XCTAssertEqual(proposal.assetRoot, fixture.expectedAssetRoot, fixture.name)
      XCTAssertEqual(proposal.frontMatterStyle, fixture.expectedFrontMatterStyle, fixture.name)
      XCTAssertEqual(
        proposal.markdownPathPattern,
        fixture.expectedMarkdownPathPattern,
        fixture.name
      )
      XCTAssertEqual(service.detectSiteKind(rootURL: rootURL), fixture.expectedKind, fixture.name)
      XCTAssertEqual(
        proposal.applying(to: .defaultProfile, repositoryURL: rootURL).siteKind,
        fixture.expectedKind,
        fixture.name
      )
    }
  }

  func testRepositoryPublishingRuleValidationCoversSafeAndUnsafeScenarios() {
    let validRules: [(contentRoot: String, pattern: String)] = [
      ("content", "content/posts/{year}/{slug}.md"),
      ("src/content/blog", "src/content/blog/{slug}.mdx"),
      (".", "notes/{slug}.md"),
    ]
    for rule in validRules {
      XCTAssertTrue(
        RepositoryPublishingRuleValidation.isValid(
          contentRoot: rule.contentRoot,
          markdownPathPattern: rule.pattern
        ),
        "Expected valid rule: \(rule)"
      )
    }

    let invalidRules: [(contentRoot: String, pattern: String)] = [
      ("content", "posts/{slug}.md"),
      ("content", "content/posts/article.md"),
      ("../content", "content/{slug}.md"),
      ("content", "content/../private/{slug}.md"),
      ("content", #"content\posts\{slug}.md"#),
      ("content", "https://example.com/{slug}.md"),
      ("content", "file:/tmp/{slug}.md"),
      ("~/content", "~/content/{slug}.md"),
    ]
    for rule in invalidRules {
      XCTAssertFalse(
        RepositoryPublishingRuleValidation.isValid(
          contentRoot: rule.contentRoot,
          markdownPathPattern: rule.pattern
        ),
        "Expected invalid rule: \(rule)"
      )
    }
  }

  func testMarkdownInferenceUsesDeterministicPathOrder() throws {
    let rootURL = try makeAutoConfigurationRepository(named: "DeterministicMarkdown")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    for directory in ["b", "a"] {
      let directoryURL = rootURL.appendingPathComponent(directory, isDirectory: true)
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      try "---\ntitle: Test\n---".write(
        to: directoryURL.appendingPathComponent("article.md"),
        atomically: true,
        encoding: .utf8
      )
    }

    let files = LocalRepositoryService().markdownFiles(
      in: rootURL,
      maximumFiles: 1,
      maximumEntries: 8
    )

    let expectedURL = rootURL.appendingPathComponent("a/article.md").resolvingSymlinksInPath()
    XCTAssertEqual(files.map { $0.resolvingSymlinksInPath().path }, [expectedURL.path])
  }

  func testAutoConfigurationUsesFallbackForUnknownRepository() throws {
    let rootURL = try makeAutoConfigurationRepository(named: "Unknown")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "title = \"Ambiguous\"".write(
      to: rootURL.appendingPathComponent("config.toml"),
      atomically: true,
      encoding: .utf8
    )
    var fallback = SiteProfile.defaultProfile
    fallback.applyPublishingDefaults(for: .vitePress)

    let proposal = LocalRepositoryService().autoConfigurationProposal(
      for: rootURL,
      fallbackProfile: fallback
    )
    let applied = proposal.applying(to: fallback, repositoryURL: rootURL)

    XCTAssertNil(proposal.detectedKind)
    XCTAssertEqual(proposal.contentRoot, fallback.contentRoot)
    XCTAssertEqual(proposal.frontMatterStyle, fallback.frontMatterStyle)
    XCTAssertEqual(proposal.markdownPathPattern, fallback.markdownPathPattern)
    XCTAssertEqual(applied.siteKind, .vitePress)
    XCTAssertEqual(applied.localRepositoryRootURL, rootURL.standardizedFileURL)
  }

  func testAutoConfigurationRecognizesLinkedWorktreeGitFile() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "RepositoryAutoConfigurationTests-Worktree-\(UUID().uuidString)",
        isDirectory: true
      )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("src/content/blog", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "gitdir: /tmp/example.git/worktrees/site\n".write(
      to: rootURL.appendingPathComponent(".git"),
      atomically: true,
      encoding: .utf8
    )
    try "export default {}".write(
      to: rootURL.appendingPathComponent("astro.config.mjs"),
      atomically: true,
      encoding: .utf8
    )

    let service = LocalRepositoryService()
    let proposal = service.autoConfigurationProposal(
      for: rootURL,
      fallbackProfile: .defaultProfile
    )
    var profile = proposal.applying(to: .defaultProfile, repositoryURL: rootURL)
    profile.assetRoot = "src/content/blog"
    let report = service.scan(profile: profile)

    XCTAssertTrue(proposal.isGitRepository)
    XCTAssertTrue(report.hasGitDirectory)
  }

  func testDetectsVitePressRepositoryShape() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("VitePressRepositoryTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("docs/.vitepress", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("docs/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "export default {}".write(
      to: rootURL.appendingPathComponent("docs/.vitepress/config.mts"),
      atomically: true,
      encoding: .utf8
    )
    try "# Hello".write(
      to: rootURL.appendingPathComponent("docs/posts/hello.md"),
      atomically: true,
      encoding: .utf8
    )

    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .vitePress)
    profile.rememberLocalRepositoryRoot(rootURL)

    let report = LocalRepositoryService().scan(profile: profile)

    XCTAssertEqual(report.detectedKind, .vitePress)
    XCTAssertTrue(report.contentRootExists)
    XCTAssertEqual(report.markdownFileCount, 1)
  }

  func testScanStopsFileEnumerationWhenCancellationIsRequested() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PersonalSitePublisherMacCancelledScanTests-\(UUID().uuidString)",
        isDirectory: true
      )
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let contentURL = rootURL.appendingPathComponent("content/posts", isDirectory: true)
    let imageURL = rootURL.appendingPathComponent("static/images", isDirectory: true)
    try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: imageURL, withIntermediateDirectories: true)
    try "# Article".write(
      to: contentURL.appendingPathComponent("article.md"),
      atomically: true,
      encoding: .utf8
    )
    try Data([0, 1, 2]).write(to: imageURL.appendingPathComponent("cover.png"))

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    profile.assetRoot = "static"

    let report = LocalRepositoryService().scan(
      profile: profile,
      cancellationCheck: { true }
    )

    XCTAssertTrue(report.contentRootExists)
    XCTAssertTrue(report.assetRootExists)
    XCTAssertEqual(report.markdownFileCount, 0)
    XCTAssertEqual(report.imageFileCount, 0)
  }

  func testReportsBranchUpstreamAheadBehindFromGitStatus() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacBranchTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "base_url = \"https://example.com\"".write(
      to: rootURL.appendingPathComponent("config.toml"),
      atomically: true,
      encoding: .utf8
    )

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)
    let baseCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)

    try git(["switch", "-c", "remote-work"], rootURL: rootURL)
    try "remote\n".write(to: rootURL.appendingPathComponent("content/posts/remote.md"), atomically: true, encoding: .utf8)
    try git(["add", "content/posts/remote.md"], rootURL: rootURL)
    try git(["commit", "-m", "Remote"], rootURL: rootURL)
    let remoteCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)

    try git(["switch", "main"], rootURL: rootURL)
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "local\n".write(to: rootURL.appendingPathComponent("content/posts/local.md"), atomically: true, encoding: .utf8)
    try git(["add", "content/posts/local.md"], rootURL: rootURL)
    try git(["commit", "-m", "Local"], rootURL: rootURL)
    try git(["remote", "add", "origin", "https://example.invalid/site.git"], rootURL: rootURL)
    try git(["update-ref", "refs/remotes/origin/main", remoteCommit], rootURL: rootURL)
    try git(["update-ref", "refs/heads/origin/main", baseCommit], rootURL: rootURL)
    try git(["config", "branch.main.remote", "origin"], rootURL: rootURL)
    try git(["config", "branch.main.merge", "refs/heads/main"], rootURL: rootURL)
    XCTAssertEqual(try git(["merge-base", "main", "origin/main"], rootURL: rootURL), baseCommit)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    profile.assetRoot = "static"

    let report = LocalRepositoryService().scan(profile: profile)

    XCTAssertEqual(report.branchStatus?.branchName, "main")
    XCTAssertEqual(report.branchStatus?.upstreamName, "remotes/origin/main")
    XCTAssertEqual(report.branchStatus?.aheadCount, 1)
    XCTAssertEqual(report.branchStatus?.behindCount, 1)
    XCTAssertEqual(report.syncStatusTitle, "本地领先 1，落后 1")
    XCTAssertEqual(report.remoteChangedFiles.map(\.path), ["content/posts/remote.md"])
    XCTAssertEqual(report.remoteChangedFiles.first?.kind, .added)
    XCTAssertTrue(report.remoteChangedFiles.first?.lineDiff?.contains("+remote") == true)
    XCTAssertEqual(report.remoteChangeSummary(contentRoot: "content", assetRoot: "static").articleCount, 1)
    XCTAssertTrue(report.preflightIssues.contains { issue in
      issue.severity == .warning
        && issue.title == "本地分支与远端分叉"
        && issue.message.contains("本地领先 1，落后 1")
    })
  }

  func testGitStatusPreservesUnicodeSpacesQuotesAndRenamePaths() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacNULStatusTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let contentURL = rootURL.appendingPathComponent("content/posts", isDirectory: true)
    try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true)
    let modifiedPath = "content/posts/修改 中文 文件.md"
    let untrackedPath = "content/posts/*?[]: 未跟踪 \"稿\".md"
    let oldRenamePath = "content/posts/旧 中文.md"
    let newRenamePath = "content/posts/新 \" 标题.md"

    for path in [modifiedPath, oldRenamePath] {
      try "original\n".write(
        to: rootURL.appendingPathComponent(path),
        atomically: true,
        encoding: .utf8
      )
    }

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try git(["add", "."], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)

    try "modified\n".write(
      to: rootURL.appendingPathComponent(modifiedPath),
      atomically: true,
      encoding: .utf8
    )
    try git(["mv", oldRenamePath, newRenamePath], rootURL: rootURL)
    try git(["add", newRenamePath], rootURL: rootURL)
    try "original\nstaged rename\nunstaged destination\n".write(
      to: rootURL.appendingPathComponent(newRenamePath),
      atomically: true,
      encoding: .utf8
    )
    try "untracked\n".write(
      to: rootURL.appendingPathComponent(untrackedPath),
      atomically: true,
      encoding: .utf8
    )

    let status = LocalRepositoryService().gitStatus(rootURL: rootURL)
    let changedFiles = status.changedFiles

    let modified = try XCTUnwrap(changedFiles.first { $0.path == modifiedPath })
    XCTAssertEqual(modified.kind, .modified)

    let untracked = try XCTUnwrap(changedFiles.first { $0.path == untrackedPath })
    XCTAssertEqual(untracked.kind, .untracked)

    let renamed = try XCTUnwrap(
      changedFiles.first {
        $0.sourcePath == oldRenamePath && $0.destinationPath == newRenamePath
      }
    )
    XCTAssertTrue(renamed.status.contains("R"))
    XCTAssertTrue(renamed.lineDiff?.contains("similarity index") == true)
    XCTAssertTrue(renamed.lineDiff?.contains("rename from") == true)
    XCTAssertTrue(renamed.lineDiff?.contains("rename to") == true)
    XCTAssertTrue(renamed.lineDiff?.contains("+unstaged destination") == true)
    if let lineDiff = renamed.lineDiff,
       let renameIndex = lineDiff.range(of: "similarity index"),
       let unstagedIndex = lineDiff.range(of: "+unstaged destination") {
      XCTAssertLessThan(renameIndex.lowerBound, unstagedIndex.lowerBound)
    } else {
      XCTFail("Expected staged rename metadata and destination unstaged content")
    }
    XCTAssertEqual(renamed.displayPath, newRenamePath)
    XCTAssertTrue(renamed.path.contains(" -> "))

    let magicUntracked = try XCTUnwrap(changedFiles.first { $0.path == untrackedPath })
    XCTAssertEqual(magicUntracked.kind, .untracked)
    XCTAssertTrue(magicUntracked.lineDiff?.contains("+untracked") == true)
    XCTAssertFalse(changedFiles.contains { $0.path.contains("\\344") })
  }

  func testRemoteNameStatusPreservesUnicodeRenamePaths() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacNULRemoteTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let contentURL = rootURL.appendingPathComponent("content/posts", isDirectory: true)
    try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true)
    let oldPath = "content/posts/旧 中文.md"
    let newPath = "content/posts/新 \" 标题.md"
    let literalPath = "content/posts/*?[]: literal.md"
    try "remote\nbody\nbody\nbody\n".write(
      to: rootURL.appendingPathComponent(oldPath),
      atomically: true,
      encoding: .utf8
    )

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try git(["add", "."], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)
    try git(["switch", "-c", "remote-work"], rootURL: rootURL)
    try git(["mv", oldPath, newPath], rootURL: rootURL)
    try "remote\nbody\nbody\nbody\nremote updated\n".write(
      to: rootURL.appendingPathComponent(newPath),
      atomically: true,
      encoding: .utf8
    )
    try "literal magic\n".write(
      to: rootURL.appendingPathComponent(literalPath),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "."], rootURL: rootURL)
    try git(["commit", "-m", "Rename remote article"], rootURL: rootURL)
    let remoteCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)
    try git(["switch", "main"], rootURL: rootURL)
    try git(["update-ref", "refs/remotes/origin/main", remoteCommit], rootURL: rootURL)

    let service = LocalRepositoryService()
    let changedFiles = service.remoteChangedFiles(rootURL: rootURL, upstreamName: "origin/main")
    let renamed = try XCTUnwrap(changedFiles.first { $0.kind == .renamed })
    XCTAssertTrue(renamed.status.hasPrefix("R"))
    XCTAssertEqual(renamed.path, "\(oldPath) -> \(newPath)")
    XCTAssertEqual(renamed.sourcePath, oldPath)
    XCTAssertEqual(renamed.destinationPath, newPath)
    XCTAssertEqual(renamed.kind, .renamed)
    XCTAssertEqual(renamed.displayPath, newPath)
    XCTAssertTrue(renamed.lineDiff?.contains("+remote updated") == true)
    XCTAssertTrue(renamed.lineDiff?.contains("similarity index") == true)
    XCTAssertTrue(renamed.lineDiff?.contains("rename from") == true)
    XCTAssertTrue(renamed.lineDiff?.contains("rename to") == true)

    let literal = try XCTUnwrap(changedFiles.first { $0.displayPath == literalPath })
    XCTAssertEqual(literal.kind, .added)
    XCTAssertTrue(literal.lineDiff?.contains("+literal magic") == true)
    XCTAssertEqual(changedFiles.map(\.displayPath), [literalPath, newPath])
  }

  func testFetchUpstreamRefreshesRemoteTrackingBranchBeforeScan() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacFetchTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let remoteURL = rootURL.appendingPathComponent("remote.git", isDirectory: true)
    let localURL = rootURL.appendingPathComponent("local", isDirectory: true)
    let contributorURL = rootURL.appendingPathComponent("contributor", isDirectory: true)

    try git(["init", "--bare", "--initial-branch=main", remoteURL.path], rootURL: rootURL)
    try git(["clone", remoteURL.path, "local"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: localURL)
    try git(["config", "user.name", "Tests"], rootURL: localURL)
    try FileManager.default.createDirectory(
      at: localURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "base\n".write(to: localURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: localURL)
    try git(["commit", "-m", "Initial"], rootURL: localURL)
    try git(["push", "-u", "origin", "main"], rootURL: localURL)

    try git(["clone", remoteURL.path, "contributor"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: contributorURL)
    try git(["config", "user.name", "Tests"], rootURL: contributorURL)
    try FileManager.default.createDirectory(
      at: contributorURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "remote\n".write(
      to: contributorURL.appendingPathComponent("content/posts/remote.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "content/posts/remote.md"], rootURL: contributorURL)
    try git(["commit", "-m", "Remote article"], rootURL: contributorURL)
    try git(["push", "origin", "main"], rootURL: contributorURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(localURL)
    profile.contentRoot = "content"
    let service = LocalRepositoryService()

    XCTAssertEqual(service.scan(profile: profile).remoteChangedFiles.map(\.displayPath), [])

    let fetch = service.fetchUpstream(profile: profile)
    let report = service.scan(profile: profile)

    XCTAssertEqual(fetch.status, .succeeded)
    XCTAssertEqual(fetch.remoteName, "origin")
    XCTAssertEqual(fetch.upstreamName, "origin/main")
    XCTAssertTrue(fetch.message.contains("已 fetch origin"))
    XCTAssertEqual(report.remoteChangedFiles.map(\.displayPath), ["content/posts/remote.md"])
  }

  func testReadsRemoteArticleSnapshotFromConfiguredUpstream() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacRemoteSnapshotTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "base_url = \"https://example.com\"".write(
      to: rootURL.appendingPathComponent("config.toml"),
      atomically: true,
      encoding: .utf8
    )

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)

    try git(["switch", "-c", "remote-work"], rootURL: rootURL)
    try """
    ---
    title: "Remote Article"
    slug: remote-article
    ---

    Remote body
    """.write(
      to: rootURL.appendingPathComponent("content/posts/remote.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "content/posts/remote.md"], rootURL: rootURL)
    try git(["commit", "-m", "Remote article"], rootURL: rootURL)
    let remoteCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)
    let remoteBlobSHA = try git(["rev-parse", "\(remoteCommit):content/posts/remote.md"], rootURL: rootURL)

    try git(["switch", "main"], rootURL: rootURL)
    try git(["remote", "add", "origin", "https://example.invalid/site.git"], rootURL: rootURL)
    try git(["update-ref", "refs/remotes/origin/main", remoteCommit], rootURL: rootURL)
    try "local shadow\n".write(
      to: rootURL.appendingPathComponent("README-local-shadow.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "README-local-shadow.md"], rootURL: rootURL)
    try git(["commit", "-m", "Local origin main shadow"], rootURL: rootURL)
    let localOriginMainCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)
    try git(["update-ref", "refs/heads/origin/main", localOriginMainCommit], rootURL: rootURL)
    try git(["config", "branch.main.remote", "origin"], rootURL: rootURL)
    try git(["config", "branch.main.merge", "refs/heads/main"], rootURL: rootURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"

    let snapshot = try XCTUnwrap(
      LocalRepositoryService().remoteFileSnapshot(profile: profile, repositoryPath: "content/posts/remote.md")
    )

    XCTAssertEqual(snapshot.refName, "origin/main")
    XCTAssertEqual(snapshot.repositoryPath, "content/posts/remote.md")
    XCTAssertEqual(snapshot.repositorySHA, remoteBlobSHA)
    XCTAssertTrue(snapshot.content.contains("title: \"Remote Article\""))
    XCTAssertNil(LocalRepositoryService().remoteFileSnapshot(profile: profile, repositoryPath: "../secret.md"))
  }

  func testReadsRemoteArticleSnapshotsInInputOrderAndSkipsInvalidMissingAndDuplicatePaths() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacRemoteBatchSnapshotTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(
      to: rootURL.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)

    try git(["switch", "-c", "remote-work"], rootURL: rootURL)
    let firstPath = "content/posts/first.md"
    let secondPath = "content/posts/second.md"
    try "first remote body\n".write(
      to: rootURL.appendingPathComponent(firstPath),
      atomically: true,
      encoding: .utf8
    )
    try "second remote body\n".write(
      to: rootURL.appendingPathComponent(secondPath),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", firstPath, secondPath], rootURL: rootURL)
    try git(["commit", "-m", "Remote articles"], rootURL: rootURL)
    let remoteCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)
    let firstBlobSHA = try git(["rev-parse", "\(remoteCommit):\(firstPath)"], rootURL: rootURL)
    let secondBlobSHA = try git(["rev-parse", "\(remoteCommit):\(secondPath)"], rootURL: rootURL)

    try git(["switch", "main"], rootURL: rootURL)
    try git(["remote", "add", "origin", "https://example.invalid/site.git"], rootURL: rootURL)
    try git(["update-ref", "refs/remotes/origin/main", remoteCommit], rootURL: rootURL)
    try git(["config", "branch.main.remote", "origin"], rootURL: rootURL)
    try git(["config", "branch.main.merge", "refs/heads/main"], rootURL: rootURL)

    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"

    let commandLogURL = rootURL.appendingPathComponent("git-invocations.log")
    let wrapperURL = rootURL.appendingPathComponent("git-wrapper.sh")
    let shellQuotedLogPath = commandLogURL.path.replacingOccurrences(of: "'", with: "'\\''")
    try """
    #!/bin/sh
    args=" $* "
    case "$args" in
      *" status "*) printf '%s\\n' status >> '\(shellQuotedLogPath)' ;;
      *"rev-parse --abbrev-ref --symbolic-full-name @{upstream}"*) printf '%s\\n' upstream >> '\(shellQuotedLogPath)' ;;
    esac
    exec /usr/bin/git "$@"
    """.write(to: wrapperURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: wrapperURL.path
    )

    let service = LocalRepositoryService(
      gitCommandRunner: GitCommandRunner(executableURL: wrapperURL)
    )
    let snapshots = service.remoteFileSnapshots(
      profile: profile,
      repositoryPaths: [
        secondPath,
        "../secret.md",
        "./\(firstPath)",
        secondPath,
        "content/posts/missing.md",
      ]
    )

    XCTAssertEqual(snapshots.map(\.repositoryPath), [secondPath, firstPath])
    XCTAssertEqual(snapshots.map(\.refName), ["origin/main", "origin/main"])
    XCTAssertEqual(snapshots.map(\.repositorySHA), [secondBlobSHA, firstBlobSHA])
    XCTAssertEqual(snapshots.map(\.content), ["second remote body", "first remote body"])
    let commandLog = try String(contentsOf: commandLogURL, encoding: .utf8)
    XCTAssertEqual(commandLog.split(whereSeparator: \.isNewline).filter { $0 == "status" }.count, 0)
    XCTAssertEqual(commandLog.split(whereSeparator: \.isNewline).filter { $0 == "upstream" }.count, 1)

    let cancellationProbe = LocalRepositoryCancellationProbe(cancelAfterCheck: 5)
    let cancelledSnapshots = service.remoteFileSnapshots(
      rootURL: rootURL,
      repositoryPaths: [secondPath, firstPath],
      repositoryProvider: .github,
      cancellationCheck: cancellationProbe.shouldCancel
    )
    XCTAssertEqual(cancelledSnapshots.map(\.repositoryPath), [secondPath])
  }

  func testReadsGitLabRemoteArticleSnapshotWithLastCommitID() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacGitLabRemoteSnapshotTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "base_url = \"https://example.com\"".write(
      to: rootURL.appendingPathComponent("config.toml"),
      atomically: true,
      encoding: .utf8
    )

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)

    try git(["switch", "-c", "remote-work"], rootURL: rootURL)
    try """
    ---
    title: "GitLab Remote Article"
    slug: gitlab-remote-article
    ---

    GitLab remote body
    """.write(
      to: rootURL.appendingPathComponent("content/posts/gitlab-remote.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "content/posts/gitlab-remote.md"], rootURL: rootURL)
    try git(["commit", "-m", "GitLab remote article"], rootURL: rootURL)
    let articleCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)
    try "unrelated remote change\n".write(
      to: rootURL.appendingPathComponent("README-unrelated.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "README-unrelated.md"], rootURL: rootURL)
    try git(["commit", "-m", "GitLab unrelated remote change"], rootURL: rootURL)
    let remoteTip = try git(["rev-parse", "HEAD"], rootURL: rootURL)

    try git(["switch", "main"], rootURL: rootURL)
    try git(["remote", "add", "origin", "https://example.invalid/site.git"], rootURL: rootURL)
    try git(["update-ref", "refs/remotes/origin/main", remoteTip], rootURL: rootURL)
    try git(["config", "branch.main.remote", "origin"], rootURL: rootURL)
    try git(["config", "branch.main.merge", "refs/heads/main"], rootURL: rootURL)

    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"

    let snapshot = try XCTUnwrap(
      LocalRepositoryService().remoteFileSnapshot(profile: profile, repositoryPath: "content/posts/gitlab-remote.md")
    )

    XCTAssertEqual(snapshot.refName, "origin/main")
    XCTAssertEqual(snapshot.repositoryPath, "content/posts/gitlab-remote.md")
    XCTAssertEqual(snapshot.repositorySHA, articleCommit)
    XCTAssertNotEqual(articleCommit, remoteTip)
    XCTAssertTrue(snapshot.content.contains("title: \"GitLab Remote Article\""))
  }

  func testScanDetectsGitHubOriginRemoteForReviewRequests() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacRemoteTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "base_url = \"https://example.com\"".write(
      to: rootURL.appendingPathComponent("config.toml"),
      atomically: true,
      encoding: .utf8
    )

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["remote", "add", "origin", "git@github.com:jinfang/site.git"], rootURL: rootURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    profile.assetRoot = "static"

    let report = LocalRepositoryService().scan(profile: profile)

    XCTAssertEqual(report.originRemote?.provider, .github)
    XCTAssertEqual(report.originRemote?.repositoryBaseURL, "https://api.github.com")
    XCTAssertEqual(report.originRemote?.owner, "jinfang")
    XCTAssertEqual(report.originRemote?.name, "site")
    XCTAssertEqual(report.originRemote?.displayName, "GitHub jinfang/site")
  }

  func testRemoteParserRedactsHTTPSOriginCredentialsAndQuerySecrets() throws {
    let remote = try XCTUnwrap(
      LocalRepositoryService().parseRepositoryRemote(
        "https://oauth-user:super-secret@github.com/owner/site.git?access_token=query-secret#fragment"
      )
    )

    XCTAssertEqual(remote.provider, .github)
    XCTAssertEqual(remote.owner, "owner")
    XCTAssertEqual(remote.name, "site")
    XCTAssertEqual(remote.remoteURL, "https://github.com/owner/site.git")
    XCTAssertFalse(remote.remoteURL.contains("oauth-user"))
    XCTAssertFalse(remote.remoteURL.contains("super-secret"))
    XCTAssertFalse(remote.remoteURL.contains("query-secret"))
  }

  func testRemoteParserRedactsSCPOriginCredentialPrefix() throws {
    let remote = try XCTUnwrap(
      LocalRepositoryService().parseRepositoryRemote(
        "oauth2:super-secret@gitlab.com:group/site.git"
      )
    )

    XCTAssertEqual(remote.provider, .gitlab)
    XCTAssertEqual(remote.owner, "group")
    XCTAssertEqual(remote.name, "site")
    XCTAssertEqual(remote.remoteURL, "gitlab.com:group/site.git")
    XCTAssertFalse(remote.remoteURL.contains("oauth2"))
    XCTAssertFalse(remote.remoteURL.contains("super-secret"))
  }

  func testReportsDetachedHeadAsRepositoryPreflightError() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacDetachedTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "base_url = \"https://example.com\"".write(
      to: rootURL.appendingPathComponent("config.toml"),
      atomically: true,
      encoding: .utf8
    )
    try "# Hello".write(
      to: rootURL.appendingPathComponent("content/posts/hello.md"),
      atomically: true,
      encoding: .utf8
    )

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try git(["add", "."], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)
    try git(["checkout", "--detach", "HEAD"], rootURL: rootURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    profile.assetRoot = "static"

    let report = LocalRepositoryService().scan(profile: profile)

    XCTAssertTrue(report.branchStatus?.isDetached == true)
    XCTAssertTrue(report.preflightIssues.contains { issue in
      issue.severity == .error && issue.title == "当前是 Detached HEAD"
    })
  }

  func testScanIncludesLineDiffsForRepositoryChangedFiles() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacDiffTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "base_url = \"https://example.com\"".write(
      to: rootURL.appendingPathComponent("config.toml"),
      atomically: true,
      encoding: .utf8
    )

    let articleURL = rootURL.appendingPathComponent("content/posts/hello.md")
    try "old title\nold body\n".write(to: articleURL, atomically: true, encoding: .utf8)
    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try git(["add", "."], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)
    try "new title\nold body\n".write(to: articleURL, atomically: true, encoding: .utf8)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    profile.assetRoot = "static"

    let report = LocalRepositoryService().scan(profile: profile)
    let changedArticle = try XCTUnwrap(report.changedFiles.first { $0.path == "content/posts/hello.md" })

    XCTAssertEqual(changedArticle.kind, .modified)
    XCTAssertTrue(changedArticle.lineDiff?.contains("-old title") == true)
    XCTAssertTrue(changedArticle.lineDiff?.contains("+new title") == true)
  }

  func testClassifiesChangedFilesByPublishingRole() {
    let report = RepositoryScanReport(
      rootPath: "/site",
      detectedKind: .zola,
      expectedKind: .zola,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 0,
      imageFileCount: 0,
      changedFiles: [
        RepositoryChangedFile(status: " M", path: "content/posts/mac-editor.md", kind: .modified),
        RepositoryChangedFile(status: "R ", path: "content/old.md -> content/posts/new-name.md", kind: .renamed),
        RepositoryChangedFile(status: "??", path: "private/posts/private-note.md", kind: .untracked),
        RepositoryChangedFile(status: "??", path: "static/images/cover.webp", kind: .untracked),
        RepositoryChangedFile(status: " M", path: "config.toml", kind: .modified),
        RepositoryChangedFile(status: " M", path: "README.md", kind: .modified),
      ],
      preflightIssues: []
    )

    let summary = report.changeSummary(contentRoot: "content", assetRoot: "static")

    XCTAssertEqual(summary.articleCount, 3)
    XCTAssertEqual(summary.imageCount, 1)
    XCTAssertEqual(summary.configurationCount, 1)
    XCTAssertEqual(summary.otherCount, 1)
    XCTAssertEqual(summary.publishRelevantCount, 5)
    XCTAssertEqual(
      report.changedFiles(role: .article, contentRoot: "content", assetRoot: "static").map(\.path),
      ["content/posts/mac-editor.md", "content/old.md -> content/posts/new-name.md", "private/posts/private-note.md"]
    )
  }

  func testBuildsChangeQueueSectionsInPublishingOrder() {
    let report = RepositoryScanReport(
      rootPath: "/site",
      detectedKind: .zola,
      expectedKind: .zola,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 0,
      imageFileCount: 0,
      changedFiles: [
        RepositoryChangedFile(status: " M", path: "README.md", kind: .modified),
        RepositoryChangedFile(status: " M", path: "config.toml", kind: .modified),
        RepositoryChangedFile(status: "??", path: "static/images/cover.webp", kind: .untracked),
        RepositoryChangedFile(status: " M", path: "content/posts/mac-editor.md", kind: .modified),
        RepositoryChangedFile(status: "R ", path: "content/old.md -> content/posts/new-name.md", kind: .renamed),
        RepositoryChangedFile(status: "??", path: "private/posts/private-note.md", kind: .untracked),
      ],
      preflightIssues: []
    )

    let sections = report.changeQueueSections(contentRoot: "content", assetRoot: "static")

    XCTAssertEqual(sections.map(\.role), [.article, .image, .configuration, .other])
    XCTAssertEqual(sections.map(\.title), ["文章变更", "图片变更", "配置变更", "其他变更"])
    XCTAssertEqual(sections.map(\.count), [3, 1, 1, 1])
    XCTAssertEqual(sections.first?.files.map(\.displayPath), ["content/posts/mac-editor.md", "content/posts/new-name.md", "private/posts/private-note.md"])
    XCTAssertTrue(sections[0].role.isPublishRelevant)
    XCTAssertFalse(sections[3].role.isPublishRelevant)
  }

  @discardableResult
  private func git(_ arguments: [String], rootURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", rootURL.path] + arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "LocalRepositoryServiceTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: output + error]
      )
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func makeBranchOperationRepository() throws -> (URL, SiteProfile) {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacBranchOperationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    do {
      try git(["init", "-b", "main"], rootURL: rootURL)
      try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
      try git(["config", "user.name", "Tests"], rootURL: rootURL)
      try "initial\n".write(
        to: rootURL.appendingPathComponent("README.md"),
        atomically: true,
        encoding: .utf8
      )
      try git(["add", "README.md"], rootURL: rootURL)
      try git(["commit", "-m", "Initial"], rootURL: rootURL)
    } catch {
      try? FileManager.default.removeItem(at: rootURL)
      throw error
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    return (rootURL, profile)
  }

  private func makeAutoConfigurationRepository(named name: String) throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "RepositoryAutoConfigurationTests-\(name)-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    return rootURL.resolvingSymlinksInPath()
  }

  private struct AutoConfigurationFixture {
    let name: String
    let directories: [String]
    let files: [String: String]
    let expectedKind: SiteKind
    let expectedContentRoot: String
    let expectedAssetRoot: String
    let expectedFrontMatterStyle: FrontMatterStyle
    let expectedMarkdownPathPattern: String
  }
}

private final class LocalRepositoryCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let cancelAfterCheck: Int
  private var checkCount = 0

  init(cancelAfterCheck: Int) {
    self.cancelAfterCheck = cancelAfterCheck
  }

  func shouldCancel() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    checkCount += 1
    return checkCount >= cancelAfterCheck
  }
}
