#if DEBUG || SCREENSHOT_CAPTURE_BUILD
import Foundation

public struct ScreenshotDemoDataService {
  public static let environmentKey = "PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO"
  public static let surfaceEnvironmentKey = "PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE"
  public static let knowledgeRootEnvironmentKey = "PERSONAL_SITE_PUBLISHER_SCREENSHOT_KNOWLEDGE_ROOT"
  public static let uiTestEnvironmentKey = "PERSONAL_SITE_PUBLISHER_SCREENSHOT_UI_TEST"
  public static let uiTestRepositoryRootEnvironmentKey = "PERSONAL_SITE_PUBLISHER_SCREENSHOT_UI_TEST_REPOSITORY_ROOT"
  public static let persistenceFilename = "screenshot-demo-workbench.json"

  public init() {}

  private static func demoUUID(_ value: String) -> UUID {
    UUID(uuidString: value) ?? UUID(uuid: (
      0, 0, 0, 0,
      0, 0,
      0, 0,
      0, 0,
      0, 0, 0, 0, 0, 0
    ))
  }

  public func makeSnapshot(now: Date = Date(timeIntervalSince1970: 1_900_000_000)) -> WorkbenchSnapshot {
    let profileID = Self.demoUUID("11111111-1111-4111-8111-111111111111")
    let articleID = Self.demoUUID("22222222-2222-4222-8222-222222222222")
    let privateArticleID = Self.demoUUID("33333333-3333-4333-8333-333333333333")
    let secondProfileID = Self.demoUUID("44444444-4444-4444-8444-444444444444")
    let crossSiteDraftID = Self.demoUUID("55555555-5555-4555-8555-555555555555")
    let directRecordID = Self.demoUUID("66666666-6666-4666-8666-666666666666")
    let reviewRecordID = Self.demoUUID("77777777-7777-4777-8777-777777777777")
    let failedRecordID = Self.demoUUID("88888888-8888-4888-8888-888888888888")

    var profile = SiteProfile.defaultProfile
    profile.id = profileID
    profile.name = "示例个人网站"
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "demo-owner"
    profile.repoName = "demo-site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .reviewRequest
    profile.deploymentProvider = .githubPages
    profile.deploymentSiteURL = "https://demo.example.com"
    profile.deploymentStatusEndpointURL = "https://status.example.com/demo-site"
    profile.deploymentProjectID = "demo-site"
    profile.deploymentAccountID = "demo-team"
    profile.deploymentStatusEndpointUsesToken = true
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.com/v1",
      model: "custom-review-model",
      requiresAPIKey: true
    )

    var secondProfile = SiteProfile.defaultProfile
    secondProfile.id = secondProfileID
    secondProfile.name = "示例项目网站"
    secondProfile.repoOwner = "demo-owner"
    secondProfile.repoName = "demo-project-site"
    secondProfile.branch = "main"

