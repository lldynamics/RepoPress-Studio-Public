import XCTest
@testable import PublishingWorkbenchCore

final class BatchPublishPlanServiceTests: XCTestCase {
  func testPlanClassifiesDraftsByBatchReadiness() throws {
    let rootURL = try makeRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let unchangedDraft = longDraft(profile: profile, title: "Unchanged", slug: "unchanged")
    let unchangedPackage = PublishPackageBuilder().build(draft: unchangedDraft, profile: profile)
    let unchangedContent = try XCTUnwrap(unchangedPackage.markdownFile?.content)
    try unchangedContent.write(
      to: rootURL.appendingPathComponent("content/posts/unchanged.md"),
      atomically: true,
      encoding: .utf8
    )

    let readyDraft = longDraft(profile: profile, title: "Ready", slug: "ready")
    var needsReviewDraft = longDraft(profile: profile, title: "Needs Review", slug: "needs-review")
    needsReviewDraft.draft = true
    let blockedDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Blocked",
      slug: "",
      draft: false,
      bodyMarkdown: "Long enough body content for a blocked draft with a missing slug in the batch queue."
    )

    let plan = BatchPublishPlanService().plan(
      drafts: [readyDraft, needsReviewDraft, blockedDraft, unchangedDraft],
      profile: profile,
      repositoryReport: nil
    )

    XCTAssertEqual(plan.items.first { $0.draftID == readyDraft.id }?.readiness, .ready)
    XCTAssertEqual(plan.items.first { $0.draftID == needsReviewDraft.id }?.readiness, .needsReview)
    XCTAssertEqual(plan.items.first { $0.draftID == blockedDraft.id }?.readiness, .blocked)
    XCTAssertEqual(plan.items.first { $0.draftID == unchangedDraft.id }?.readiness, .unchanged)
    XCTAssertEqual(plan.readyCount, 1)
    XCTAssertEqual(plan.needsReviewCount, 1)
    XCTAssertEqual(plan.blockedCount, 1)
    XCTAssertEqual(plan.unchangedCount, 1)
    XCTAssertEqual(Set(plan.writableItems.map(\.draftID)), Set([readyDraft.id]))
  }

  func testPlanMarksRemoteSamePathChangesAsNeedsReview() throws {
    let rootURL = try makeRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = longDraft(profile: profile, title: "Remote Review", slug: "remote-review")
    let repositoryReport = RepositoryScanReport(
      rootPath: rootURL.path,
      detectedKind: profile.siteKind,
      expectedKind: profile.siteKind,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 0,
      imageFileCount: 0,
      changedFiles: [],
      remoteChangedFiles: [
        RepositoryChangedFile(status: "M", path: "content/posts/remote-review.md", kind: .modified)
      ],
      preflightIssues: []
    )

    let plan = BatchPublishPlanService().plan(
      drafts: [draft],
      profile: profile,
      repositoryReport: repositoryReport
    )
    let item = try XCTUnwrap(plan.items.first)

    XCTAssertEqual(item.readiness, .needsReview)
    XCTAssertFalse(item.isWritable)
    XCTAssertEqual(plan.remotePublishableItems.map(\.draftID), [draft.id])
    XCTAssertEqual(item.warningCount, 1)
    XCTAssertTrue(item.preflightIssues.contains { issue in
      issue.title == "远端同路径变更"
        && issue.message.contains("content/posts/remote-review.md")
    })
  }

  func testPlanBlocksDifferentImagePayloadsForSameDestination() throws {
    let rootURL = try makeRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let firstImageURL = rootURL.appendingPathComponent("first-source.png")
    let secondImageURL = rootURL.appendingPathComponent("second-source.png")
    try Data([1, 2, 3, 4]).write(to: firstImageURL)
    try Data([4, 3, 2, 1]).write(to: secondImageURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    var firstDraft = longDraft(profile: profile, title: "First Image", slug: "first-image")
    firstDraft.attachments = [sharedAttachment(sourceURL: firstImageURL)]
    var secondDraft = longDraft(profile: profile, title: "Second Image", slug: "second-image")
    secondDraft.attachments = [sharedAttachment(sourceURL: secondImageURL)]

    let plan = BatchPublishPlanService().plan(
      drafts: [firstDraft, secondDraft],
      profile: profile,
      repositoryReport: nil
    )

    XCTAssertEqual(plan.blockedCount, 2)
    XCTAssertTrue(plan.remotePublishableItems.isEmpty)
    XCTAssertTrue(plan.items.allSatisfy { item in
      item.preflightIssues.contains {
        $0.title == "批量目标路径冲突"
          && $0.message.contains("static/images/shared.png")
      }
    })
  }

  func testEquivalentSharedImageIsAllowedAndDeduplicatedForRemotePublish() throws {
    let rootURL = try makeRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let firstImageURL = rootURL.appendingPathComponent("first-source.png")
    let secondImageURL = rootURL.appendingPathComponent("second-source.png")
    let sharedData = Data([1, 2, 3, 4])
    try sharedData.write(to: firstImageURL)
    try sharedData.write(to: secondImageURL)

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    var firstDraft = longDraft(profile: profile, title: "First Image", slug: "first-image")
    firstDraft.attachments = [sharedAttachment(sourceURL: firstImageURL)]
    var secondDraft = longDraft(profile: profile, title: "Second Image", slug: "second-image")
    secondDraft.attachments = [sharedAttachment(sourceURL: secondImageURL, repositorySHA: "image-sha")]

    let plan = BatchPublishPlanService().plan(
      drafts: [firstDraft, secondDraft],
      profile: profile,
      repositoryReport: nil
    )
    let mergedFiles = deduplicatedBatchPublishFiles(plan.remotePublishableItems.flatMap(\.package.files))
    let sharedImages = mergedFiles.filter { $0.repositoryPath == "static/images/shared.png" }

    XCTAssertEqual(plan.blockedCount, 0)
    XCTAssertEqual(plan.remotePublishableItems.count, 2)
    XCTAssertEqual(sharedImages.count, 1)
    XCTAssertEqual(sharedImages.first?.expectedRemoteSHA, "image-sha")
  }

  private func makeRepositoryRoot() throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacBatchPlanTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    return rootURL
  }

  private func longDraft(profile: SiteProfile, title: String, slug: String) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: profile.id,
      title: title,
      slug: slug,
      draft: false,
      bodyMarkdown: "This article body is intentionally longer than the preflight minimum so batch readiness is driven by repository diff state."
    )
  }

  private func sharedAttachment(sourceURL: URL, repositorySHA: String? = nil) -> DraftAttachment {
    DraftAttachment(
      originalFilename: "shared.png",
      relativePublishPath: "/images/shared.png",
      repositoryPath: "static/images/shared.png",
      altText: "Shared image",
      byteSize: 4,
      sourceFilePath: sourceURL.path,
      repositorySHA: repositorySHA
    )
  }
}

