#if DEBUG
import Foundation
import PublishingWorkbenchCore

public struct ScreenshotDemoDataService {
  public static let environmentKey = "PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO"
  public static let surfaceEnvironmentKey = "PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE"
  public static let persistenceFilename = "screenshot-demo-workbench.json"

  public init() {}

  public func makeSnapshot(now: Date = Date(timeIntervalSince1970: 1_900_000_000)) -> WorkbenchSnapshot {
    let profileID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let articleID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let privateArticleID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    let generalDraftProfileID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    let generalDraftID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    let directRecordID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    let reviewRecordID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    let failedRecordID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!

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

    var generalProfile = SiteProfile.defaultProfile
    generalProfile.id = generalDraftProfileID
    generalProfile.name = "素材库"
    generalProfile.purpose = .generalDraftBackup
    generalProfile.repoOwner = "demo-owner"
    generalProfile.repoName = "demo-notes"
    generalProfile.branch = "main"

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
      title: "Mac 个人网站发布控制台发布流程",
      date: now.addingTimeInterval(-86_400),
      slug: "mac-publishing-console-flow",
      tags: ["Mac", "发布", "SEO"],
      categories: ["Product"],
      authors: ["Demo Author"],
      draft: false,
      summary: "演示写作、AI 对话、SEO 社交预览、GitHub API 发布和发布后部署校验的完整桌面流程。",
      coverAttachmentID: cover.id,
      bodyMarkdown: """
      # Mac 个人网站发布控制台发布流程

      这是一篇用于 App Store 截图的演示文章，所有账号、URL 和路径都是安全示例。

      ## 发布前检查

      - 通过 Front Matter、摘要、封面图和公开风险检查。
      - 使用 AI 对话页审阅标题、摘要和关联文章。
      - 通过 GitHub/GitLab API 发布前预检确认权限和远端冲突。

      ## 发布后校验

      部署状态面板会汇总 GitHub Pages、Actions、状态端点和文章页面内容校验。
      """,
      attachments: [cover],
      status: .ready,
      createdAt: now.addingTimeInterval(-172_800),
      updatedAt: now.addingTimeInterval(-3_600),
      repositoryPath: "content/posts/2026/mac-publishing-console-flow.md",
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
    let generalDraft = ArticleDraft(
      id: generalDraftID,
      siteProfileID: generalDraftProfileID,
      title: "跨站点发布检查模板",
      date: now.addingTimeInterval(-7_200),
      slug: "cross-site-publish-checklist",
      tags: ["Checklist", "Template"],
      categories: ["Reusable"],
      authors: ["Demo Author"],
      draft: true,
      summary: "可复用到多个站点的发布前检查模板。",
      bodyMarkdown: "# 跨站点发布检查模板\n\n- 标题\n- 摘要\n- 封面\n- 链接\n- 部署状态\n",
      status: .ready,
      createdAt: now.addingTimeInterval(-50_000),
      updatedAt: now.addingTimeInterval(-900)
    )

    let directRecord = ReleaseRecord(
      id: directRecordID,
      kind: .remoteDirectCommit,
      title: "线上提交：Mac 个人网站发布控制台发布流程",
      summary: "GitHub · main · 2 个文件 · abc123de",
      siteProfileID: profileID,
      siteName: profile.name,
      draftID: articleID,
      draftTitle: article.title,
      markdownPath: "content/posts/2026/mac-publishing-console-flow.md",
      changedPaths: [
        "content/posts/2026/mac-publishing-console-flow.md",
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
          urlText: "https://demo.example.com/mac-publishing-console-flow"
        ),
      ]
    )