    let cover = DraftAttachment(
      originalFilename: "social-preview.png",
      relativePublishPath: "/images/2026/social-preview.png",
      repositoryPath: "static/images/2026/social-preview.png",
      altText: "桌面发布控制台的 SEO 社交卡片预览",
      caption: "安全演示图，不包含真实路径或账号。",
      byteSize: 248_000
    )
    let article = ArticleDraft(
      id: articleID,
      siteProfileID: profileID,
      title: "RepoPress Studio 发布流程",
      date: now.addingTimeInterval(-86_400),
      slug: "repopress-studio-publishing-flow",
      tags: ["发布", "SEO", "静态站点"],
      categories: ["Product"],
      authors: ["Demo Author"],
      draft: false,
      summary: "演示写作、SEO 社交预览、GitHub API 发布和发布后部署校验的完整桌面流程。",
      coverAttachmentID: cover.id,
      bodyMarkdown: """
      # RepoPress Studio 发布流程

      这是一篇用于 App Store 截图的演示文章，所有账号、URL 和路径都是安全示例。

      ## 发布前检查

      - 通过 Front Matter、摘要、封面图和公开风险检查。
      - 在写作页审阅标题、摘要、元数据和关联文章。
      - 通过 GitHub/GitLab API 发布前预检确认权限和远端冲突。

      ## 发布后校验

      部署状态面板会汇总 GitHub Pages、Actions、状态端点和文章页面内容校验。
      """,
      attachments: [cover],
      status: .ready,
      createdAt: now.addingTimeInterval(-172_800),
      updatedAt: now.addingTimeInterval(-3_600),
      repositoryPath: "content/posts/2026/repopress-studio-publishing-flow.md",
      repositorySHA: "demo-local-sha"
    )
    let privateArticle = ArticleDraft(
      id: privateArticleID,
      siteProfileID: profileID,
      title: "私密客户复盘草稿",
      date: now.addingTimeInterval(-43_200),
      slug: "private-client-review",
      tags: ["Private"],
      categories: ["Notes"],
      authors: ["Demo Author"],
      draft: true,
      visibility: .private,
      summary: "这篇私密草稿用于验证列表和概览遮挡，不应出现在公开截图细节中。",
      bodyMarkdown: "# 私密客户复盘草稿\n\n这段正文只用于验证遮挡策略。",
      status: .draft,
      createdAt: now.addingTimeInterval(-100_000),
      updatedAt: now.addingTimeInterval(-1_800)
    )
    let crossSiteDraft = ArticleDraft(
      id: crossSiteDraftID,
      siteProfileID: secondProfileID,
      scope: .general,
      title: "通用发布检查模板",
      date: now.addingTimeInterval(-7_200),
      slug: "cross-site-publish-checklist",
      tags: ["Checklist", "Template"],
      categories: ["Reusable"],
      authors: ["Demo Author"],
      draft: true,
      summary: "可复用到多个站点的发布前检查模板。",
      bodyMarkdown: "# 通用发布检查模板\n\n- 标题\n- 摘要\n- 封面\n- 链接\n- 部署状态\n",
      status: .ready,
      createdAt: now.addingTimeInterval(-50_000),
      updatedAt: now.addingTimeInterval(-900)
    )

    let directRecord = ReleaseRecord(
      id: directRecordID,
      kind: .remoteDirectCommit,
      title: "线上提交：RepoPress Studio 发布流程",
      summary: "GitHub · main · 2 个文件 · abc123de",
      siteProfileID: profileID,
      siteName: profile.name,
      draftID: articleID,
      draftTitle: article.title,
      markdownPath: "content/posts/2026/repopress-studio-publishing-flow.md",
      changedPaths: [
        "content/posts/2026/repopress-studio-publishing-flow.md",
        "static/images/2026/social-preview.png",
      ],
      repositoryProvider: .github,
      repositoryBaseURL: RepositoryProvider.github.defaultBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: "main",
      targetBranch: "main",
      commitSHA: "abc123def4567890abc123def4567890abc123de",
      createdAt: now.addingTimeInterval(-1_200)
    )
    let reviewRecord = ReleaseRecord(
      id: reviewRecordID,
      kind: .remoteReviewRequest,
      title: "线上 PR/MR：跨站点素材整理",
      summary: "GitHub · publish/cross-site-assets · 1 个文件",
      siteProfileID: profileID,
      siteName: profile.name,
      draftTitle: "跨站点素材整理",
      markdownPath: "content/posts/2026/cross-site-assets.md",
      changedPaths: ["content/posts/2026/cross-site-assets.md"],
      repositoryProvider: .github,
      repositoryBaseURL: RepositoryProvider.github.defaultBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: "publish/cross-site-assets",
      targetBranch: "main",
      reviewURL: "https://github.com/demo-owner/demo-site/pull/42",
      reviewTitle: "Publish cross-site assets",
      createdAt: now.addingTimeInterval(-900)
    )
    let failedRecord = ReleaseRecord(
      id: failedRecordID,
      kind: .remotePublishFailure,
      title: "线上发布失败：旧文整理",
      summary: "远端冲突：content/posts/2026/stale-cleanup.md 已在 upstream 更新。",
      siteProfileID: profileID,
      siteName: profile.name,
      draftTitle: "旧文整理",
      markdownPath: "content/posts/2026/stale-cleanup.md",
      changedPaths: ["content/posts/2026/stale-cleanup.md"],
      repositoryProvider: .github,
      repositoryBaseURL: RepositoryProvider.github.defaultBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: "main",
      targetBranch: "main",
      commitSHA: "fedcba9876543210fedcba9876543210fedcba98",
      createdAt: now.addingTimeInterval(-600)
    )