final class BatchPublishCommandBuilderTests: XCTestCase {
  func testBuildsBatchCommitAndReviewBranchCommandsForWritableItems() throws {
    let rootURL = URL(fileURLWithPath: "/tmp/site", isDirectory: true)
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = rootURL.path
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let firstDraft = longDraft(profile: profile, title: "First Batch", slug: "first-batch")
    let secondDraft = longDraft(profile: profile, title: "Second Batch", slug: "second-batch")
    var blockedDraft = longDraft(profile: profile, title: "Blocked Batch", slug: "")
    blockedDraft.bodyMarkdown = "Long enough content but missing slug means this item stays blocked."

    let plan = BatchPublishPlanService().plan(
      drafts: [firstDraft, secondDraft, blockedDraft],
      profile: profile,
      repositoryReport: nil
    )
    let builder = BatchPublishCommandBuilder()

    XCTAssertEqual(
      builder.directCommitCommand(plan: plan, profile: profile),
      "cd '/tmp/site' && git add 'content/posts/first-batch.md' 'content/posts/second-batch.md' && git commit -m 'Publish: 2 articles'"
    )

    XCTAssertEqual(
      builder.reviewBranchCommands(
        plan: plan,
        profile: profile,
        now: Date(timeIntervalSince1970: 1_788_000_000)
      ),
      [
        "cd '/tmp/site'",
        "git switch -c 'publish/batch-20260829-1040-2-articles'",
        "git add 'content/posts/first-batch.md' 'content/posts/second-batch.md'",
        "git commit -m 'Publish: 2 articles'",
        "git push -u origin 'publish/batch-20260829-1040-2-articles'",
      ]
    )
  }

  func testCommitCommandSafelyQuotesShellSyntaxInTitleAndRepositoryPath() {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = "/tmp/site $(touch /tmp/should-not-run)"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = longDraft(
      profile: profile,
      title: "Title $(touch /tmp/should-not-run) `id` 'quoted'\nnext",
      slug: "safe"
    )
    let plan = BatchPublishPlanService().plan(drafts: [draft], profile: profile, repositoryReport: nil)
    let command = BatchPublishCommandBuilder().directCommitCommand(plan: plan, profile: profile) ?? ""

    XCTAssertEqual(
      command,
      "cd '/tmp/site $(touch /tmp/should-not-run)' && git add 'content/posts/safe.md' && git commit -m 'Publish: Title $(touch /tmp/should-not-run) `id` '\\''quoted'\\''\nnext'"
    )
  }