    let seoSnapshot = SEOSocialPreviewSnapshot(
      draftID: articleID,
      signature: "screenshot-demo",
      markdownPath: "content/posts/2026/mac-publishing-console-flow.md",
      canonicalURLText: "https://demo.example.com/mac-publishing-console-flow",
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
          urlText: "https://demo.example.com/mac-publishing-console-flow",
          imagePath: nil,
          imageAltText: nil,
          siteName: profile.name
        ),
        SEOSocialPreviewCard(
          kind: .openGraph,
          title: article.title,
          description: article.summary,
          urlText: "https://demo.example.com/mac-publishing-console-flow",
          imagePath: cover.relativePublishPath,
          imageAltText: cover.altText,
          imageDimensions: ImageDimensions(width: 1200, height: 630),
          siteName: profile.name
        ),
        SEOSocialPreviewCard(
          kind: .twitter,
          title: article.title,
          description: article.summary,
          urlText: "https://demo.example.com/mac-publishing-console-flow",
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

    let chatState = AIPublishingChatSessionState(
      messages: [
        AIPublishingChatMessage(
          role: .user,
          content: "请从发布前角度检查这篇文章的标题、摘要、SEO 和发布风险。",
          contextMode: .site,
          createdAt: now.addingTimeInterval(-500)
        ),
        AIPublishingChatMessage(
          role: .assistant,
          content: "标题清晰，摘要覆盖写作、SEO、线上发布和部署校验。建议保留 Open Graph 图片，并在发布前确认远端冲突预览为空。",
          model: "deepseek-v4-flash",
          contextMode: .site,
          createdAt: now.addingTimeInterval(-460)
        ),
      ],
      contextMode: .site,
      modelGrade: .standard,
      selectedModel: "deepseek-v4-flash"
    )

    return WorkbenchSnapshot(
      profiles: [profile, generalProfile],
      activeProfileID: profileID,
      drafts: [article, privateArticle, generalDraft],
      releaseRecords: [directRecord, reviewRecord, failedRecord],
      aiChatSessionsByDraftID: [articleID: chatState],
      seoSocialPreviewSnapshots: [seoSnapshot],
      privacySettings: PrivacyProtectionSettings(
        requiresUnlockOnLaunch: false,
        locksWhenInactive: true,
        masksPrivateContent: true
      ),
      monetizationState: MonetizationState(
        entitlement: .locked,
        freeUsage: FreePlanUsage(
          aiRequestCount: 9,
          onlinePublishAttemptCount: 0,
          batchPublishCount: 1
        )
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
  case proSettings = "pro-settings"
  case privacyLock = "privacy-lock"
  case releaseReadiness = "release-readiness"

  public var id: String { rawValue }

  @MainActor
  public func apply(to store: WorkbenchStore) {
    store.unlockPrivacy()
    if let draft = preferredDraft(in: store) {
      store.selectDraft(draft.id)
    }

    switch self {
    case .writing:
      store.selectSection(.writing)
      store.setInspectorPresented(true)
      store.setEditorDisplayMode(.split)
      store.setPublishActionMessage("截图模式：写作工作区已载入演示文章。")
    case .aiChat:
      _ = store.openAIChatWorkspace(for: preferredDraft(in: store)?.id)
      store.setPublishActionMessage("截图模式：完整 AI 对话页已载入。")
    case .syncAPIPublish:
      store.selectSection(.sync)
      store.setPublishActionMessage("截图模式：同步/API 发布工作区已载入。")
    case .seoSocialPreview:
      store.selectSection(.contentHealth)
      store.setInspectorPresented(true)
      if let draft = preferredDraft(in: store) {
        store.refreshSEOSocialPreview(for: draft, message: "截图模式：SEO / 社交预览快照已载入。")
      }
    case .deploymentStatus:
      store.selectSection(.releaseHistory)
      store.setDeploymentStatusMessage("截图模式：部署状态和轮询记录已载入。")
    case .maintenance:
      store.selectSection(.maintenance)
      store.setPublishActionMessage("截图模式：站点维护工作台已载入。")
    case .generalDrafts:
      store.selectSection(.generalDrafts)
      store.setPublishActionMessage("截图模式：素材库已载入。")
    case .proSettings:
      store.selectSection(.releaseReadiness)
      store.setMonetizationMessage("截图模式：请打开 Settings > Pro 捕获免费额度、StoreKit 购买和恢复状态。")
    case .privacyLock:
      store.selectSection(.writing)
      store.setInspectorPresented(true)
      store.lockPrivacy(reason: "截图模式：隐私锁已启用，工作台内容已遮挡。")
    case .releaseReadiness:
      store.selectSection(.releaseReadiness)
      store.refreshReleaseQualityGate()
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