    let deploymentSnapshot = DeploymentStatusSnapshot(
      profileID: profileID,
      releaseRecordID: directRecordID,
      provider: .githubPages,
      level: .success,
      title: "GitHub Pages · 正常",
      message: "Pages、Actions 和文章页面内容校验均已通过。",
      siteURLText: "https://demo.example.com",
      checkedAt: now.addingTimeInterval(-300),
      signals: [
        DeploymentStatusSignal(
          level: .success,
          title: "GitHub Pages",
          message: "Pages 状态：built",
          urlText: "https://demo.example.com"
        ),
        DeploymentStatusSignal(
          level: .success,
          title: "Deploy Pages",
          message: "completed / success",
          urlText: "https://github.com/demo-owner/demo-site/actions/runs/100"
        ),
        DeploymentStatusSignal(
          level: .success,
          title: "发布页面内容",
          message: "已在发布页面找到文章标题：\(article.title)",
          urlText: "https://demo.example.com/repopress-studio-publishing-flow"
        ),
      ]
    )

    let seoSnapshot = SEOSocialPreviewSnapshot(
      draftID: articleID,
      signature: "screenshot-demo",
      markdownPath: "content/posts/2026/repopress-studio-publishing-flow.md",
      canonicalURLText: "https://demo.example.com/repopress-studio-publishing-flow",
      titleCharacterCount: article.title.count,
      descriptionCharacterCount: article.summary.count,
      imagePath: cover.relativePublishPath,
      imageDimensions: ImageDimensions(width: 1200, height: 630),
      shareHashtags: ["Mac", "Publishing", "SEO"],
      cards: [
        SEOSocialPreviewCard(
          kind: .search,
          title: article.title,
          description: article.summary,
          urlText: "https://demo.example.com/repopress-studio-publishing-flow",
          imagePath: nil,
          imageAltText: nil,
          siteName: profile.name
        ),
        SEOSocialPreviewCard(
          kind: .openGraph,
          title: article.title,
          description: article.summary,
          urlText: "https://demo.example.com/repopress-studio-publishing-flow",
          imagePath: cover.relativePublishPath,
          imageAltText: cover.altText,
          imageDimensions: ImageDimensions(width: 1200, height: 630),
          siteName: profile.name
        ),
        SEOSocialPreviewCard(
          kind: .twitter,
          title: article.title,
          description: article.summary,
          urlText: "https://demo.example.com/repopress-studio-publishing-flow",
          imagePath: cover.relativePublishPath,
          imageAltText: cover.altText,
          imageDimensions: ImageDimensions(width: 1200, height: 630),
          siteName: profile.name
        ),
      ],
      metaTags: [
        SEOSocialPreviewMetaTag(scope: .openGraph, property: "og:title", content: article.title),
        SEOSocialPreviewMetaTag(scope: .openGraph, property: "og:image", content: cover.relativePublishPath),
        SEOSocialPreviewMetaTag(scope: .twitter, property: "twitter:card", content: "summary_large_image"),
      ],
      findings: [
        SEOAuditFinding(severity: .info, title: "社交预览演示", message: "Open Graph 和 Twitter 卡片已生成。")
      ],
      generatedAt: now.addingTimeInterval(-240)
    )