  func testReturnsNilCommandsWithoutRepositoryOrWritableItems() throws {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = ""
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let draft = longDraft(profile: profile, title: "Ready", slug: "ready")
    let plan = BatchPublishPlanService().plan(drafts: [draft], profile: profile, repositoryReport: nil)
    let builder = BatchPublishCommandBuilder()

    XCTAssertNil(builder.directCommitCommand(plan: plan, profile: profile))
    XCTAssertTrue(builder.reviewBranchCommands(plan: plan, profile: profile).isEmpty)

    profile.localRepositoryRootPath = "/tmp/site"
    let unchangedPackage = PublishPackageBuilder().build(draft: draft, profile: profile)
    let unchangedPreview = LocalPublishPreview(
      package: unchangedPackage,
      fileDiffs: [
        PublishFileDiff(path: unchangedPackage.markdownPath, kind: .markdown, status: .unchanged)
      ],
      issues: []
    )
    let unchangedPlan = BatchPublishPlan(
      profileID: profile.id,
      siteName: profile.name,
      items: [
        BatchPublishPlanItem(
          draftID: draft.id,
          draftTitle: draft.title,
          markdownPath: unchangedPackage.markdownPath,
          readiness: .unchanged,
          package: unchangedPackage,
          preview: unchangedPreview,
          preflightIssues: []
        )
      ]
    )

    XCTAssertNil(builder.directCommitCommand(plan: unchangedPlan, profile: profile))
    XCTAssertTrue(builder.reviewBranchCommands(plan: unchangedPlan, profile: profile).isEmpty)
  }

  private func longDraft(profile: SiteProfile, title: String, slug: String) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: profile.id,
      title: title,
      slug: slug,
      draft: false,
      bodyMarkdown: "This article body is intentionally longer than the preflight minimum so batch command tests focus on git command output."
    )
  }
}

@MainActor
final class WorkbenchStoreBatchPublishTests: XCTestCase {
  func testBatchWriteOnlyWritesWritableDraftsAndRecordsRelease() async throws {
    let rootURL = try makeRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)

    let readyDraft = longDraft(profile: profile, title: "Ready Batch", slug: "ready-batch")
    var needsReviewDraft = longDraft(profile: profile, title: "Review Batch", slug: "review-batch")
    needsReviewDraft.draft = true
    let blockedDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Blocked Batch",
      slug: "",
      draft: false,
      bodyMarkdown: "Long enough body content for a blocked batch draft with no publishable slug."
    )

    store.setDrafts([readyDraft, needsReviewDraft, blockedDraft])
    store.setSelectedDraftID(readyDraft.id)
    store.runPreflight()

    let result = await store.writeBatchReadyDraftsToLocalRepository()

    XCTAssertEqual(result.writtenDraftCount, 1)
    XCTAssertEqual(result.skippedCount, 2)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("content/posts/ready-batch.md").path)
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("content/posts/review-batch.md").path)
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("content/posts/.md").path)
    )
    XCTAssertEqual(store.releaseRecords.first?.kind, .batchLocalWrite)
    XCTAssertEqual(store.monetizationState.freeUsage.batchPublishCount, 1)
    XCTAssertTrue(store.publishActionMessage?.contains("已批量写入 1 篇") == true)
    XCTAssertFalse(store.isLocalRepositoryMutationRunning)
  }

  func testBatchOnlinePublishStopsWhenReviewedFileScopeChanged() async throws {
    let rootURL = try makeRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)

    let draft = longDraft(profile: profile, title: "Reviewed Batch", slug: "reviewed-batch")
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let result = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
      expectedChangedPaths: Set(["content/posts/a-different-file.md"])
    )

    XCTAssertNil(result)
    XCTAssertTrue(store.publishActionMessage?.contains("待发布文件已变化") == true)
    XCTAssertFalse(store.isRemoteRepositoryPublishing)
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacBatchStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }

  private func makeRepositoryRoot() throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacBatchStoreRepo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    return rootURL
  }

  private func longDraft(profile: SiteProfile, title: String, slug: String) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: profile.id,
      title: title,
      slug: slug,
      draft: false,
      bodyMarkdown: "This article body is intentionally longer than the preflight minimum so store batch publishing can focus on write behavior."
    )
  }
}
