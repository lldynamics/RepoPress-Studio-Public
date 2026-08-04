import Foundation
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class DeploymentStatusServiceTests: XCTestCase {
  func testGitHubPagesActionsAndEndpointBuildSuccessfulSnapshot() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(json: #"{"status":"built","html_url":"https://owner.github.io/site/"}"#),
      deploymentResponse(json: #"{"workflow_runs":[{"name":"Deploy Pages","status":"completed","conclusion":"success","html_url":"https://github.com/owner/site/actions/runs/1"}]}"#),
      deploymentResponse(statusCode: 200, json: #"{"ok":true}"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.deploymentProvider = .githubPages
    profile.deploymentSiteURL = "https://owner.github.io/site/"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：Hello",
      summary: "GitHub · main",
      siteProfileID: profile.id,
      branchName: "main",
      commitSHA: "abc123"
    )

    let snapshot = await service.check(profile: profile, releaseRecord: record, token: "github-token")

    XCTAssertEqual(snapshot.provider, .githubPages)
    XCTAssertEqual(snapshot.level, .success)
    XCTAssertEqual(snapshot.siteURLText, "https://owner.github.io/site/")
    XCTAssertEqual(snapshot.signals.map(\.title), [
      "GitHub Pages",
      "Deploy Pages",
      CoreL10n.format("%@ 状态", DeploymentProvider.githubPages.displayName),
    ])

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site/pages")
    XCTAssertEqual(requests[1].url?.path, "/repos/owner/site/actions/runs")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
    let queryItems = URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "branch", value: "main")))
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "head_sha", value: "abc123")))
    XCTAssertEqual(requests[2].url?.absoluteString, "https://owner.github.io/site/")
  }

  func testGitLabPipelineAndPagesEndpointBuildSuccessfulSnapshot() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(json: #"[{"status":"success","web_url":"https://gitlab.com/group/site/-/pipelines/5"}]"#),
      deploymentResponse(statusCode: 200, json: #"<html><body>GitLab Pages is live</body></html>"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    profile.deploymentProvider = .gitlabPages
    profile.deploymentSiteURL = "https://group.gitlab.io/site/"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：GitLab",
      summary: "GitLab · main",
      siteProfileID: profile.id,
      branchName: "publish/gitlab-status",
      commitSHA: "def456"
    )

    let snapshot = await service.check(profile: profile, releaseRecord: record, token: "gitlab-token")

    XCTAssertEqual(snapshot.provider, .gitlabPages)
    XCTAssertEqual(snapshot.level, .success)
    XCTAssertEqual(snapshot.siteURLText, "https://group.gitlab.io/site/")
    XCTAssertEqual(snapshot.signals.map(\.title), [
      "GitLab Pipeline",
      CoreL10n.format("%@ 可达性", DeploymentProvider.gitlabPages.displayName),
    ])
    XCTAssertEqual(snapshot.signals.first?.message, CoreL10n.format("Pipeline 状态：%@", "success"))
    XCTAssertEqual(snapshot.signals.first?.urlText, "https://gitlab.com/group/site/-/pipelines/5")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests[0].url?.absoluteString.contains("/api/v4/projects/group%2Fsite/pipelines") == true)
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")
    let queryItems = URLComponents(url: try XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "ref", value: "publish/gitlab-status")))
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "per_page", value: "1")))
    XCTAssertEqual(requests[1].url?.absoluteString, "https://group.gitlab.io/site/")
  }

  func testCustomEndpointFailureMarksSnapshotFailed() async {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 503, json: #"{"status":"maintenance"}"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .vercel
    profile.deploymentStatusEndpointURL = "https://example.com/api/status"

    let snapshot = await service.check(profile: profile)

    XCTAssertEqual(snapshot.provider, .vercel)
    XCTAssertEqual(snapshot.level, .failed)
    XCTAssertEqual(snapshot.signals.first?.message, "HTTP 503")
    XCTAssertEqual(snapshot.nextActionTitle, CoreL10n.text("处理失败后重试"))
    XCTAssertEqual(
      snapshot.nextActionMessage,
      CoreL10n.text("打开失败的 Actions、Pipeline 或状态端点，修复后重新检查部署。")
    )
    XCTAssertTrue(snapshot.clipboardSummary.contains("Vercel · \(CoreL10n.text("失败"))"))
    XCTAssertTrue(snapshot.clipboardSummary.contains("HTTP 503"))
    XCTAssertTrue(snapshot.clipboardSummary.contains("https://example.com/api/status"))
  }

  func testDeploymentEndpointJSONStatusOverridesHTTPReachability() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(
        statusCode: 200,
        json: #"{"status":"building","title":"Vercel Production","message":"Queued by Git push","url":"https://vercel.com/acme/site/123"}"#
      ),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .vercel
    profile.deploymentStatusEndpointURL = "https://status.example.com/vercel"

    let snapshot = await service.check(profile: profile)

    XCTAssertEqual(snapshot.provider, .vercel)
    XCTAssertEqual(snapshot.level, .running)
    let signal = try XCTUnwrap(snapshot.signals.first)
    XCTAssertEqual(signal.level, .running)
    XCTAssertEqual(signal.title, "Vercel Production")
    XCTAssertEqual(signal.message, "Queued by Git push")
    XCTAssertEqual(signal.urlText, "https://vercel.com/acme/site/123")
  }

  func testDeploymentEndpointJSONOkBooleanMapsToSuccess() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Netlify deploy is live"}"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .netlify
    profile.deploymentStatusEndpointURL = "status.example.com/netlify"

    let snapshot = await service.check(profile: profile)

    XCTAssertEqual(snapshot.provider, .netlify)
    XCTAssertEqual(snapshot.level, .success)
    XCTAssertEqual(snapshot.signals.first?.title, CoreL10n.format("%@ 状态", DeploymentProvider.netlify.displayName))
    XCTAssertEqual(snapshot.signals.first?.message, "Netlify deploy is live")
    XCTAssertEqual(snapshot.signals.first?.urlText, "https://status.example.com/netlify")
  }

  func testDeploymentEndpointUsesBearerTokenOnlyWhenExplicitlyEnabled() async throws {
    let authorizedTransport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Authenticated status is live"}"#),
    ])
    var authorizedProfile = SiteProfile.defaultProfile
    authorizedProfile.deploymentProvider = .custom
    authorizedProfile.deploymentStatusEndpointURL = "https://status.example.com/private"
    authorizedProfile.deploymentStatusEndpointUsesToken = true

    let authorizedSnapshot = await DeploymentStatusService(transport: authorizedTransport)
      .check(profile: authorizedProfile, token: "deploy-token")

    XCTAssertEqual(authorizedSnapshot.level, .success)
    let authorizedRequests = await authorizedTransport.capturedRequests()
    XCTAssertEqual(authorizedRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer deploy-token")

    let publicTransport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Public status is live"}"#),
    ])
    var publicProfile = authorizedProfile
    publicProfile.deploymentStatusEndpointUsesToken = false

    _ = await DeploymentStatusService(transport: publicTransport)
      .check(profile: publicProfile, token: "deploy-token")

    let publicRequests = await publicTransport.capturedRequests()
    XCTAssertNil(publicRequests.first?.value(forHTTPHeaderField: "Authorization"))
  }

  func testDeploymentEndpointRejectsHTTPBeforeSendingBearerToken() async throws {
    let transport = SequencedDeploymentTransport(responses: [])
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "http://status.example.com/private"
    profile.deploymentStatusEndpointUsesToken = true

    let snapshot = await DeploymentStatusService(transport: transport)
      .check(profile: profile, token: "deploy-token")

    XCTAssertEqual(snapshot.level, .failed)
    let signal = try XCTUnwrap(snapshot.signals.first)
    XCTAssertTrue(signal.message.contains("HTTPS"))
    XCTAssertEqual(
      signal.message,
      CoreL10n.text("使用 Bearer Token 的状态端点必须使用 HTTPS；本次未发送 Token。")
    )
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testDeploymentEndpointMarkedForTokenRejectsHTTPEvenWhenTokenIsMissing() async {
    let transport = SequencedDeploymentTransport(responses: [])
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "http://status.example.com/private"
    profile.deploymentStatusEndpointUsesToken = true

    let snapshot = await DeploymentStatusService(transport: transport)
      .check(profile: profile, token: nil)

    XCTAssertEqual(snapshot.level, .failed)
    XCTAssertTrue(snapshot.signals.first?.message.contains("HTTPS") == true)
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testProtectedHTTPSEndpointDoesNotFallBackToAnonymousRequestWhenTokenIsMissing() async {
    let transport = SequencedDeploymentTransport(responses: [])
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "https://status.example.com/private"
    profile.deploymentStatusEndpointUsesToken = true

    let snapshot = await DeploymentStatusService(transport: transport)
      .check(profile: profile, token: nil)

    XCTAssertEqual(snapshot.level, .unknown)
    XCTAssertEqual(
      snapshot.signals.first?.message,
      CoreL10n.text("该端点要求 Bearer Token，但当前未保存 Token；本次未发起请求。")
    )
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
  }

  func testPublicDeploymentEndpointStillAllowsHTTPWithoutAuthorization() async {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true}"#),
    ])
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "http://status.example.com/public"
    profile.deploymentStatusEndpointUsesToken = false

    let snapshot = await DeploymentStatusService(transport: transport)
      .check(profile: profile, token: "must-not-be-sent")

    XCTAssertEqual(snapshot.level, .success)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
  }

  func testGitHubDeploymentAPIRejectsHTTPBeforeBuildingTokenRequest() {
    let service = DeploymentStatusService()
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "http://api.github.example"

    XCTAssertThrowsError(
      try service.githubRequest(profile: profile, path: "/repos/owner/site/pages", token: "github-token")
    ) { error in
      XCTAssertEqual(error as? DeploymentStatusError, .insecureCredentialURL)
      XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
    }
  }

  func testGitLabDeploymentAPIRejectsHTTPBeforeBuildingTokenRequest() {
    let service = DeploymentStatusService()
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "http://gitlab.example"

    XCTAssertThrowsError(
      try service.gitLabRequest(profile: profile, path: "/projects/group%2Fsite/pipelines", token: "gitlab-token")
    ) { error in
      XCTAssertEqual(error as? DeploymentStatusError, .insecureCredentialURL)
      XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
    }
  }

  func testDeploymentSiteURLFallbackNeverReceivesEndpointBearerToken() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Site is reachable"}"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com"
    profile.deploymentStatusEndpointURL = nil
    profile.deploymentStatusEndpointUsesToken = true

    let snapshot = await service.check(profile: profile, token: "deploy-token")

    XCTAssertEqual(snapshot.level, .success)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.first?.url?.absoluteString, "https://example.com")
    XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
  }

  func testProviderDeploymentTokenIsNeverForwardedToThirdPartyStatusEndpoint() async {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true}"#),
    ])
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .githubPages
    profile.repoOwner = ""
    profile.repoName = ""
    profile.deploymentStatusEndpointURL = "https://status.third-party.example/private"
    profile.deploymentStatusEndpointUsesToken = true

    _ = await DeploymentStatusService(transport: transport)
      .check(profile: profile, token: "github-platform-token")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
  }

  func testDeploymentCheckVerifiesPublishedArticlePageContainsTitle() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Site is live"}"#),
      deploymentResponse(statusCode: 200, json: #"<html><head><title>Published Article</title><link rel="canonical" href="https://example.com/blog/published-article"><meta property="og:url" content="https://example.com/blog/published-article/"></head><body>Published Article</body></html>"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com/blog/"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：Published Article",
      summary: "custom",
      siteProfileID: profile.id,
      draftTitle: "Published Article",
      markdownPath: "content/posts/published-article.md"
    )

    let snapshot = await service.check(profile: profile, releaseRecord: record)

    XCTAssertEqual(snapshot.level, .success)
    XCTAssertEqual(snapshot.signals.map(\.title), [
      CoreL10n.format("%@ 状态", DeploymentProvider.custom.displayName),
      CoreL10n.text("发布页面内容"),
      CoreL10n.text("发布页面 SEO"),
    ])
    XCTAssertEqual(
      snapshot.signals.first { $0.title == CoreL10n.text("发布页面内容") }?.message,
      CoreL10n.format("已在发布页面找到文章标题：%@", "Published Article")
    )
    XCTAssertEqual(
      snapshot.signals.first { $0.title == CoreL10n.text("发布页面 SEO") }?.message,
      CoreL10n.format("%@ 已指向当前文章 URL。", "canonical / og:url")
    )
    XCTAssertEqual(snapshot.signals.last?.urlText, "https://example.com/blog/published-article")
    XCTAssertEqual(snapshot.postPublishCheckItems.map(\.title), [
      CoreL10n.text("站点入口"),
      CoreL10n.format("%@ 状态", DeploymentProvider.custom.displayName),
      CoreL10n.text("发布页面内容"),
      CoreL10n.text("发布页面 SEO"),
      CoreL10n.text("保持监控"),
    ])
    XCTAssertTrue(snapshot.postPublishCheckItems.allSatisfy { $0.level == .success })
    XCTAssertTrue(snapshot.postPublishChecklistMarkdown.contains(CoreL10n.text("# 发布后校验报告")))
    XCTAssertTrue(snapshot.postPublishChecklistMarkdown.contains(
      CoreL10n.format(
        "- [%@] %@：%@",
        "x",
        CoreL10n.text("发布页面内容"),
        CoreL10n.format("已在发布页面找到文章标题：%@", "Published Article")
      )
    ))
    XCTAssertTrue(snapshot.postPublishChecklistMarkdown.contains(
      CoreL10n.format(
        "- [%@] %@：%@",
        "x",
        CoreL10n.text("发布页面 SEO"),
        CoreL10n.format("%@ 已指向当前文章 URL。", "canonical / og:url")
      )
    ))
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
      "https://example.com/blog/",
      "https://example.com/blog/published-article",
    ])
  }

  func testDeploymentCheckFailsWhenPublishedArticlePageDoesNotContainTitle() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Site is live"}"#),
      deploymentResponse(statusCode: 200, json: #"<html><body>Old article content</body></html>"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：New Article",
      summary: "custom",
      siteProfileID: profile.id,
      draftTitle: "New Article",
      markdownPath: "content/posts/new-article.md"
    )

    let snapshot = await service.check(profile: profile, releaseRecord: record)

    XCTAssertEqual(snapshot.level, .failed)
    let missingTitleMessage = CoreL10n.format("文章页面可访问，但没有找到文章标题：%@", "New Article")
    let contentSignal = try XCTUnwrap(snapshot.signals.first { $0.title == CoreL10n.text("发布页面内容") })
    XCTAssertEqual(contentSignal.level, .failed)
    XCTAssertEqual(contentSignal.message, missingTitleMessage)
    XCTAssertEqual(snapshot.message, missingTitleMessage)
    XCTAssertTrue(snapshot.postPublishCheckItems.contains {
      $0.title == CoreL10n.text("发布页面内容")
        && $0.level == .failed
        && $0.message == missingTitleMessage
    })
    XCTAssertTrue(snapshot.postPublishChecklistMarkdown.contains(CoreL10n.text("## 需处理信号")))
    XCTAssertTrue(snapshot.postPublishChecklistMarkdown.contains(
      CoreL10n.format(
        "- [%@] %@：%@",
        CoreL10n.text("失败"),
        CoreL10n.text("发布页面内容"),
        missingTitleMessage
      )
    ))
  }

  func testDeploymentCheckFailsWhenPublishedArticleCanonicalPointsElsewhere() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Site is live"}"#),
      deploymentResponse(statusCode: 200, json: #"<html><head><link rel="canonical" href="https://example.com/posts/old-article"><meta property="og:url" content="https://example.com/posts/new-article"></head><body>New Article</body></html>"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：New Article",
      summary: "custom",
      siteProfileID: profile.id,
      draftTitle: "New Article",
      markdownPath: "content/posts/new-article.md"
    )

    let snapshot = await service.check(profile: profile, releaseRecord: record)

    XCTAssertEqual(snapshot.level, .failed)
    XCTAssertEqual(snapshot.signals.first { $0.title == CoreL10n.text("发布页面内容") }?.level, .success)
    let seoSignal = try XCTUnwrap(snapshot.signals.first { $0.title == CoreL10n.text("发布页面 SEO") })
    XCTAssertEqual(seoSignal.level, .failed)
    let canonicalMismatchMessage = CoreL10n.format(
      "%@ 指向 %@，不是当前文章 URL。",
      "canonical",
      "https://example.com/posts/old-article"
    )
    XCTAssertEqual(seoSignal.message, canonicalMismatchMessage)
    XCTAssertEqual(snapshot.message, canonicalMismatchMessage)
    XCTAssertTrue(snapshot.postPublishChecklistMarkdown.contains(
      CoreL10n.format(
        "- [%@] %@：%@",
        CoreL10n.text("失败"),
        CoreL10n.text("发布页面 SEO"),
        canonicalMismatchMessage
      )
    ))
  }

  func testDeploymentArticleCheckVerifiesPublishedSocialMetadataAgainstReleaseSnapshot() async throws {
    let summary = "这是一段会进入 meta description 和社交卡片摘要的发布记录快照。"
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Site is live"}"#),
      deploymentResponse(
        statusCode: 200,
        json: """
        <html>
          <head>
            <link rel="canonical" href="https://example.com/social-article">
            <meta property="og:url" content="https://example.com/social-article">
            <meta property="og:title" content="Social Article">
            <meta name="twitter:title" content="Social Article | Site">
            <meta name="description" content="\(summary)">
            <meta property="og:description" content="\(summary)">
            <meta property="og:image" content="/images/social-article.jpg">
            <meta property="og:image:alt" content="Social article cover">
          </head>
          <body>Social Article</body>
        </html>
        """
      ),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：Social Article",
      summary: "custom",
      siteProfileID: profile.id,
      draftTitle: "Social Article",
      draftSummary: summary,
      draftCoverAltText: "Social article cover",
      markdownPath: "content/posts/social-article.md"
    )

    let snapshot = await service.check(profile: profile, releaseRecord: record)

    XCTAssertEqual(snapshot.level, .success)
    XCTAssertEqual(snapshot.signals.map(\.title), [
      CoreL10n.format("%@ 状态", DeploymentProvider.custom.displayName),
      CoreL10n.text("发布页面内容"),
      CoreL10n.text("发布页面 SEO"),
      CoreL10n.text("发布页面社交元数据"),
    ])
    let matchedPieces = [
      CoreL10n.text("标题"),
      CoreL10n.text("摘要"),
      CoreL10n.text("封面 Alt"),
      CoreL10n.format("%@ URL", "og:image"),
    ].joined(separator: CoreL10n.text("、"))
    let socialMetadataMessage = CoreL10n.format("社交卡片字段（%@）已匹配发布记录。", matchedPieces)
    XCTAssertEqual(snapshot.signals.last?.message, socialMetadataMessage)
    XCTAssertEqual(snapshot.signals.last?.urlText, "https://example.com/images/social-article.jpg")
    XCTAssertTrue(snapshot.postPublishChecklistMarkdown.contains(
      CoreL10n.format(
        "- [%@] %@：%@",
        "x",
        CoreL10n.text("发布页面社交元数据"),
        socialMetadataMessage
      )
    ))
    XCTAssertTrue(snapshot.postPublishChecklistMarkdown.contains("https://example.com/images/social-article.jpg"))
  }

  func testDeploymentArticleCheckFailsWhenPublishedSocialImageURLIsMissing() async throws {
    let summary = "这是一段会进入 meta description 和社交卡片摘要的发布记录快照。"
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Site is live"}"#),
      deploymentResponse(
        statusCode: 200,
        json: """
        <html>
          <head>
            <link rel="canonical" href="https://example.com/social-image-missing">
            <meta property="og:url" content="https://example.com/social-image-missing">
            <meta property="og:title" content="Social Image Missing">
            <meta name="description" content="\(summary)">
            <meta property="og:description" content="\(summary)">
            <meta property="og:image:alt" content="Expected cover alt">
          </head>
          <body>Social Image Missing</body>
        </html>
        """
      ),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：Social Image Missing",
      summary: "custom",
      siteProfileID: profile.id,
      draftTitle: "Social Image Missing",
      draftSummary: summary,
      draftCoverAltText: "Expected cover alt",
      markdownPath: "content/posts/social-image-missing.md"
    )

    let snapshot = await service.check(profile: profile, releaseRecord: record)

    XCTAssertEqual(snapshot.level, .failed)
    let socialSignal = try XCTUnwrap(snapshot.signals.first { $0.title == CoreL10n.text("发布页面社交元数据") })
    XCTAssertEqual(socialSignal.level, .failed)
    let missingImageMessage = CoreL10n.text("缺少 og:image 或 twitter:image，无法确认社交图 URL。")
    XCTAssertEqual(socialSignal.message, missingImageMessage)
    XCTAssertEqual(snapshot.message, missingImageMessage)
    XCTAssertTrue(snapshot.postPublishChecklistMarkdown.contains(
      CoreL10n.format(
        "- [%@] %@：%@",
        CoreL10n.text("失败"),
        CoreL10n.text("发布页面社交元数据"),
        missingImageMessage
      )
    ))
  }

  func testDeploymentArticleCheckFailsWhenPublishedSocialImageAltIsMissing() async throws {
    let summary = "这是一段会进入 meta description 和社交卡片摘要的发布记录快照。"
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Site is live"}"#),
      deploymentResponse(
        statusCode: 200,
        json: """
        <html>
          <head>
            <link rel="canonical" href="https://example.com/social-alt-missing">
            <meta property="og:url" content="https://example.com/social-alt-missing">
            <meta property="og:title" content="Social Alt Missing">
            <meta name="description" content="\(summary)">
            <meta property="og:description" content="\(summary)">
            <meta property="og:image" content="https://cdn.example.com/social-alt-missing.jpg">
          </head>
          <body>Social Alt Missing</body>
        </html>
        """
      ),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：Social Alt Missing",
      summary: "custom",
      siteProfileID: profile.id,
      draftTitle: "Social Alt Missing",
      draftSummary: summary,
      draftCoverAltText: "Expected cover alt",
      markdownPath: "content/posts/social-alt-missing.md"
    )

    let snapshot = await service.check(profile: profile, releaseRecord: record)

    XCTAssertEqual(snapshot.level, .failed)
    let socialSignal = try XCTUnwrap(snapshot.signals.first { $0.title == CoreL10n.text("发布页面社交元数据") })
    XCTAssertEqual(socialSignal.level, .failed)
    let missingAltMessage = CoreL10n.text("缺少 og:image:alt 或 twitter:image:alt，无法确认社交图 Alt。")
    XCTAssertEqual(socialSignal.message, missingAltMessage)
    XCTAssertEqual(snapshot.message, missingAltMessage)
    XCTAssertTrue(snapshot.postPublishChecklistMarkdown.contains(
      CoreL10n.format(
        "- [%@] %@：%@",
        CoreL10n.text("失败"),
        CoreL10n.text("发布页面社交元数据"),
        missingAltMessage
      )
    ))
  }

  func testDeploymentArticleCheckFailsWhenPublishedSocialTitleIsMissing() async throws {
    let summary = "这是一段会进入 meta description 的发布记录快照。"
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Site is live"}"#),
      deploymentResponse(
        statusCode: 200,
        json: """
        <html>
          <head>
            <link rel="canonical" href="https://example.com/social-missing-title">
            <meta property="og:url" content="https://example.com/social-missing-title">
            <meta name="description" content="\(summary)">
          </head>
          <body>Social Missing Title</body>
        </html>
        """
      ),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：Social Missing Title",
      summary: "custom",
      siteProfileID: profile.id,
      draftTitle: "Social Missing Title",
      draftSummary: summary,
      markdownPath: "content/posts/social-missing-title.md"
    )

    let snapshot = await service.check(profile: profile, releaseRecord: record)

    XCTAssertEqual(snapshot.level, .failed)
    let socialSignal = try XCTUnwrap(snapshot.signals.first { $0.title == CoreL10n.text("发布页面社交元数据") })
    XCTAssertEqual(socialSignal.level, .failed)
    let missingSocialTitleMessage = CoreL10n.text("缺少 og:title 或 twitter:title，无法确认社交卡片标题。")
    XCTAssertEqual(socialSignal.message, missingSocialTitleMessage)
    XCTAssertEqual(snapshot.message, missingSocialTitleMessage)
    XCTAssertTrue(snapshot.postPublishChecklistMarkdown.contains(
      CoreL10n.format(
        "- [%@] %@：%@",
        CoreL10n.text("失败"),
        CoreL10n.text("发布页面社交元数据"),
        missingSocialTitleMessage
      )
    ))
  }

  func testDeploymentArticleCheckUsesJekyllDatedPermalink() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Site is live"}"#),
      deploymentResponse(statusCode: 200, json: #"<html><head><link rel="canonical" href="https://example.com/blog/2026/07/07/jekyll-article"></head><body>Jekyll Article</body></html>"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .jekyll)
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com/blog/"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：Jekyll Article",
      summary: "custom",
      siteProfileID: profile.id,
      draftTitle: "Jekyll Article",
      markdownPath: "_posts/2026-07-07-jekyll-article.md"
    )

    let snapshot = await service.check(profile: profile, releaseRecord: record)

    XCTAssertEqual(snapshot.level, .success)
    XCTAssertEqual(snapshot.signals.last?.title, CoreL10n.text("发布页面 SEO"))
    XCTAssertEqual(snapshot.signals.last?.urlText, "https://example.com/blog/2026/07/07/jekyll-article")
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
      "https://example.com/blog/",
      "https://example.com/blog/2026/07/07/jekyll-article",
    ])
  }

  func testDeploymentArticleCheckKeepsHugoSectionPath() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"ok":true,"message":"Site is live"}"#),
      deploymentResponse(statusCode: 200, json: #"<html><head><meta property="og:url" content="https://example.com/posts/hugo-article"></head><body>Hugo Article</body></html>"#),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.applyPublishingDefaults(for: .hugo)
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：Hugo Article",
      summary: "custom",
      siteProfileID: profile.id,
      draftTitle: "Hugo Article",
      markdownPath: "content/posts/hugo-article.md"
    )

    let snapshot = await service.check(profile: profile, releaseRecord: record)

    XCTAssertEqual(snapshot.level, .success)
    XCTAssertEqual(snapshot.signals.last?.urlText, "https://example.com/posts/hugo-article")
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
      "https://example.com",
      "https://example.com/posts/hugo-article",
    ])
  }

  func testNetlifyDeployAPIBuildsSuccessfulSnapshotWithoutCustomEndpoint() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(
        json: #"[{"name":"personal-site","state":"ready","branch":"main","commit_ref":"abc123","admin_url":"https://app.netlify.com/sites/personal-site/deploys/1"}]"#
      ),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .netlify
    profile.deploymentProjectID = "site-id-123"

    let snapshot = await service.check(profile: profile, token: "netlify-token")

    XCTAssertEqual(snapshot.provider, .netlify)
    XCTAssertEqual(snapshot.level, .success)
    XCTAssertEqual(snapshot.signals.map(\.title), ["personal-site"])
    XCTAssertEqual(snapshot.signals.first?.message, [
      CoreL10n.format("状态：%@", "ready"),
      CoreL10n.format("分支：%@", "main"),
      CoreL10n.format("提交：%@", "abc123"),
    ].joined(separator: " · "))
    XCTAssertEqual(snapshot.signals.first?.urlText, "https://app.netlify.com/sites/personal-site/deploys/1")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].url?.scheme, "https")
    XCTAssertEqual(requests[0].url?.host, "api.netlify.com")
    XCTAssertEqual(requests[0].url?.path, "/api/v1/sites/site-id-123/deploys")
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer netlify-token")
    let queryItems = URLComponents(url: try XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "per_page", value: "1")))
  }

  func testNetlifyDeployAPIRunningAndFailureStatesAreMapped() async throws {
    let runningTransport = SequencedDeploymentTransport(responses: [
      deploymentResponse(json: #"[{"name":"personal-site","state":"building"}]"#),
    ])
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .netlify
    profile.deploymentProjectID = "site-id-123"

    let runningSnapshot = await DeploymentStatusService(transport: runningTransport)
      .check(profile: profile, token: "netlify-token")

    XCTAssertEqual(runningSnapshot.level, .running)

    let failedTransport = SequencedDeploymentTransport(responses: [
      deploymentResponse(json: #"[{"name":"personal-site","state":"error","error_message":"Build command failed"}]"#),
    ])

    let failedSnapshot = await DeploymentStatusService(transport: failedTransport)
      .check(profile: profile, token: "netlify-token")

    XCTAssertEqual(failedSnapshot.level, .failed)
    XCTAssertEqual(failedSnapshot.signals.first?.message, [
      CoreL10n.format("状态：%@", "error"),
      "Build command failed",
    ].joined(separator: " · "))
  }

  func testVercelDeploymentsAPIBuildsRunningSnapshotWithProjectAndTeam() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(
        json: #"{"deployments":[{"name":"personal-site","url":"personal-site-git-main.vercel.app","readyState":"BUILDING","target":"production","inspectorUrl":"https://vercel.com/team/personal-site/abc","meta":{"githubCommitRef":"main","githubCommitSha":"abc123"}}]}"#
      ),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .vercel
    profile.deploymentProjectID = "prj_123"
    profile.deploymentAccountID = "team_456"
    profile.branch = "main"
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：Vercel",
      summary: "Vercel",
      siteProfileID: profile.id,
      branchName: "main",
      commitSHA: "abc123"
    )

    let snapshot = await service.check(profile: profile, releaseRecord: record, token: "vercel-token")

    XCTAssertEqual(snapshot.provider, .vercel)
    XCTAssertEqual(snapshot.level, .running)
    XCTAssertEqual(snapshot.signals.map(\.title), ["personal-site"])
    XCTAssertEqual(snapshot.signals.first?.message, [
      CoreL10n.format("状态：%@", "BUILDING"),
      CoreL10n.format("目标：%@", "production"),
      CoreL10n.format("分支：%@", "main"),
      CoreL10n.format("提交：%@", "abc123"),
    ].joined(separator: " · "))
    XCTAssertEqual(snapshot.signals.first?.urlText, "https://vercel.com/team/personal-site/abc")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].url?.scheme, "https")
    XCTAssertEqual(requests[0].url?.host, "api.vercel.com")
    XCTAssertEqual(requests[0].url?.path, "/v7/deployments")
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer vercel-token")
    let queryItems = URLComponents(url: try XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "projectId", value: "prj_123")))
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "teamId", value: "team_456")))
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "limit", value: "1")))
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "target", value: "production")))
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "branch", value: "main")))
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "sha", value: "abc123")))
  }

  func testCloudflarePagesAPIBuildsSuccessfulSnapshotWithAccountAndProject() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(
        json: #"{"result":[{"id":"deploy-1","url":"https://personal-site.pages.dev","aliases":["https://www.example.com"],"latest_stage":{"name":"deploy","status":"success"},"deployment_trigger":{"metadata":{"branch":"main","commit_hash":"abc123","commit_message":"Publish article"}}}]}"#
      ),
    ])
    let service = DeploymentStatusService(transport: transport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .cloudflarePages
    profile.deploymentProjectID = "personal-site"
    profile.deploymentAccountID = "account123"

    let snapshot = await service.check(profile: profile, token: "cloudflare-token")

    XCTAssertEqual(snapshot.provider, .cloudflarePages)
    XCTAssertEqual(snapshot.level, .success)
    XCTAssertEqual(snapshot.signals.map(\.title), ["deploy"])
    XCTAssertEqual(snapshot.signals.first?.message, [
      CoreL10n.format("状态：%@", "success"),
      CoreL10n.format("分支：%@", "main"),
      CoreL10n.format("提交：%@", "abc123"),
      "Publish article",
    ].joined(separator: " · "))
    XCTAssertEqual(snapshot.signals.first?.urlText, "https://personal-site.pages.dev")

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].url?.scheme, "https")
    XCTAssertEqual(requests[0].url?.host, "api.cloudflare.com")
    XCTAssertEqual(requests[0].url?.path, "/client/v4/accounts/account123/pages/projects/personal-site/deployments")
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer cloudflare-token")
    let queryItems = URLComponents(url: try XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "env", value: "production")))
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "page", value: "1")))
    XCTAssertTrue(queryItems.contains(URLQueryItem(name: "per_page", value: "1")))
  }

  func testThirdPartyDeploymentAPIsDoNotConfirmMismatchedReleaseAttribution() async throws {
    let releaseRecord = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：Current Article",
      summary: "Third party deploy",
      siteProfileID: SiteProfile.defaultProfile.id,
      branchName: "main",
      commitSHA: "abc123456789ffff"
    )

    let netlifyTransport = SequencedDeploymentTransport(responses: [
      deploymentResponse(
        json: #"[{"name":"personal-site","state":"ready","branch":"preview","commit_ref":"def999888777","admin_url":"https://app.netlify.com/sites/personal-site/deploys/2"}]"#
      ),
    ])
    var netlifyProfile = SiteProfile.defaultProfile
    netlifyProfile.deploymentProvider = .netlify
    netlifyProfile.deploymentProjectID = "site-id-123"
    netlifyProfile.branch = "main"

    let netlifySnapshot = await DeploymentStatusService(transport: netlifyTransport)
      .check(profile: netlifyProfile, releaseRecord: releaseRecord, token: "netlify-token")

    XCTAssertEqual(netlifySnapshot.level, .unknown)
    let netlifyMismatches = [
      CoreL10n.format("期望提交 %@，实际 %@", "abc123456789", "def999888777"),
      CoreL10n.format("期望分支 %@，实际 %@", "main", "preview"),
    ].joined(separator: CoreL10n.text("；"))
    XCTAssertEqual(
      netlifySnapshot.signals.first?.message,
      CoreL10n.format(
        "最近一次 %@ 部署不是当前发布：%@。请等待目标 commit 部署完成或检查部署队列。",
        DeploymentProvider.netlify.displayName,
        netlifyMismatches
      )
    )

    let vercelTransport = SequencedDeploymentTransport(responses: [
      deploymentResponse(
        json: #"{"deployments":[{"name":"personal-site","readyState":"READY","target":"production","inspectorUrl":"https://vercel.com/team/personal-site/other","meta":{"githubCommitRef":"main","githubCommitSha":"def999888777aaaa"}}]}"#
      ),
    ])
    var vercelProfile = SiteProfile.defaultProfile
    vercelProfile.deploymentProvider = .vercel
    vercelProfile.deploymentProjectID = "prj_123"
    vercelProfile.branch = "main"

    let vercelSnapshot = await DeploymentStatusService(transport: vercelTransport)
      .check(profile: vercelProfile, releaseRecord: releaseRecord, token: "vercel-token")

    XCTAssertEqual(vercelSnapshot.level, .unknown)
    XCTAssertEqual(
      vercelSnapshot.signals.first?.message,
      CoreL10n.format(
        "最近一次 %@ 部署不是当前发布：%@。请等待目标 commit 部署完成或检查部署队列。",
        DeploymentProvider.vercel.displayName,
        CoreL10n.format("期望提交 %@，实际 %@", "abc123456789", "def999888777")
      )
    )

    let cloudflareTransport = SequencedDeploymentTransport(responses: [
      deploymentResponse(
        json: #"{"result":[{"id":"deploy-1","url":"https://personal-site.pages.dev","aliases":[],"latest_stage":{"name":"deploy","status":"success"},"deployment_trigger":{"metadata":{"branch":"develop","commit_hash":"abc123456789ffff","commit_message":"Publish article"}}}]}"#
      ),
    ])
    var cloudflareProfile = SiteProfile.defaultProfile
    cloudflareProfile.deploymentProvider = .cloudflarePages
    cloudflareProfile.deploymentProjectID = "personal-site"
    cloudflareProfile.deploymentAccountID = "account123"
    cloudflareProfile.branch = "main"

    let cloudflareSnapshot = await DeploymentStatusService(transport: cloudflareTransport)
      .check(profile: cloudflareProfile, releaseRecord: releaseRecord, token: "cloudflare-token")

    XCTAssertEqual(cloudflareSnapshot.level, .unknown)
    XCTAssertEqual(
      cloudflareSnapshot.signals.first?.message,
      CoreL10n.format(
        "最近一次 %@ 部署不是当前发布：%@。请等待目标 commit 部署完成或检查部署队列。",
        DeploymentProvider.cloudflarePages.displayName,
        CoreL10n.format("期望分支 %@，实际 %@", "main", "develop")
      )
    )
  }

  func testDeploymentReadinessShowsProviderMissingTokenAndFallbackState() {
    let service = DeploymentStatusService()
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .vercel
    profile.deploymentProjectID = "prj_123"
    profile.deploymentStatusEndpointURL = "https://status.example.com/vercel"

    let readiness = service.readiness(profile: profile, hasToken: false)

    XCTAssertEqual(readiness.provider, .vercel)
    XCTAssertFalse(readiness.isAPIReady)
    XCTAssertTrue(readiness.canCheckAnyStatus)
    XCTAssertTrue(readiness.configuredSignals.contains("Vercel Project ID"))
    XCTAssertTrue(readiness.configuredSignals.contains(CoreL10n.text("状态端点 URL")))
    XCTAssertTrue(readiness.missingRequirements.contains(CoreL10n.text("部署 Token")))
    XCTAssertEqual(
      readiness.statusTitle,
      CoreL10n.format("%@ 可做降级校验", DeploymentProvider.vercel.displayName)
    )
    XCTAssertEqual(
      readiness.fallbackMessage,
      CoreL10n.text("已配置站点 URL 或状态端点；即使 API 未就绪，也能检查 HTTP 可达性和文章页面内容。")
    )
    XCTAssertTrue(readiness.checklistMarkdown.contains(
      CoreL10n.format("- [ ] %@", CoreL10n.text("部署 Token"))
    ))
  }

  func testDeploymentReadinessTracksProtectedStatusEndpointTokenRequirement() {
    let service = DeploymentStatusService()
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "https://status.example.com/private"
    profile.deploymentStatusEndpointUsesToken = true

    let missingToken = service.readiness(profile: profile, hasToken: false)

    XCTAssertFalse(missingToken.isAPIReady)
    XCTAssertTrue(missingToken.canCheckAnyStatus)
    XCTAssertTrue(missingToken.missingRequirements.contains(CoreL10n.text("状态端点 Bearer Token")))
    XCTAssertTrue(missingToken.fallbackMessage.contains(
      CoreL10n.text(" 状态端点会在保存 Token 后使用 Bearer 授权。")
    ))

    let ready = service.readiness(profile: profile, hasToken: true)

    XCTAssertTrue(ready.isAPIReady)
    XCTAssertTrue(ready.configuredSignals.contains(CoreL10n.text("状态端点 Bearer Token")))
    XCTAssertFalse(ready.missingRequirements.contains(CoreL10n.text("状态端点 Bearer Token")))
  }

  func testDeploymentReadinessRejectsProtectedHTTPStatusEndpoint() {
    let service = DeploymentStatusService()
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "http://status.example.com/private"
    profile.deploymentStatusEndpointUsesToken = true

    let readiness = service.readiness(profile: profile, hasToken: true)

    XCTAssertFalse(readiness.isAPIReady)
    XCTAssertFalse(readiness.canCheckAnyStatus)
    XCTAssertTrue(readiness.missingRequirements.contains(CoreL10n.text("状态端点 HTTPS URL")))
    XCTAssertEqual(
      readiness.fallbackMessage,
      CoreL10n.text("受保护状态端点必须使用 HTTPS；当前端点已禁用，不会发送 Bearer Token。")
    )
  }

  func testDeploymentReadinessRejectsHTTPRepositoryAPIWithToken() {
    let service = DeploymentStatusService()
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "http://api.github.example"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.deploymentProvider = .githubPages

    let readiness = service.readiness(profile: profile, hasToken: true)

    XCTAssertFalse(readiness.isAPIReady)
    XCTAssertTrue(readiness.missingRequirements.contains(CoreL10n.text("仓库 API HTTPS URL")))
  }

  func testDeploymentReadinessPassesCloudflareWhenAccountProjectAndTokenExist() {
    let service = DeploymentStatusService()
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .cloudflarePages
    profile.deploymentAccountID = "account123"
    profile.deploymentProjectID = "personal-site"

    let readiness = service.readiness(profile: profile, hasToken: true)

    XCTAssertTrue(readiness.isAPIReady)
    XCTAssertTrue(readiness.canCheckAnyStatus)
    XCTAssertTrue(readiness.missingRequirements.isEmpty)
    XCTAssertTrue(readiness.configuredSignals.contains("Cloudflare Account ID"))
    XCTAssertTrue(readiness.configuredSignals.contains("Cloudflare Pages project"))
    XCTAssertEqual(
      readiness.statusTitle,
      CoreL10n.format("%@ API 已就绪", DeploymentProvider.cloudflarePages.displayName)
    )
  }

  func testDeploymentReadinessRequiresCompleteCloudflareConfigurationBeforeCheckingStatus() {
    let service = DeploymentStatusService()
    var missingProject = SiteProfile.defaultProfile
    missingProject.deploymentProvider = .cloudflarePages
    missingProject.deploymentAccountID = "account123"
    missingProject.deploymentProjectID = nil
    missingProject.deploymentSiteURL = nil
    missingProject.deploymentStatusEndpointURL = nil

    let accountOnly = service.readiness(profile: missingProject, hasToken: true)

    XCTAssertFalse(accountOnly.isAPIReady)
    XCTAssertFalse(accountOnly.canCheckAnyStatus)
    XCTAssertTrue(accountOnly.configuredSignals.contains("Cloudflare Account ID"))
    XCTAssertTrue(accountOnly.missingRequirements.contains("Cloudflare Pages project"))
    XCTAssertTrue(accountOnly.nextStep.contains("Cloudflare Pages project"))

    var missingAccount = missingProject
    missingAccount.deploymentAccountID = nil
    missingAccount.deploymentProjectID = "personal-site"

    let projectOnly = service.readiness(profile: missingAccount, hasToken: true)

    XCTAssertFalse(projectOnly.isAPIReady)
    XCTAssertFalse(projectOnly.canCheckAnyStatus)
    XCTAssertTrue(projectOnly.configuredSignals.contains("Cloudflare Pages project"))
    XCTAssertTrue(projectOnly.missingRequirements.contains("Cloudflare Account ID"))
  }

  func testDeploymentReadinessAllowsCloudflareFallbackWhenProviderConfigurationIsPartial() {
    let service = DeploymentStatusService()
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .cloudflarePages
    profile.deploymentAccountID = "account123"
    profile.deploymentProjectID = nil
    profile.deploymentSiteURL = "https://example.com"

    let readiness = service.readiness(profile: profile, hasToken: true)

    XCTAssertFalse(readiness.isAPIReady)
    XCTAssertTrue(readiness.canCheckAnyStatus)
    XCTAssertTrue(readiness.configuredSignals.contains(CoreL10n.text("站点 URL")))
    XCTAssertTrue(readiness.missingRequirements.contains("Cloudflare Pages project"))
    XCTAssertEqual(
      readiness.statusTitle,
      CoreL10n.format("%@ 可做降级校验", DeploymentProvider.cloudflarePages.displayName)
    )
  }

  func testStoreRefreshDeploymentStatusCachesSnapshotForRecord() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"status":"ok"}"#),
    ])
    let persistenceURL = try temporaryPersistenceURL()
    let deploymentTokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.DeploymentStatusSnapshot",
      accountPrefix: "deployment-status-snapshot",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      deploymentStatusService: DeploymentStatusService(transport: transport),
      deploymentTokenStore: deploymentTokenStore
    )
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .custom
      profile.deploymentStatusEndpointURL = "https://status.example.com/site"
    }
    let record = ReleaseRecord(
      title: "线上发布：Test",
      summary: "custom",
      siteProfileID: store.activeProfileID
    )
    store.setReleaseRecords([record])

    let snapshot = await store.refreshDeploymentStatus(for: record)

    XCTAssertEqual(snapshot?.level, .success)
    XCTAssertEqual(store.deploymentStatusSnapshot(for: record)?.provider, .custom)
    XCTAssertEqual(
      store.deploymentStatusMessage,
      CoreL10n.format("%@：%@", DeploymentProvider.custom.displayName, CoreL10n.text("正常"))
    )

    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(reloaded.deploymentStatusSnapshot(for: record)?.level, .success)
    XCTAssertEqual(reloaded.releaseLedger.entries.first?.status, .succeeded)
    XCTAssertEqual(reloaded.releaseLedger.entries.first?.deploymentStatus?.provider, .custom)
  }

  func testStoreRefreshDeploymentStatusContinuesPublicFallbackAfterKeychainReadFailure() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"status":"ok"}"#),
    ])
    let deploymentTokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.DeploymentFallbackAccessFailure",
      accountPrefix: "deployment-fallback-access-failure",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      deploymentStatusService: DeploymentStatusService(transport: transport),
      deploymentTokenStore: deploymentTokenStore
    )
    store.updateActiveProfile { profile in
      profile.repositoryProvider = .github
      profile.repositoryBaseURL = "http://insecure.example.test"
      profile.repoOwner = "owner"
      profile.repoName = "site"
      profile.deploymentProvider = .githubPages
      profile.deploymentSiteURL = "https://owner.github.io/site/"
    }
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上发布：Fallback",
      summary: "github-pages",
      siteProfileID: store.activeProfileID,
      branchName: "main",
      commitSHA: "abc123"
    )
    store.setReleaseRecords([record])

    let snapshot = await store.refreshDeploymentStatus(for: record)

    XCTAssertNotNil(snapshot)
    XCTAssertEqual(store.deploymentTokenAvailability.accessState, .accessFailed)
    XCTAssertTrue(store.deploymentStatusMessage?.contains(CoreL10n.text("部署 Token 状态读取失败")) == true)
    XCTAssertFalse(store.deploymentStatusMessage?.contains(CoreL10n.text("未保存 Token")) == true)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.url?.absoluteString, "https://owner.github.io/site/")
    XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
  }

  func testStoreRefreshDeploymentStatusKeepsHistoryForRecord() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"status":"error","message":"Deploy failed"}"#),
      deploymentResponse(statusCode: 200, json: #"{"status":"ok","message":"Deploy recovered"}"#),
    ])
    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      deploymentStatusService: DeploymentStatusService(transport: transport)
    )
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .custom
      profile.deploymentStatusEndpointURL = "https://status.example.com/site"
    }
    let record = ReleaseRecord(
      title: "线上发布：History",
      summary: "custom",
      siteProfileID: store.activeProfileID
    )
    store.setReleaseRecords([record])

    let failedSnapshot = await store.refreshDeploymentStatus(for: record)
    try await Task.sleep(nanoseconds: 1_000_000)
    let recoveredSnapshot = await store.refreshDeploymentStatus(for: record)

    XCTAssertEqual(failedSnapshot?.level, .failed)
    XCTAssertEqual(recoveredSnapshot?.level, .success)
    XCTAssertEqual(store.deploymentStatusSnapshot(for: record)?.level, .success)
    XCTAssertEqual(store.deploymentStatusHistory(for: record).map(\.level), [.success, .failed])

    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(reloaded.deploymentStatusSnapshot(for: record)?.level, .success)
    XCTAssertEqual(reloaded.deploymentStatusHistory(for: record).map(\.level), [.success, .failed])
  }

  func testStoreIgnoresOlderDeploymentRefreshThatFinishesLast() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(
        statusCode: 200,
        json: #"{"status":"error","message":"stale failure"}"#,
        delayNanoseconds: 80_000_000
      ),
      deploymentResponse(
        statusCode: 200,
        json: #"{"status":"ok","message":"latest success"}"#,
        delayNanoseconds: 5_000_000
      ),
    ])
    let deploymentTokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.DeploymentStatusConcurrency",
      accountPrefix: "deployment-status-concurrency",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      deploymentStatusService: DeploymentStatusService(transport: transport),
      deploymentTokenStore: deploymentTokenStore
    )
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .custom
      profile.deploymentStatusEndpointURL = "https://status.example.com/site"
    }
    let record = ReleaseRecord(
      title: "线上发布：Concurrent",
      summary: "custom",
      siteProfileID: store.activeProfileID
    )
    store.setReleaseRecords([record])

    let olderRefresh = Task {
      await store.refreshDeploymentStatus(for: record)
    }
    for _ in 0..<200 {
      if (await transport.capturedRequests()).count == 1 { break }
      await Task.yield()
    }
    let newerRefresh = Task {
      await store.refreshDeploymentStatus(for: record)
    }

    let newerSnapshot = await newerRefresh.value
    let olderSnapshot = await olderRefresh.value

    XCTAssertEqual(newerSnapshot?.level, .success)
    XCTAssertNil(olderSnapshot)
    XCTAssertEqual(store.deploymentStatusSnapshot(for: record)?.level, .success)
    XCTAssertEqual(store.deploymentStatusHistory(for: record).map(\.level), [.success])
    XCTAssertEqual(
      store.deploymentStatusMessage,
      CoreL10n.format("%@：%@", DeploymentProvider.custom.displayName, CoreL10n.text("正常"))
    )
    XCTAssertFalse(store.isDeploymentStatusChecking)
  }

  func testStoreBlocksDeploymentStatusCheckWhenNoProviderEvidenceExists() async throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .custom
      profile.deploymentSiteURL = nil
      profile.deploymentStatusEndpointURL = nil
      profile.deploymentProjectID = nil
      profile.deploymentAccountID = nil
      profile.repoOwner = ""
      profile.repoName = ""
    }
    let record = ReleaseRecord(
      title: "线上发布：No Config",
      summary: "custom",
      siteProfileID: store.activeProfileID
    )

    XCTAssertFalse(store.canCheckDeploymentStatus(for: record))

    let snapshot = await store.refreshDeploymentStatus(for: record)

    XCTAssertNil(snapshot)
    XCTAssertTrue(store.deploymentStatusMessage?.contains(CoreL10n.text("站点 URL 或状态端点 URL")) == true)
  }

  func testStoreAllowsDeploymentStatusChecksFromPlatformProjectConfiguration() async throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .vercel
      profile.deploymentProjectID = "prj_123"
      profile.deploymentAccountID = "team_456"
      profile.deploymentSiteURL = nil
      profile.deploymentStatusEndpointURL = nil
      profile.repoOwner = ""
      profile.repoName = ""
    }
    let record = ReleaseRecord(
      title: "线上发布：Vercel",
      summary: "vercel",
      siteProfileID: store.activeProfileID
    )

    XCTAssertTrue(store.canCheckDeploymentStatus(for: record))
  }

  func testLegacySnapshotDecodesWithDefaultDeploymentPollingSettings() throws {
    let profile = SiteProfile.defaultProfile
    let encoded = try JSONEncoder.workbench.encode(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [ArticleDraft(siteProfileID: profile.id, title: "Legacy", slug: "legacy")],
        releaseRecords: [],
        deploymentPollingSettings: DeploymentPollingSettings(isEnabled: true, intervalMinutes: 20)
      )
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "deploymentPollingSettings")
    let json = try JSONSerialization.data(withJSONObject: object)

    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: json)

    XCTAssertFalse(snapshot.deploymentPollingSettings.isEnabled)
    XCTAssertEqual(snapshot.deploymentPollingSettings.normalizedIntervalMinutes, 10)
    XCTAssertEqual(snapshot.deploymentPollingState.status, .idle)
    XCTAssertTrue(snapshot.deploymentStatusSnapshots.isEmpty)
  }

  func testDeploymentPollingPersistsSettingsAndSkipsWhenNoEligibleRecords() async throws {
    let transport = SequencedDeploymentTransport(responses: [])
    let url = try temporaryPersistenceURL()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: url),
      deploymentStatusService: DeploymentStatusService(transport: transport)
    )

    store.updateDeploymentPollingSettings(DeploymentPollingSettings(isEnabled: true, intervalMinutes: 15))
    let didRun = await store.runDeploymentPolling(now: Date(timeIntervalSince1970: 1_900_000_000))

    XCTAssertTrue(didRun)
    XCTAssertEqual(store.deploymentPollingState.status, .noEligibleRecords)
    XCTAssertEqual(store.deploymentPollingState.checkedRecordCount, 0)
    let skippedRequests = await transport.capturedRequests()
    XCTAssertEqual(skippedRequests.count, 0)

    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertTrue(reloaded.deploymentPollingSettings.isEnabled)
    XCTAssertEqual(reloaded.deploymentPollingSettings.normalizedIntervalMinutes, 15)
  }

  func testDeploymentPollingStateDecodesLegacyPayloadWithoutCheckedRecords() throws {
    let data = """
    {
      "status": "checked",
      "checkedRecordCount": 2,
      "message": "部署轮询已检查 2 条待部署记录。"
    }
    """.data(using: .utf8)!

    let state = try JSONDecoder.workbench.decode(DeploymentPollingState.self, from: data)

    XCTAssertEqual(state.status, .checked)
    XCTAssertEqual(state.checkedRecordCount, 2)
    XCTAssertEqual(state.checkedRecords, [])
    XCTAssertEqual(state.successCount, 0)
    XCTAssertEqual(state.attentionCount, 0)
  }

  func testDeploymentPollingChecksPendingDeploymentRecordsAndCachesSnapshots() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"status":"ok"}"#),
    ])
    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      deploymentStatusService: DeploymentStatusService(transport: transport)
    )
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .custom
      profile.deploymentStatusEndpointURL = "https://status.example.com/site"
    }
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上发布：Polling",
      summary: "custom",
      siteProfileID: store.activeProfileID
    )
    store.setReleaseRecords([record])
    store.updateDeploymentPollingSettings(DeploymentPollingSettings(isEnabled: true, intervalMinutes: 5))

    let didRun = await store.tickDeploymentPolling(now: Date(timeIntervalSince1970: 1_900_000_000))

    XCTAssertTrue(didRun)
    XCTAssertEqual(store.deploymentPollingState.status, .checked)
    XCTAssertEqual(store.deploymentPollingState.checkedRecordCount, 1)
    XCTAssertEqual(store.deploymentPollingState.checkedRecords.map(\.recordID), [record.id])
    XCTAssertEqual(store.deploymentPollingState.checkedRecords.first?.title, "线上发布：Polling")
    XCTAssertEqual(store.deploymentPollingState.checkedRecords.first?.provider, .custom)
    XCTAssertEqual(store.deploymentPollingState.checkedRecords.first?.level, .success)
    XCTAssertEqual(store.deploymentPollingState.successCount, 1)
    XCTAssertEqual(store.deploymentPollingState.runningCount, 0)
    XCTAssertEqual(store.deploymentPollingState.attentionCount, 0)
    XCTAssertTrue(store.deploymentPollingState.message.contains(CoreL10n.format("正常 %@", "1")))
    XCTAssertEqual(store.deploymentStatusSnapshot(for: record)?.level, .success)
    let checkedRequests = await transport.capturedRequests()
    XCTAssertEqual(checkedRequests.count, 1)

    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(reloaded.deploymentPollingSettings.normalizedIntervalMinutes, 5)
    XCTAssertTrue(reloaded.deploymentPollingSettings.isEnabled)
    XCTAssertEqual(reloaded.deploymentPollingState.status, .checked)
    XCTAssertEqual(reloaded.deploymentPollingState.checkedRecords.map(\.recordID), [record.id])
    XCTAssertEqual(reloaded.deploymentStatusSnapshot(for: record)?.level, .success)
    XCTAssertEqual(reloaded.releaseLedger.entries.first?.status, .succeeded)
  }

  func testDeploymentPollingKeepsPartialRemoteRecoveryAttentionWhenDeploymentSucceeds() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"status":"ok","message":"Published"}"#),
    ])
    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      deploymentStatusService: DeploymentStatusService(transport: transport)
    )
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .custom
      profile.deploymentStatusEndpointURL = "https://status.example.com/partial"
    }
    let record = ReleaseRecord(
      kind: .remotePublishFailure,
      title: "线上发布中断：Partial",
      summary: "远端 commit 已写入，但后续确认失败。",
      siteProfileID: store.activeProfileID,
      commitSHA: "abc1234567890"
    )
    store.setReleaseRecords([record])
    store.updateDeploymentPollingSettings(DeploymentPollingSettings(isEnabled: true, intervalMinutes: 5))

    let didRun = await store.runDeploymentPolling(now: Date(timeIntervalSince1970: 1_900_000_900))

    XCTAssertTrue(didRun)
    XCTAssertEqual(store.deploymentPollingState.status, .checked)
    XCTAssertEqual(store.deploymentPollingState.checkedRecordCount, 1)
    XCTAssertEqual(store.deploymentPollingState.checkedRecords.first?.recordID, record.id)
    XCTAssertEqual(store.deploymentPollingState.checkedRecords.first?.releaseStatus, .pendingRemoteRecovery)
    XCTAssertEqual(store.deploymentPollingState.checkedRecords.first?.level, .success)
    XCTAssertEqual(store.deploymentPollingState.successCount, 0)
    XCTAssertEqual(store.deploymentPollingState.attentionCount, 1)
    XCTAssertTrue(store.deploymentPollingState.message.contains(CoreL10n.format("正常 %@", "0")))
    XCTAssertTrue(store.deploymentPollingState.message.contains(CoreL10n.format("远端恢复待确认 %@", "1")))
    XCTAssertTrue(store.deploymentPollingState.followUpChecklistMarkdown.contains(
      CoreL10n.text("# 部署轮询后续处理")
    ))
    XCTAssertTrue(store.deploymentPollingState.followUpChecklistMarkdown.contains(
      CoreL10n.format("- 需处理：%@", "1")
    ))
    XCTAssertTrue(store.deploymentPollingState.followUpChecklistMarkdown.contains(
      CoreL10n.text("确认远端恢复")
    ))
    XCTAssertTrue(store.deploymentPollingState.followUpChecklistMarkdown.contains(
      CoreL10n.text("即使本次状态信号正常，也要先确认远端部分写入、冲突路径和恢复包。")
    ))
    XCTAssertEqual(store.deploymentStatusSnapshot(for: record)?.level, .success)
    XCTAssertEqual(store.releaseLedger.entries.first?.status, .pendingRemoteRecovery)
    XCTAssertEqual(store.releaseLedger.summary.remoteRecoveryPendingCount, 1)
    XCTAssertEqual(store.releaseLedger.summary.succeededCount, 0)
    let checkedRequests = await transport.capturedRequests()
    XCTAssertEqual(checkedRequests.count, 1)

    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(reloaded.deploymentPollingState.checkedRecords.first?.releaseStatus, .pendingRemoteRecovery)
    XCTAssertEqual(reloaded.deploymentPollingState.successCount, 0)
    XCTAssertEqual(reloaded.deploymentPollingState.attentionCount, 1)
    XCTAssertEqual(reloaded.releaseLedger.entries.first?.status, .pendingRemoteRecovery)
  }

  func testDeploymentPollingSummarizesSuccessRunningAndFailedRecords() async throws {
    let transport = SequencedDeploymentTransport(responses: [
      deploymentResponse(statusCode: 200, json: #"{"status":"building","message":"Build still running"}"#),
      deploymentResponse(statusCode: 200, json: #"{"status":"error","message":"Deploy failed"}"#),
      deploymentResponse(statusCode: 200, json: #"{"message":"Deployment is reachable"}"#),
    ])
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      deploymentStatusService: DeploymentStatusService(transport: transport)
    )
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .custom
      profile.deploymentStatusEndpointURL = "https://status.example.com/site"
    }
    let runningRecord = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上发布：Running",
      summary: "custom",
      siteProfileID: store.activeProfileID
    )
    let failedRecord = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上发布：Failed",
      summary: "custom",
      siteProfileID: store.activeProfileID
    )
    let successRecord = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上发布：Success",
      summary: "custom",
      siteProfileID: store.activeProfileID
    )
    store.setReleaseRecords([runningRecord, failedRecord, successRecord])
    store.updateDeploymentPollingSettings(DeploymentPollingSettings(isEnabled: true, intervalMinutes: 5))

    let didRun = await store.runDeploymentPolling(now: Date(timeIntervalSince1970: 1_900_000_600))

    XCTAssertTrue(didRun)
    XCTAssertEqual(store.deploymentPollingState.status, .checked)
    XCTAssertEqual(store.deploymentPollingState.checkedRecordCount, 3)
    XCTAssertEqual(store.deploymentPollingState.successCount, 1)
    XCTAssertEqual(store.deploymentPollingState.runningCount, 1)
    XCTAssertEqual(store.deploymentPollingState.failedCount, 1)
    XCTAssertEqual(store.deploymentPollingState.unknownCount, 0)
    XCTAssertEqual(store.deploymentPollingState.attentionCount, 1)
    XCTAssertTrue(store.deploymentPollingState.message.contains(CoreL10n.format("正常 %@", "1")))
    XCTAssertTrue(store.deploymentPollingState.message.contains(CoreL10n.format("部署中 %@", "1")))
    XCTAssertTrue(store.deploymentPollingState.message.contains(CoreL10n.format("失败 %@", "1")))
    let checklist = store.deploymentPollingState.followUpChecklistMarkdown
    let checkedRecords = store.deploymentPollingState.checkedRecords
    XCTAssertTrue(checklist.contains(try XCTUnwrap(checkedRecords.first { $0.recordID == runningRecord.id }).followUpChecklistLine))
    XCTAssertTrue(checklist.contains(try XCTUnwrap(checkedRecords.first { $0.recordID == failedRecord.id }).followUpChecklistLine))
    XCTAssertTrue(checklist.contains(try XCTUnwrap(checkedRecords.first { $0.recordID == successRecord.id }).followUpChecklistLine))
    XCTAssertTrue(checklist.contains(
      CoreL10n.text("- [ ] 先处理远端待确认、失败和未知记录，再继续观察部署中记录。")
    ))
    XCTAssertEqual(store.deploymentStatusSnapshot(for: runningRecord)?.level, .running)
    XCTAssertEqual(store.deploymentStatusSnapshot(for: failedRecord)?.level, .failed)
    XCTAssertEqual(store.deploymentStatusSnapshot(for: successRecord)?.level, .success)
  }

  func testDeploymentWebhookParsesNetlifyDeployPayload() throws {
    let service = DeploymentWebhookService()
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .netlify
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上发布：Netlify",
      summary: "Netlify",
      siteProfileID: profile.id,
      branchName: "main",
      commitSHA: "abc123"
    )

    let result = try service.receive(
      provider: .netlify,
      payloadText: #"{"state":"ready","name":"personal-site","branch":"main","commit_ref":"abc123","admin_url":"https://app.netlify.com/sites/personal-site/deploys/1"}"#,
      profile: profile,
      releaseRecord: record,
      receivedAt: Date(timeIntervalSince1970: 1_900_000_000)
    )

    XCTAssertEqual(result.snapshot.provider, .netlify)
    XCTAssertEqual(result.snapshot.releaseRecordID, record.id)
    XCTAssertEqual(result.snapshot.level, .success)
    XCTAssertEqual(result.snapshot.title, "personal-site")
    XCTAssertEqual(result.snapshot.signals.first?.message, [
      CoreL10n.format("状态：%@", "ready"),
      CoreL10n.format("分支：%@", "main"),
      CoreL10n.format("提交：%@", "abc123"),
    ].joined(separator: " · "))
    XCTAssertEqual(result.snapshot.siteURLText, "https://app.netlify.com/sites/personal-site/deploys/1")
  }

  func testStoreReceivesDeploymentWebhookAndUpdatesSnapshotHistory() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .vercel
      profile.deploymentProjectID = "prj_123"
    }
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上发布：Vercel",
      summary: "Vercel",
      siteProfileID: store.activeProfileID,
      branchName: "main",
      commitSHA: "abc123"
    )
    store.setReleaseRecords([record])

    let running = store.receiveDeploymentWebhook(
      provider: .vercel,
      payloadText: #"{"type":"deployment.created","deployment":{"name":"personal-site","readyState":"BUILDING","target":"production","inspectorUrl":"https://vercel.com/team/site/1","meta":{"githubCommitRef":"main","githubCommitSha":"abc123"}}}"#,
      for: record,
      receivedAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
    let success = store.receiveDeploymentWebhook(
      provider: .vercel,
      payloadText: #"{"type":"deployment.succeeded","deployment":{"name":"personal-site","readyState":"READY","target":"production","inspectorUrl":"https://vercel.com/team/site/2","meta":{"githubCommitRef":"main","githubCommitSha":"abc123"}}}"#,
      for: record,
      receivedAt: Date(timeIntervalSince1970: 1_900_000_060)
    )

    XCTAssertEqual(running?.snapshot.level, .running)
    XCTAssertEqual(success?.snapshot.level, .success)
    XCTAssertEqual(store.deploymentStatusSnapshot(for: record)?.level, .success)
    let history = store.deploymentStatusHistory(for: record)
    XCTAssertEqual(history.map(\.level), [.success, .running])
    XCTAssertEqual(
      store.deploymentStatusMessage,
      CoreL10n.format("已接收 %@ Webhook：%@", "Vercel", CoreL10n.text("正常"))
    )
  }

  func testDeploymentProviderIntegrationDepthDocumentsThirdPartyAPIs() {
    XCTAssertTrue(DeploymentProvider.netlify.integrationDepth.title.contains("Netlify Deploy API"))
    XCTAssertTrue(DeploymentProvider.vercel.integrationDepth.title.contains("Vercel Deployments API"))
    XCTAssertTrue(DeploymentProvider.cloudflarePages.integrationDepth.detail.contains("Cloudflare Pages Deployments API"))
    XCTAssertEqual(
      DeploymentProvider.custom.integrationDepth.detail,
      CoreL10n.text("读取自定义 JSON/HTTP 状态端点，或使用站点 URL 做可达性与发布后页面校验。")
    )
  }

  func testDeploymentWebhookHTTPRequestParsesProviderAndPayload() throws {
    let body = #"{"state":"ready"}"#
    let request = """
    POST /deployment-webhook/cloudflare-pages HTTP/1.1\r
    Host: 127.0.0.1:8787\r
    Content-Type: application/json\r
    Content-Length: \(body.utf8.count)\r
    \r
    \(body)
    """

    let parsed = try XCTUnwrap(DeploymentWebhookHTTPRequest.parse(Data(request.utf8)))

    XCTAssertEqual(parsed.provider, .cloudflarePages)
    XCTAssertEqual(parsed.payloadText, body)
  }

  func testDeploymentWebhookHTTPRequestRejectsDuplicateContentLengthWithoutTrapping() {
    let body = #"{"state":"ready"}"#
    let request = """
    POST /deployment-webhook/vercel HTTP/1.1\r
    Host: 127.0.0.1:8787\r
    Content-Length: \(body.utf8.count)\r
    Content-Length: \(body.utf8.count)\r
    \r
    \(body)
    """

    XCTAssertNil(DeploymentWebhookHTTPRequest.parse(Data(request.utf8)))
  }

  func testDeploymentWebhookHTTPRequestAllowsRepeatedExtensionHeaders() throws {
    let body = #"{"state":"ready"}"#
    let request = """
    POST /deployment-webhook/vercel HTTP/1.1\r
    Host: 127.0.0.1:8787\r
    X-Debug-Trace: first\r
    X-Debug-Trace: second\r
    Content-Length: \(body.utf8.count)\r
    \r
    \(body)
    """

    let parsed = try XCTUnwrap(DeploymentWebhookHTTPRequest.parse(Data(request.utf8)))

    XCTAssertEqual(parsed.provider, .vercel)
    XCTAssertEqual(parsed.payloadText, body)
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }
}

private actor SequencedDeploymentTransport: RemoteRepositoryHTTPTransport {
  private var responses: [DeploymentTransportResponse]
  private var requests: [URLRequest] = []

  init(responses: [DeploymentTransportResponse]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard !responses.isEmpty else {
      XCTFail("Unexpected deployment status request: \(request.url?.absoluteString ?? "")")
      return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    }

    let response = responses.removeFirst()
    if response.delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: response.delayNanoseconds)
    }
    return (
      response.data,
      HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
    )
  }

  func capturedRequests() -> [URLRequest] {
    requests
  }
}

private struct DeploymentTransportResponse {
  var statusCode: Int
  var data: Data
  var delayNanoseconds: UInt64 = 0
}

private func deploymentResponse(
  statusCode: Int = 200,
  json: String,
  delayNanoseconds: UInt64 = 0
) -> DeploymentTransportResponse {
  DeploymentTransportResponse(
    statusCode: statusCode,
    data: Data(json.utf8),
    delayNanoseconds: delayNanoseconds
  )
}
