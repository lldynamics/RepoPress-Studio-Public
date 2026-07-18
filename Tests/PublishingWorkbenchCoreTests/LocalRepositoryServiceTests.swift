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
    try git(["config", "branch.main.remote", "origin"], rootURL: rootURL)
    try git(["config", "branch.main.merge", "refs/heads/main"], rootURL: rootURL)
    XCTAssertEqual(try git(["merge-base", "main", "origin/main"], rootURL: rootURL), baseCommit)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    profile.assetRoot = "static"

    let report = LocalRepositoryService().scan(profile: profile)

    XCTAssertEqual(report.branchStatus?.branchName, "main")
    XCTAssertEqual(report.branchStatus?.upstreamName, "origin/main")
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
    let remoteCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)

    try git(["switch", "main"], rootURL: rootURL)
    try git(["remote", "add", "origin", "https://example.invalid/site.git"], rootURL: rootURL)
    try git(["update-ref", "refs/remotes/origin/main", remoteCommit], rootURL: rootURL)
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
    XCTAssertEqual(snapshot.repositorySHA, remoteCommit)
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

  func testScanRedactsHTTPSOriginCredentialsAndQuerySecrets() throws {
    let rootURL = try makeRemoteDetectionRepository(
      remoteURL: "https://oauth-user:super-secret@github.com/owner/site.git?access_token=query-secret#fragment"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)

    let remote = try XCTUnwrap(LocalRepositoryService().scan(profile: profile).originRemote)

    XCTAssertEqual(remote.provider, .github)
    XCTAssertEqual(remote.owner, "owner")
    XCTAssertEqual(remote.name, "site")
    XCTAssertEqual(remote.remoteURL, "https://github.com/owner/site.git")
    XCTAssertFalse(remote.remoteURL.contains("oauth-user"))
    XCTAssertFalse(remote.remoteURL.contains("super-secret"))
    XCTAssertFalse(remote.remoteURL.contains("query-secret"))
  }

  func testScanRedactsSCPOriginCredentialPrefix() throws {
    let rootURL = try makeRemoteDetectionRepository(
      remoteURL: "oauth2:super-secret@gitlab.com:group/site.git"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)

    let remote = try XCTUnwrap(LocalRepositoryService().scan(profile: profile).originRemote)

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

  private func makeRemoteDetectionRepository(remoteURL: String) throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacRemoteRedactionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    do {
      try git(["init", "-b", "main"], rootURL: rootURL)
      try git(["remote", "add", "origin", remoteURL], rootURL: rootURL)
      return rootURL
    } catch {
      try? FileManager.default.removeItem(at: rootURL)
      throw error
    }
  }
}