    return WorkbenchSnapshot(
      profiles: [profile, secondProfile],
      activeProfileID: profileID,
      drafts: [article, privateArticle, crossSiteDraft],
      releaseRecords: [directRecord, reviewRecord, failedRecord],
      seoSocialPreviewSnapshots: [seoSnapshot],
      privacySettings: PrivacyProtectionSettings(
        masksPrivateContent: true
      ),
      repositoryAutoSyncSettings: RepositoryAutoSyncSettings(
        isEnabled: true,
        intervalMinutes: 15,
        fetchBeforeScan: true
      ),
      deploymentPollingSettings: DeploymentPollingSettings(
        isEnabled: true,
        intervalMinutes: 10
      ),
      deploymentPollingState: DeploymentPollingState(
        status: .checked,
        lastRunAt: now.addingTimeInterval(-300),
        nextRunAt: now.addingTimeInterval(300),
        checkedRecordCount: 1,
        checkedRecords: [
          DeploymentPollingRecordSummary(
            recordID: directRecordID,
            title: article.title,
            provider: .githubPages,
            level: .success,
            message: deploymentSnapshot.message,
            checkedAt: deploymentSnapshot.checkedAt
          )
        ],
        message: "部署轮询已检查 1 条待部署记录：正常 1，部署中 0。"
      ),
      deploymentStatusSnapshots: [deploymentSnapshot]
    )
  }

  public static var isEnabledFromEnvironment: Bool {
    let value = ProcessInfo.processInfo.environment[environmentKey]?.lowercased()
    return value == "1" || value == "true" || value == "yes"
  }

  public static var requestedSurfaceFromEnvironment: ScreenshotDemoSurface? {
    let rawValue = ProcessInfo.processInfo.environment[surfaceEnvironmentKey]
    return rawValue.flatMap(ScreenshotDemoSurface.init(rawValue:))
  }

  public static var defaultPersistenceURL: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
      .appendingPathComponent(persistenceFilename)
  }

  public static var defaultKnowledgeLibraryRootURL: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
      .appendingPathComponent("screenshot-demo-knowledge-library-review-v2", isDirectory: true)
  }

  public static var defaultRepositoryRootURL: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
      .appendingPathComponent("screenshot-demo-repository", isDirectory: true)
  }

  public static func prepareKnowledgeLibraryServiceIfEnabled() -> KnowledgeLibraryService {
    guard isEnabledFromEnvironment,
          requestedSurfaceFromEnvironment == .knowledgeLibrary else {
      return KnowledgeLibraryService()
    }
    let configuredPath = ProcessInfo.processInfo.environment[knowledgeRootEnvironmentKey].map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let rootURL = configuredPath.flatMap { path in
      path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    } ?? defaultKnowledgeLibraryRootURL
    try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return KnowledgeLibraryService(rootURL: rootURL)
  }

  public static func preparePersistenceIfEnabled() -> WorkbenchPersistence {
    guard isEnabledFromEnvironment else {
      return WorkbenchPersistence()
    }
    let persistence = WorkbenchPersistence(fileURL: defaultPersistenceURL)
    _ = try? persistence.save(ScreenshotDemoDataService().makeSnapshot())
    return persistence
  }

  @MainActor
  public static func applyRequestedSurfaceIfEnabled(to store: WorkbenchStore) {
    guard isEnabledFromEnvironment, let surface = requestedSurfaceFromEnvironment else {
      return
    }
    surface.apply(to: store)
    let isUITest = ProcessInfo.processInfo.environment[uiTestEnvironmentKey] == "1"
    if isUITest || surface == .syncAPIPublish {
      prepareRepositoryFixture(in: store, isUITest: isUITest)
      if surface == .syncAPIPublish {
        seedSyncAPIPublishPreview(in: store)
      }
      // The publish-drawer UI test must always expose its intended "Open
      // Publish" action. A concurrent scan temporarily replaces that action
      // with "Cancel Scan", making the fixture depend on runner speed.
      if !(isUITest && surface == .syncAPIPublish) {
        Task { @MainActor in
          await store.repository.scanAsync()
          if surface == .syncAPIPublish {
            seedSyncAPIPublishPreview(in: store)
          }
        }
      }
    }
    if surface == .writing,
       isUITest {
      // Sidebar accessibility coverage does not exercise the AppKit Markdown
      // editor. Leave the deterministic list populated but avoid mounting an
      // unrelated editor during this focused UI test.
      store.selectDraft(nil)
    }
    if surface == .knowledgeLibrary {
      Task { @MainActor in
        await seedKnowledgeLibraryIfEnabled(in: store.knowledge)
      }
    }
  }

  @MainActor
  private static func prepareRepositoryFixture(in store: WorkbenchStore, isUITest: Bool) {
    let configuredPath = isUITest
      ? ProcessInfo.processInfo.environment[uiTestRepositoryRootEnvironmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      : nil
    let rootURL = configuredPath.flatMap { path in
      path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    } ?? (isUITest
      ? FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonalSitePublisherMac-AccessibilityUITestRepository", isDirectory: true)
      : defaultRepositoryRootURL)

    let contentURL = rootURL.appendingPathComponent("content/posts/2026", isDirectory: true)
    let imageURL = rootURL.appendingPathComponent("static/images", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: imageURL, withIntermediateDirectories: true)
      try writeFixtureFileIfMissing(
        at: rootURL.appendingPathComponent("config.toml"),
        contents: "base_url = \"https://demo.example.com\"\ntitle = \"截图演示站点\"\n"
      )
      try writeFixtureFileIfMissing(
        at: contentURL.appendingPathComponent("repopress-studio-publishing-flow.md"),
        contents: "+++\ntitle = \"RepoPress Studio 发布流程\"\ndraft = false\n+++\n\n# RepoPress Studio 发布流程\n"
      )
    } catch {
      store.setPublishActionMessage(String(localized: "无法准备运行时辅助功能测试仓库。"), status: .failure)
      return
    }

    var profile = store.activeProfile
    profile.localRepositoryRootPath = rootURL.standardizedFileURL.path
    profile.localRepositoryBookmarkData = nil
    store.updateActiveProfile(profile)
  }

  @MainActor
  private static func seedSyncAPIPublishPreview(in store: WorkbenchStore) {
    guard let draft = store.selectedDraft else { return }

    let profile = store.profile(for: draft)
    store.setRepositoryReport(
      RepositoryScanReport(
        rootPath: profile.localRepositoryRootPath,
        detectedKind: profile.siteKind,
        expectedKind: profile.siteKind,
        hasGitDirectory: true,
        contentRootExists: true,
        assetRootExists: true,
        markdownFileCount: 1,
        imageFileCount: 1,
        changedFiles: [],
        remoteChangedFiles: [],
        preflightIssues: [],
        scannedAt: Date(timeIntervalSince1970: 1_900_000_000)
      )
    )
    let accessCheck = RemoteRepositoryAccessCheck(
      provider: profile.repositoryProvider,
      repositoryName: profile.repositoryDisplayName,
      defaultBranch: profile.branch,
      canRead: true,
      canWrite: true,
      permissionSummary: "截图演示：已确认仓库内容写入权限。",
      tokenScopeSummary: "Repository contents: write",
      message: "截图演示：Token 权限检查已通过。"
    )
    let conflictPath = "content/posts/2026/repopress-studio-publishing-flow.md"
    let conflictWarning = PreflightIssue(
      severity: .warning,
      title: "远端同路径变更",
      message: "截图演示：上游也更新了当前文章；可先查看差异，或改用 PR/MR 审阅流程。",
      field: "repository"
    )

    store.setRepositoryTokenAvailability(
      KeychainTokenAvailability(hasToken: true, updatedAt: Date(timeIntervalSince1970: 1_900_000_000))
    )
    store.setRemoteRepositoryAccessCheck(accessCheck)
    store.refreshPublishPreview(for: draft)
    store.publishingStore.localPublishReadiness = LocalPublishReadiness(
      writeReadiness: .ready,
      commitReadiness: .ready,
      changedFileCount: 1,
      fileCount: 1,
      writeBlockingIssues: [],
      commitBlockingIssues: [],
      warningIssues: [conflictWarning]
    )

    var preview = store.remotePublishPreviewSnapshot ?? RemoteRepositoryPublishPreview(
      provider: profile.repositoryProvider,
      repositoryName: profile.repositoryDisplayName,
      mode: .reviewRequest,
      branchName: "publish/repopress-studio-publishing-flow",
      targetBranch: profile.branch,
      changedPaths: [
        conflictPath,
        "static/images/2026/social-preview.png",
      ],
      hasToken: true,
      blockingIssues: [],
      warningIssues: []
    )
    preview.mode = .reviewRequest
    preview.branchName = "publish/repopress-studio-publishing-flow"
    preview.changedPaths = [
      conflictPath,
      "static/images/2026/social-preview.png",
    ]
    preview.remoteConflictPaths = [conflictPath]
    preview.remoteRiskState = .conflict
    preview.hasToken = true
    preview.accessCheck = accessCheck
    preview.blockingIssues = []
    preview.warningIssues = [conflictWarning]
    store.publishingStore.remotePublishPreviewSnapshot = preview
    store.selectSection(.sync)
  }

  private static func writeFixtureFileIfMissing(at url: URL, contents: String) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    try Data(contents.utf8).write(to: url, options: .atomic)
  }

  @MainActor
  public static func seedKnowledgeLibraryIfEnabled(in knowledge: KnowledgeStore) async {
    guard isEnabledFromEnvironment,
          requestedSurfaceFromEnvironment == .knowledgeLibrary,
          knowledge.documents.isEmpty,
          let sourceURL = URL(string: "https://example.com/accessibility/knowledge-library") else {
      return
    }
    let capture = KnowledgeBrowserCapture(
      sourceURL: sourceURL,
      title: "资料库辅助功能演示",
      authors: ["Demo Author"],
      language: "zh-Hans",
      summary: "用于验证资料详情标题、阅读区和操作控件的辅助功能标识。",
      tags: ["辅助功能", "资料库"],
      contentText: """
      # 资料库辅助功能演示

      这是一份只保存在隔离测试资料库中的合成内容，不包含真实文章、账号或本机路径。

      ## 可访问性检查

      标题、阅读区、检查器开关、资料操作与导入按钮都应拥有唯一标识。
      """,
      captureMode: .cleanedArticle,
      allowsAIUse: false
    )
    _ = try? await knowledge.importBrowserCapture(
      capture,
      folderID: nil,
      newFolderName: nil
    )
  }
}

