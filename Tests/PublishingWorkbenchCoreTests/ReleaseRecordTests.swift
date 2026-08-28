import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class ReleaseRecordTests: XCTestCase {
  func testDecodesLegacyReleaseRecordWithTraceableDefaults() throws {
    let json = """
    {
      "id": "1F3A8208-4D37-49FB-9DF3-3F9C29B6403A",
      "title": "旧记录",
      "summary": "旧版摘要",
      "commitSHA": "0123456789abcdef",
      "reviewURL": "https://example.com/review",
      "createdAt": "2026-07-05T12:00:00Z"
    }
    """.data(using: .utf8)!

    let record = try JSONDecoder.workbench.decode(ReleaseRecord.self, from: json)

    XCTAssertEqual(record.kind, .localWrite)
    XCTAssertEqual(record.title, "旧记录")
    XCTAssertEqual(record.summary, "旧版摘要")
    XCTAssertEqual(record.changedPaths, [])
    XCTAssertEqual(record.batchItems, [])
    XCTAssertEqual(record.shortCommitSHA, "01234567")
    XCTAssertEqual(record.reviewWebURL?.absoluteString, "https://example.com/review")
  }

  func testLocalWriteRecordCapturesPackageSiteAndPaths() {
    var profile = SiteProfile.defaultProfile
    profile.name = "工程笔记"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let coverID = UUID(uuidString: "46D2BA2F-21BA-4D03-A983-58C1D92DFAC5")!
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "发布记录",
      slug: "release-records",
      summary: "发布记录会保留当次文章摘要，供发布后校验社交元数据。",
      coverAttachmentID: coverID,
      bodyMarkdown: "Body",
      attachments: [
        DraftAttachment(
          id: coverID,
          originalFilename: "cover.jpg",
          relativePublishPath: "/images/cover.jpg",
          repositoryPath: "static/images/cover.jpg",
          altText: "发布记录封面"
        )
      ]
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let record = ReleaseRecord.localWrite(
      package: package,
      profile: profile,
      writtenPaths: ["content/posts/release-records.md"]
    )

    XCTAssertEqual(record.kind, .localWrite)
    XCTAssertEqual(record.siteProfileID, profile.id)
    XCTAssertEqual(record.siteName, "工程笔记")
    XCTAssertEqual(record.draftID, draft.id)
    XCTAssertEqual(record.draftTitle, "发布记录")
    XCTAssertEqual(record.draftSummary, "发布记录会保留当次文章摘要，供发布后校验社交元数据。")
    XCTAssertEqual(record.draftCoverAltText, "发布记录封面")
    XCTAssertEqual(record.markdownPath, "content/posts/release-records.md")
    XCTAssertEqual(record.changedPaths, ["content/posts/release-records.md"])
    XCTAssertNil(record.commitSHA)
  }

  func testReviewBranchRecordCapturesCommitAndReviewURL() throws {
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "jinfang"
    profile.repoName = "site"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Review Record",
      slug: "review-record",
      bodyMarkdown: "Body"
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let review = RemoteReviewDraftBuilder().build(package: package, profile: profile)
    let result = LocalGitPublishResult(
      mode: .reviewBranch,
      branchName: package.reviewBranchName,
      committedPaths: [package.markdownPath],
      commitSHA: "abcdef1234567890",
      commandLog: [],
      output: ""
    )

    let record = ReleaseRecord.gitPublish(
      package: package,
      profile: profile,
      result: result,
      reviewDraft: review
    )

    XCTAssertEqual(record.kind, .reviewBranch)
    XCTAssertEqual(record.branchName, package.reviewBranchName)
    XCTAssertEqual(record.targetBranch, "main")
    XCTAssertEqual(record.commitSHA, "abcdef1234567890")
    XCTAssertEqual(record.shortCommitSHA, "abcdef12")
    XCTAssertEqual(record.reviewTitle, review.title)
    XCTAssertTrue(try XCTUnwrap(record.reviewURL).contains("github.com/jinfang/site"))
  }

  func testBatchLocalWriteRecordCapturesSiteAndChangedPaths() {
    var profile = SiteProfile.defaultProfile
    profile.name = "批量站点"

    let package = PublishPackage(
      draftID: UUID(),
      title: "Batch Item",
      markdownPath: "content/posts/batch-item.md",
      files: [
        PublishPackageFile(kind: .markdown, repositoryPath: "content/posts/batch-item.md")
      ],
      commitMessage: "Publish: Batch Item",
      reviewBranchName: "publish/batch-item",
      reviewTitle: "Publish Batch Item",
      reviewChecklist: []
    )
    let preview = LocalPublishPreview(
      package: package,
      fileDiffs: [
        PublishFileDiff(path: package.markdownPath, kind: .markdown, status: .added)
      ],
      issues: []
    )
    let item = BatchPublishPlanItem(
      draftID: package.draftID,
      draftTitle: package.title,
      markdownPath: package.markdownPath,
      readiness: .ready,
      package: package,
      preview: preview,
      preflightIssues: []
    )

    let record = ReleaseRecord.batchLocalWrite(
      profile: profile,
      items: [item],
      writtenPaths: ["content/posts/batch-item.md", "static/images/batch.jpg"]
    )

    XCTAssertEqual(record.kind, .batchLocalWrite)
    XCTAssertEqual(record.siteProfileID, profile.id)
    XCTAssertEqual(record.siteName, "批量站点")
    XCTAssertNil(record.draftID)
    XCTAssertEqual(record.batchItems.count, 1)
    XCTAssertEqual(record.batchItems.first?.draftID, package.draftID)
    XCTAssertEqual(record.batchItems.first?.draftTitle, "Batch Item")
    XCTAssertEqual(record.batchItems.first?.markdownPath, "content/posts/batch-item.md")
    XCTAssertEqual(record.batchItems.first?.changedPaths, ["content/posts/batch-item.md"])
    XCTAssertEqual(record.changedPaths, ["content/posts/batch-item.md", "static/images/batch.jpg"])
    XCTAssertTrue(record.summary.contains("已写入 1 篇文章、2 个文件"))
  }

  func testRemotePublishRecordCapturesProviderBranchCommitAndReviewURL() {
    var profile = SiteProfile.defaultProfile
    profile.name = "线上站点"
    profile.repositoryProvider = .gitlab
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Remote Record",
      slug: "remote-record",
      bodyMarkdown: "Body"
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let result = RemoteRepositoryPublishResult(
      provider: .gitlab,
      mode: .reviewRequest,
      branchName: "publish/remote-record",
      targetBranch: "main",
      changedPaths: [package.markdownPath],
      commitSHA: "1234567890abcdef",
      reviewURL: "https://gitlab.com/group/site/-/merge_requests/9",
      reviewTitle: "Publish Remote Record"
    )

    let record = ReleaseRecord.remotePublish(package: package, profile: profile, result: result)

    XCTAssertEqual(record.kind, .remoteReviewRequest)
    XCTAssertEqual(record.siteName, "线上站点")
    XCTAssertEqual(record.branchName, "publish/remote-record")
    XCTAssertEqual(record.targetBranch, "main")
    XCTAssertEqual(record.shortCommitSHA, "12345678")
    XCTAssertEqual(record.reviewURL, "https://gitlab.com/group/site/-/merge_requests/9")
    XCTAssertEqual(record.changedPaths, [package.markdownPath])
    XCTAssertTrue(record.summary.contains("GitLab"))
  }

  func testPreviewPublishRecordUsesDedicatedNonProductionKind() {
    var profile = SiteProfile.defaultProfile
    profile.name = "预览站点"
    profile.repositoryProvider = .github
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Preview Record",
      slug: "preview-record",
      bodyMarkdown: "Body"
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let result = RemoteRepositoryPublishResult(
      provider: .github,
      mode: .previewBranch,
      branchName: "draft/preview-record",
      targetBranch: "main",
      changedPaths: [package.markdownPath],
      commitSHA: "preview1234567890"
    )

    let record = ReleaseRecord.remotePublish(package: package, profile: profile, result: result)

    XCTAssertEqual(record.kind, .remotePreviewBranch)
    XCTAssertEqual(record.branchName, "draft/preview-record")
    XCTAssertEqual(record.targetBranch, "main")
    XCTAssertEqual(record.reviewURL, nil)
  }

  func testBatchRemotePublishRecordCapturesTraceableDraftItems() {
    var profile = SiteProfile.defaultProfile
    profile.name = "批量线上站点"
    profile.repositoryProvider = .github

    let firstPackage = PublishPackage(
      draftID: UUID(),
      title: "Batch Remote One",
      markdownPath: "content/posts/batch-remote-one.md",
      files: [
        PublishPackageFile(kind: .markdown, repositoryPath: "content/posts/batch-remote-one.md"),
        PublishPackageFile(kind: .image, repositoryPath: "static/images/batch-remote-one.png"),
      ],
      commitMessage: "Publish: Batch Remote One",
      reviewBranchName: "publish/batch-remote-one",
      reviewTitle: "Publish Batch Remote One",
      reviewChecklist: []
    )
    let secondPackage = PublishPackage(
      draftID: UUID(),
      title: "Batch Remote Two",
      markdownPath: "content/posts/batch-remote-two.md",
      files: [
        PublishPackageFile(kind: .markdown, repositoryPath: "content/posts/batch-remote-two.md"),
      ],
      commitMessage: "Publish: Batch Remote Two",
      reviewBranchName: "publish/batch-remote-two",
      reviewTitle: "Publish Batch Remote Two",
      reviewChecklist: []
    )
    let items = [
      batchItem(package: firstPackage),
      batchItem(package: secondPackage),
    ]
    let result = RemoteRepositoryPublishResult(
      provider: .github,
      mode: .directCommit,
      branchName: "main",
      targetBranch: "main",
      changedPaths: [
        "content/posts/batch-remote-one.md",
        "static/images/batch-remote-one.png",
        "content/posts/batch-remote-two.md",
      ],
      commitSHA: "batch1234567890"
    )

    let record = ReleaseRecord.batchRemotePublish(profile: profile, items: items, result: result)

    XCTAssertEqual(record.kind, .remoteDirectCommit)
    XCTAssertEqual(record.batchItems.count, 2)
    XCTAssertEqual(record.batchItems.map(\.draftID), [firstPackage.draftID, secondPackage.draftID])
    XCTAssertEqual(record.batchItems.first?.draftTitle, "Batch Remote One")
    XCTAssertEqual(record.batchItems.first?.markdownPath, "content/posts/batch-remote-one.md")
    XCTAssertEqual(record.batchItems.first?.changedPaths, [
      "content/posts/batch-remote-one.md",
      "static/images/batch-remote-one.png",
    ])
    XCTAssertEqual(record.batchItems.last?.changedPaths, ["content/posts/batch-remote-two.md"])
  }

  func testBatchRemotePublishFailureRecoveryPackageIncludesDraftItems() {
    var profile = SiteProfile.defaultProfile
    profile.name = "批量失败站点"
    profile.repositoryProvider = .github

    let firstPackage = PublishPackage(
      draftID: UUID(),
      title: "Batch Failure One",
      markdownPath: "content/posts/batch-failure-one.md",
      files: [
        PublishPackageFile(kind: .markdown, repositoryPath: "content/posts/batch-failure-one.md"),
      ],
      commitMessage: "Publish: Batch Failure One",
      reviewBranchName: "publish/batch-failure-one",
      reviewTitle: "Publish Batch Failure One",
      reviewChecklist: []
    )
    let secondPackage = PublishPackage(
      draftID: UUID(),
      title: "Batch Failure Two",
      markdownPath: "content/posts/batch-failure-two.md",
      files: [
        PublishPackageFile(kind: .markdown, repositoryPath: "content/posts/batch-failure-two.md"),
      ],
      commitMessage: "Publish: Batch Failure Two",
      reviewBranchName: "publish/batch-failure-two",
      reviewTitle: "Publish Batch Failure Two",
      reviewChecklist: []
    )
    let batchPackage = PublishPackage(
      draftID: firstPackage.draftID,
      title: "2 articles",
      markdownPath: firstPackage.markdownPath,
      files: firstPackage.files + secondPackage.files,
      commitMessage: "Publish: 2 articles",
      reviewBranchName: "publish/batch",
      reviewTitle: "Publish 2 articles",
      reviewChecklist: []
    )
    let record = ReleaseRecord.batchRemotePublishFailure(
      package: batchPackage,
      profile: profile,
      items: [batchItem(package: firstPackage), batchItem(package: secondPackage)],
      mode: .directCommit,
      errorMessage: "部分完成后失败",
      changedPaths: ["content/posts/batch-failure-one.md"],
      commitSHA: "partial1234567890"
    )
    let entry = ReleaseLedgerService().ledger(
      releaseRecords: [record],
      deploymentStatusSnapshots: [:]
    ).entries[0]
    let package = entry.recoveryPackage

    XCTAssertEqual(record.batchItems.count, 2)
    XCTAssertTrue(package.clipboardMarkdown.contains("## 批量文章明细"))
    XCTAssertTrue(package.clipboardMarkdown.contains("Batch Failure One：content/posts/batch-failure-one.md"))
    XCTAssertTrue(package.clipboardMarkdown.contains("Batch Failure Two：content/posts/batch-failure-two.md"))
  }

  func testRemotePublishFailureRecordCapturesErrorAndPendingPaths() {
    var profile = SiteProfile.defaultProfile
    profile.name = "线上站点"
    profile.branch = "main"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Remote Failure",
      slug: "remote-failure",
      bodyMarkdown: "Body"
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)

    let record = ReleaseRecord.remotePublishFailure(
      package: package,
      profile: profile,
      mode: .directCommit,
      errorMessage: "直接提交失败：401"
    )

    XCTAssertEqual(record.kind, .remotePublishFailure)
    XCTAssertEqual(record.siteName, "线上站点")
    XCTAssertEqual(record.branchName, "main")
    XCTAssertEqual(record.targetBranch, "main")
    XCTAssertEqual(record.changedPaths, [package.markdownPath])
    XCTAssertEqual(record.summary, "直接提交失败：401")
  }

  func testStoreCreatesReleaseRecordWhenWritingSelectedDraftToRepository() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacReleaseRecordTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: false
    )
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.name = "发布站点"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)

    let draft = try XCTUnwrap(store.selectedDraft)
    store.refreshPublishPreview(for: draft)
    await store.writeSelectedDraftToLocalRepository()

    let record = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(record.kind, .localWrite)
    XCTAssertEqual(record.siteName, "发布站点")
    XCTAssertEqual(record.draftID, draft.id)
    let expectedPath = profile.markdownPath(for: draft)
    XCTAssertEqual(record.markdownPath, expectedPath)
    XCTAssertEqual(record.changedPaths, [expectedPath])
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent(expectedPath).path
      )
    )
    XCTAssertFalse(store.isLocalRepositoryMutationRunning)
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacReleaseRecordPersistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }

  private func batchItem(package: PublishPackage) -> BatchPublishPlanItem {
    let preview = LocalPublishPreview(
      package: package,
      fileDiffs: package.files.map {
        PublishFileDiff(path: $0.repositoryPath, kind: $0.kind, status: .added)
      },
      issues: []
    )
    return BatchPublishPlanItem(
      draftID: package.draftID,
      draftTitle: package.title,
      markdownPath: package.markdownPath,
      readiness: .ready,
      package: package,
      preview: preview,
      preflightIssues: []
    )
  }
}