public enum ScreenshotDemoSurface: String, CaseIterable, Identifiable, Sendable {
  case writing
  case aiChat = "ai-chat"
  case syncAPIPublish = "sync-api-publish"
  case seoSocialPreview = "seo-social-preview"
  case deploymentStatus = "deployment-status"
  case maintenance
  case generalDrafts = "general-drafts"
  case quickHide = "privacy-lock"
  case knowledgeLibrary = "knowledge-library"

  public var id: String { rawValue }

  @MainActor
  public func apply(to store: WorkbenchStore) {
    store.deactivateQuickHide()
    if let draft = preferredDraft(in: store) {
      store.selectDraft(draft.id)
    }

    switch self {
    case .writing:
      store.selectSection(.writing)
      store.setEditorDisplayMode(.split)
      store.setPublishActionMessage(String(localized: "截图模式：写作工作区已载入演示文章。"), status: .information)
    case .aiChat:
      _ = store.openAIChatWorkspace(for: preferredDraft(in: store)?.id)
      store.seedTransientAIChatPreview([
        AIPublishingChatMessage(
          role: .user,
          content: "请从发布前角度检查这篇文章的标题、摘要、SEO 和发布风险。",
          contextMode: .site
        ),
        AIPublishingChatMessage(
          role: .assistant,
          content: "标题清晰，摘要覆盖写作、SEO、线上发布和部署校验。建议保留 Open Graph 图片，并在发布前确认远端冲突预览为空。",
          model: "custom-review-model",
          contextMode: .site
        ),
      ])
      store.setInspectorPresented(false)
      store.setPublishActionMessage(
          String(localized: "截图模式：免费自定义 API 的 AI 助手已载入。"), status: .information)
    case .syncAPIPublish:
      store.selectSection(.sync)
      store.setPublishActionMessage(
          String(localized: "截图模式：同步/API 发布工作区已载入。"), status: .information)
    case .seoSocialPreview:
      store.selectSection(.writing)
      store.setInspectorPresented(true)
      if let draft = preferredDraft(in: store) {
        store.refreshSEOSocialPreview(for: draft, message: "截图模式：SEO / 社交预览快照已载入。")
      }
    case .deploymentStatus:
      store.selectSection(.sync)
      store.setDeploymentStatusMessage("截图模式：部署状态和轮询记录已载入。")
    case .maintenance:
      store.selectSection(.contentHealth)
      store.setPublishActionMessage(String(localized: "截图模式：站点维护工作台已载入。"), status: .information)
    case .generalDrafts:
      store.selectSection(.writing)
      store.setDraftListContentScope(.general)
      store.setPublishActionMessage(String(localized: "截图模式：通用草稿已载入。"), status: .information)
    case .quickHide:
      store.selectSection(.writing)
      store.setInspectorPresented(true)
      store.activateQuickHide(reason: "工作台已手动隐藏，私密内容已遮挡。")
    case .knowledgeLibrary:
      store.selectSection(.library)
      store.setInspectorPresented(false)
      store.setPublishActionMessage(String(localized: "截图模式：本地资料库已载入。"), status: .information)
    }
  }

  @MainActor
  private func preferredDraft(in store: WorkbenchStore) -> ArticleDraft? {
    store.visibleDrafts.first { $0.status == .ready && !$0.isPrivate }
      ?? store.visibleDrafts.first { !$0.isPrivate }
      ?? store.visibleDrafts.first
  }
}
#endif
