import Combine
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class RepositoryWorktreePublishStoreTests: XCTestCase {
  private struct Fixture {
    let baseURL: URL
    let worktreeURL: URL
    let profile: SiteProfile
    let draft: ArticleDraft
    let articleURL: URL
    let store: WorkbenchStore
    let persistenceURL: URL
  }

  func testPrepareFlushesActiveDirtyEditorBufferBeforeFreezingGitReview() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()

    fixture.store.publishingStore.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: fixture.draft.id,
        bodyMarkdown: "应当先落盘再进入完整 Git 清单。",
        revision: 1,
        isDirty: true
      ),
      for: fixture.draft.id
    )

    let confirmation = await fixture.store.prepareRepositoryWorktreePublish(
      commitMessage: "Publish buffered edit"
    )

    let review = try XCTUnwrap(confirmation)
    XCTAssertEqual(review.snapshot.paths, ["content/posts/article.md"])
    XCTAssertTrue(
      try String(contentsOf: fixture.articleURL, encoding: .utf8)
        .contains("应当先落盘再进入完整 Git 清单。")
    )
    XCTAssertFalse(fixture.store.draftBodyEditorBuffer(for: fixture.draft.id).isDirty)
  }

  func testPrepareRejectsBoundDraftFailedSaveWithPathAndReason() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    fixture.store.siteDraftFileSaveStates[fixture.draft.id] = .failed(
      repositoryPath: "content/posts/article.md", message: "磁盘写入失败")
    let headBefore = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL)
    let statusBefore = try git(
      ["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktreeURL)
    let articleBefore = try Data(contentsOf: fixture.articleURL)

    let confirmation = await fixture.store.prepareRepositoryWorktreePublish(
      commitMessage: "Publish all site changes")

    XCTAssertNil(confirmation)
    let message = try XCTUnwrap(fixture.store.publishActionMessage)
    XCTAssertTrue(message.contains("Article"), message)
    XCTAssertTrue(message.contains("content/posts/article.md"), message)
    XCTAssertTrue(message.contains("磁盘写入失败"), message)
    XCTAssertFalse(message.contains("待发布文件已变化"), message)
    XCTAssertEqual(try git(["rev-parse", "HEAD"], at: fixture.worktreeURL), headBefore)
    XCTAssertEqual(
      try git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktreeURL),
      statusBefore)
    XCTAssertEqual(try Data(contentsOf: fixture.articleURL), articleBefore)
  }

  func testPrepareRejectsBoundDraftPendingSaveWithPath() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    fixture.store.siteDraftFileSaveStates[fixture.draft.id] = .pending(
      repositoryPath: "content/posts/article.md")

    let confirmation = await fixture.store.prepareRepositoryWorktreePublish(
      commitMessage: "Publish all site changes")

    XCTAssertNil(confirmation)
    let message = try XCTUnwrap(fixture.store.publishActionMessage)
    XCTAssertTrue(message.contains("文章尚未保存成功"), message)
    XCTAssertTrue(message.contains("content/posts/article.md"), message)
  }

  func testImportedISODateBlocksArticlePublishWithoutMutatingRepositoryState() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()

    fixture.store.updateActiveProfile { profile in
      profile.dateFormat = "yyyy-MM-dd"
    }
    var imported = fixture.draft
    imported.importedFrontMatter = .init(
      rawBlock: "---\ntitle: \"Article\"\ndate: \"2024-02-30T03:04:05Z\"\nslug: \"article\"\n---",
      syntax: .yaml
    )
    imported.date = Date(timeIntervalSince1970: 1_704_168_245)
    imported.importedFrontMatter = ArticleFrontMatterPreservation.capturing(
      try XCTUnwrap(imported.importedFrontMatter), draft: imported,
      profile: fixture.store.activeProfile)
    let importedDocument = FrontMatterRenderer().renderDocument(
      draft: imported, profile: fixture.store.activeProfile)
    try importedDocument.write(to: fixture.articleURL, atomically: true, encoding: .utf8)
    imported.recordProjectFile(
      profile: fixture.store.activeProfile,
      repositoryPath: "content/posts/article.md",
      renderedContentDigest: ArticleDraft.repositoryDocumentDigest(importedDocument)
    )
    fixture.store.updateDraft(imported)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    XCTAssertTrue(fixture.store.focusDraft(imported.id, section: .writing))

    let unrelatedURL = fixture.worktreeURL.appendingPathComponent("staged-unrelated.txt")
    try "keep this staged change\n".write(to: unrelatedURL, atomically: true, encoding: .utf8)
    _ = try git(["add", "--", "staged-unrelated.txt"], at: fixture.worktreeURL)
    let headBefore = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL)
    let statusBefore = try git(
      ["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktreeURL)
    let articleBefore = try String(contentsOf: fixture.articleURL, encoding: .utf8)

    let preparation = await fixture.store.prepareArticleRepositoryPublish(draftID: imported.id)
    guard case .blocked(let draftID, let issues) = preparation else {
      return XCTFail("Expected date preflight to block publishing, got \(preparation)")
    }
    XCTAssertEqual(draftID, imported.id)
    XCTAssertTrue(
      issues.contains { $0.ruleID == "frontmatter.date-format" },
      "Expected the date-format issue, got \(issues)")
    XCTAssertEqual(try git(["rev-parse", "HEAD"], at: fixture.worktreeURL), headBefore)
    XCTAssertEqual(
      try git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktreeURL),
      statusBefore)
    XCTAssertEqual(
      try String(contentsOf: fixture.articleURL, encoding: .utf8), articleBefore)
  }

  func testPreparePreservesExternalArticleWhenEditorBufferIsAlsoDirty() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    let externalDocument = "+++\ntitle = \"External\"\n+++\n外部编辑器写入的内容。\n"
    try externalDocument.write(to: fixture.articleURL, atomically: true, encoding: .utf8)
    fixture.store.publishingStore.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: fixture.draft.id,
        bodyMarkdown: "软件内尚未落盘的另一份修改。",
        revision: 1,
        isDirty: true
      ),
      for: fixture.draft.id
    )

    let confirmation = await fixture.store.prepareRepositoryWorktreePublish(
      commitMessage: "Do not overwrite external edit"
    )

    XCTAssertNil(confirmation)
    XCTAssertEqual(
      try String(contentsOf: fixture.articleURL, encoding: .utf8),
      externalDocument
    )
    XCTAssertTrue(fixture.store.draftBodyEditorBuffer(for: fixture.draft.id).isDirty)
    XCTAssertTrue(fixture.store.publishActionMessage?.contains("外部修改") == true)
  }

  func testPublishThisArticleCommitsOnlyItsFilesAndKeepsOtherChangesLocal() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    let themeURL = fixture.worktreeURL.appendingPathComponent("theme.css")
    try "body {}\n".write(to: themeURL, atomically: true, encoding: .utf8)
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))
    fixture.store.publishingStore.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: fixture.draft.id, bodyMarkdown: "单独发布的新正文。", revision: 1, isDirty: true),
      for: fixture.draft.id
    )

    let preparation = await fixture.store.prepareArticleRepositoryPublish(
      draftID: fixture.draft.id)
    guard case .review(let confirmation) = preparation else {
      return XCTFail("Expected a review, got \(preparation)")
    }
    XCTAssertTrue(confirmation.isScoped)
    XCTAssertEqual(confirmation.snapshot.paths, ["content/posts/article.md"])

    let result = await fixture.store.publishRepositoryWorktree(confirmation)
    XCTAssertEqual(result?.committedPaths, ["content/posts/article.md"])
    XCTAssertEqual(
      try git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktreeURL),
      "?? theme.css\n")

    let again = await fixture.store.prepareArticleRepositoryPublish(draftID: fixture.draft.id)
    guard case .unavailable(let message) = again else {
      return XCTFail("An unchanged article has nothing to publish, got \(again)")
    }
    XCTAssertTrue(message.contains("没有需要发布的新变化"))
  }

  func testScopedArticlePublishIgnoresUnrelatedDirtyAndFailedSaveState() async throws {
    let fixture = try makeFixture(draftFlag: false)
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()

    var unrelated = ArticleDraft(
      siteProfileID: fixture.profile.id,
      title: "Unrelated",
      slug: "unrelated",
      bodyMarkdown: "无关文章基线。",
      repositoryPath: "content/posts/unrelated.md"
    )
    let unrelatedDocument = FrontMatterRenderer().renderDocument(
      draft: unrelated, profile: fixture.profile)
    unrelated.recordProjectFile(
      profile: fixture.profile,
      repositoryPath: "content/posts/unrelated.md",
      renderedContentDigest: ArticleDraft.repositoryDocumentDigest(unrelatedDocument)
    )
    fixture.store.publishingStore.drafts.append(unrelated)
    fixture.store.publishingStore.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: unrelated.id, bodyMarkdown: "无关文章尚未保存。", revision: 1, isDirty: true),
      for: unrelated.id
    )
    fixture.store.siteDraftFileSaveStates[unrelated.id] = .failed(
      repositoryPath: "content/posts/unrelated.md", message: "fixture save failure")

    fixture.store.publishingStore.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: fixture.draft.id, bodyMarkdown: "目标文章的新正文。", revision: 1, isDirty: true),
      for: fixture.draft.id
    )
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))

    let preparation = await fixture.store.prepareArticleRepositoryPublish(
      draftID: fixture.draft.id)
    guard case .review(let confirmation) = preparation else {
      return XCTFail("The selected article must remain publishable: \(preparation)")
    }
    XCTAssertTrue(confirmation.isScoped)
    XCTAssertEqual(confirmation.snapshot.paths, ["content/posts/article.md"])

    let result = await fixture.store.publishRepositoryWorktree(confirmation)
    XCTAssertNotNil(result)
    XCTAssertEqual(fixture.store.draft(for: unrelated.id)?.bodyMarkdown, "无关文章尚未保存。")
    let remotePaths = try git(
      ["ls-tree", "-r", "--name-only", "refs/remotes/origin/main"], at: fixture.worktreeURL)
    XCTAssertTrue(remotePaths.contains("content/posts/article.md"))
    XCTAssertFalse(remotePaths.contains("content/posts/unrelated.md"))
    XCTAssertNotNil(fixture.store.releaseRecords.first?.articlePublishTrackingRequest)
  }

  func testScopedPublishRejectsConfirmationWhenTargetChangesAfterReview() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    fixture.store.publishingStore.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: fixture.draft.id, bodyMarkdown: "确认时的正文。", revision: 1, isDirty: true),
      for: fixture.draft.id
    )
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))

    let preparation = await fixture.store.prepareArticleRepositoryPublish(
      draftID: fixture.draft.id)
    guard case .review(let confirmation) = preparation else {
      return XCTFail("Expected a review, got \(preparation)")
    }
    let baseline = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL)
    try "外部修改使确认过期。\n".write(to: fixture.articleURL, atomically: true, encoding: .utf8)

    let result = await fixture.store.publishRepositoryWorktree(confirmation)
    XCTAssertNil(result)
    XCTAssertEqual(try git(["rev-parse", "HEAD"], at: fixture.worktreeURL), baseline)
    XCTAssertTrue(
      fixture.store.publishActionMessage?.contains("变化") == true
        || fixture.store.publishActionMessage?.contains("重新") == true,
      fixture.store.publishActionMessage ?? "missing publish rejection")
    XCTAssertEqual(
      try String(contentsOf: fixture.articleURL, encoding: .utf8),
      "外部修改使确认过期。\n"
    )
  }

  func testConsecutiveArticleRenamesPublishAllOldDeletionsAndKeepOtherChangesLocal() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    let themeURL = fixture.worktreeURL.appendingPathComponent("theme.css")
    try "body {}\n".write(to: themeURL, atomically: true, encoding: .utf8)
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))

    var renamed = fixture.draft
    renamed.slug = "b"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    renamed = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    renamed.slug = "c"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()

    let preparation = await fixture.store.prepareArticleRepositoryPublish(
      draftID: fixture.draft.id)
    guard case .review(let confirmation) = preparation else {
      return XCTFail("Expected a review, got \(preparation)")
    }
    XCTAssertEqual(
      confirmation.snapshot.paths,
      ["content/posts/article.md", "content/posts/c.md"])
    let preparedAgain = await fixture.store.prepareArticleRepositoryPublish(
      draftID: fixture.draft.id)
    guard case .review(let repeatedConfirmation) = preparedAgain else {
      return XCTFail("Expected the cancelled review to be reproducible, got \(preparedAgain)")
    }
    XCTAssertEqual(repeatedConfirmation.snapshot.paths, confirmation.snapshot.paths)

    _ = await fixture.store.publishRepositoryWorktree(confirmation)
    let headPaths = try git(
      ["ls-tree", "-r", "--name-only", "HEAD"], at: fixture.worktreeURL)
    XCTAssertFalse(headPaths.contains("content/posts/article.md"))
    XCTAssertFalse(headPaths.contains("content/posts/b.md"))
    XCTAssertTrue(headPaths.contains("content/posts/c.md"))
    let remotePaths = try git(
      ["ls-tree", "-r", "--name-only", "refs/remotes/origin/main"], at: fixture.worktreeURL)
    XCTAssertFalse(remotePaths.contains("content/posts/article.md"))
    XCTAssertFalse(remotePaths.contains("content/posts/b.md"))
    XCTAssertTrue(remotePaths.contains("content/posts/c.md"))
    XCTAssertEqual(
      try git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktreeURL),
      "?? theme.css\n")
  }

  func testArticleRenameJournalSurvivesSiteDraftFileStoreRecreation() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))

    var renamed = fixture.draft
    renamed.slug = "b"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    renamed = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))

    let recreatedStore = SiteDraftFileStore(
      moveJournalURL: fixture.persistenceURL.appendingPathExtension("article-moves"))
    XCTAssertEqual(
      try recreatedStore.pendingMovePaths(
        draft: renamed, profile: fixture.profile, otherArticlePaths: []),
      ["content/posts/article.md"])
  }

  func testArticleRenameStopsWhenOldPathIsRecreatedExternally() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))

    var renamed = fixture.draft
    renamed.slug = "b"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    let externalDocument = "external recreation\n"
    try externalDocument.write(to: fixture.articleURL, atomically: true, encoding: .utf8)

    let preparation = await fixture.store.prepareArticleRepositoryPublish(
      draftID: fixture.draft.id)
    guard case .unavailable(let message) = preparation else {
      return XCTFail("Expected an unavailable result, got \(preparation)")
    }
    XCTAssertTrue(message.contains("content/posts/article.md"))
    XCTAssertEqual(
      try String(contentsOf: fixture.articleURL, encoding: .utf8), externalDocument)
  }

  func testArticleRenameBackAndForwardPublishesEachChangedPath() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))

    var renamed = fixture.draft
    renamed.slug = "b"
    renamed.bodyMarkdown = "正文 B。"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    renamed = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    renamed.slug = fixture.draft.slug
    renamed.bodyMarkdown = "正文 A 的新版本。"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()

    let firstPreparation = await fixture.store.prepareArticleRepositoryPublish(
      draftID: fixture.draft.id)
    guard case .review(let firstConfirmation) = firstPreparation else {
      return XCTFail("Expected a review, got \(firstPreparation)")
    }
    XCTAssertEqual(firstConfirmation.snapshot.paths, ["content/posts/article.md"])
    let firstResult = await fixture.store.publishRepositoryWorktree(firstConfirmation)
    XCTAssertNotNil(firstResult)
    XCTAssertFalse(
      try git(["ls-tree", "-r", "--name-only", "HEAD"], at: fixture.worktreeURL)
        .contains("content/posts/b.md"))

    renamed = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    renamed.slug = "c"
    renamed.bodyMarkdown = "正文 C。"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()

    let secondPreparation = await fixture.store.prepareArticleRepositoryPublish(
      draftID: fixture.draft.id)
    guard case .review(let secondConfirmation) = secondPreparation else {
      return XCTFail("Expected a review, got \(secondPreparation)")
    }
    XCTAssertEqual(
      secondConfirmation.snapshot.paths,
      ["content/posts/article.md", "content/posts/c.md"])
    let secondResult = await fixture.store.publishRepositoryWorktree(secondConfirmation)
    XCTAssertNotNil(secondResult)
    let headPaths = try git(
      ["ls-tree", "-r", "--name-only", "HEAD"], at: fixture.worktreeURL)
    XCTAssertFalse(headPaths.contains("content/posts/article.md"))
    XCTAssertFalse(headPaths.contains("content/posts/b.md"))
    XCTAssertTrue(headPaths.contains("content/posts/c.md"))
  }

  func testPendingMovePathsKeepsImmutableOriginalRevisionEvidence() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))

    var renamed = fixture.draft
    renamed.slug = "b"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    renamed = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    let originalHead = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL)
      .trimmedForPublishing
    let moveStore = SiteDraftFileStore(
      moveJournalURL: fixture.persistenceURL.appendingPathExtension("article-moves"))
    XCTAssertEqual(
      try moveStore.pendingMovePaths(
        draft: renamed, profile: fixture.profile, otherArticlePaths: [], revision: originalHead),
      ["content/posts/article.md"])

    try "externally rewritten\n".write(
      to: fixture.articleURL, atomically: true, encoding: .utf8)
    _ = try git(["add", "--", "content/posts/article.md"], at: fixture.worktreeURL)
    _ = try git(["commit", "-m", "external rewrite"], at: fixture.worktreeURL)
    try FileManager.default.removeItem(at: fixture.articleURL)
    let newHead = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL)
      .trimmedForPublishing

    XCTAssertThrowsError(
      try moveStore.pendingMovePaths(
        draft: renamed, profile: fixture.profile, otherArticlePaths: [], revision: newHead)
    ) { error in
      XCTAssertEqual(
        error as? SiteDraftFileStoreError,
        .projectFileChangedExternally("content/posts/article.md"))
    }
    XCTAssertEqual(
      try moveStore.pendingMovePaths(
        draft: renamed, profile: fixture.profile, otherArticlePaths: [], revision: originalHead),
      ["content/posts/article.md"])
  }

  func testPendingMovePathsRejectsJournalWhenRecordedHeadIsNotAncestor() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))

    let originalHead = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL)
      .trimmedForPublishing
    let unrelatedURL = fixture.worktreeURL.appendingPathComponent("unrelated.txt")
    try "unrelated commit\n".write(to: unrelatedURL, atomically: true, encoding: .utf8)
    _ = try git(["add", "--", "unrelated.txt"], at: fixture.worktreeURL)
    _ = try git(["commit", "-m", "unrelated"], at: fixture.worktreeURL)
    let newerHead = try git(["rev-parse", "HEAD"], at: fixture.worktreeURL)
      .trimmedForPublishing
    XCTAssertNotEqual(newerHead, originalHead)

    var renamed = fixture.draft
    renamed.slug = "b"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    renamed = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    let moveStore = SiteDraftFileStore(
      moveJournalURL: fixture.persistenceURL.appendingPathExtension("article-moves"))
    let journalURL = fixture.persistenceURL.appendingPathExtension("article-moves")
    let journalBefore = try FileManager.default.contentsOfDirectory(
      at: journalURL, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }
    XCTAssertEqual(journalBefore.count, 1)

    let remoteBefore = try git(
      ["rev-parse", "refs/remotes/origin/main"], at: fixture.worktreeURL
    ).trimmedForPublishing
    try git(["update-ref", "refs/heads/main", originalHead], at: fixture.worktreeURL)
    XCTAssertEqual(
      try git(["rev-parse", "HEAD"], at: fixture.worktreeURL).trimmedForPublishing,
      originalHead)
    let statusBefore = try git(
      ["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktreeURL)

    XCTAssertThrowsError(
      try moveStore.pendingMovePaths(
        draft: renamed, profile: fixture.profile, otherArticlePaths: [])
    ) { error in
      XCTAssertEqual(
        error as? SiteDraftFileStoreError,
        .projectFileChangedExternally("content/posts/article.md"))
    }
    XCTAssertEqual(
      try git(["rev-parse", "refs/remotes/origin/main"], at: fixture.worktreeURL)
        .trimmedForPublishing,
      remoteBefore)
    XCTAssertEqual(
      try git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktreeURL),
      statusBefore)
    let journalAfter = try FileManager.default.contentsOfDirectory(
      at: journalURL, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }
    XCTAssertEqual(journalAfter.count, 1, "Rejected journal must remain for recovery")
  }

  func testPendingMovePathsCleansJournalAfterSuccessfulPublishDeletesOldPath() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))

    var renamed = fixture.draft
    renamed.slug = "b"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    renamed = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    let moveStore = SiteDraftFileStore(
      moveJournalURL: fixture.persistenceURL.appendingPathExtension("article-moves"))
    XCTAssertEqual(
      try moveStore.pendingMovePaths(
        draft: renamed, profile: fixture.profile, otherArticlePaths: []),
      ["content/posts/article.md"])

    let preparation = await fixture.store.prepareArticleRepositoryPublish(draftID: fixture.draft.id)
    guard case .review(let confirmation) = preparation else {
      return XCTFail("Expected a review, got \(preparation)")
    }
    XCTAssertTrue(confirmation.snapshot.paths.contains("content/posts/article.md"))
    _ = await fixture.store.publishRepositoryWorktree(confirmation)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.articleURL.path))

    XCTAssertEqual(
      try moveStore.pendingMovePaths(
        draft: renamed, profile: fixture.profile, otherArticlePaths: []),
      [])
    let journalURL = fixture.persistenceURL.appendingPathExtension("article-moves")
    let remainingJournal =
      (try? FileManager.default.contentsOfDirectory(
        at: journalURL, includingPropertiesForKeys: nil
      ).filter { $0.pathExtension == "json" }) ?? []
    XCTAssertTrue(remainingJournal.isEmpty)
    let remotePaths = try git(
      ["ls-tree", "-r", "--name-only", "refs/remotes/origin/main"], at: fixture.worktreeURL)
    XCTAssertFalse(remotePaths.contains("content/posts/article.md"))
    XCTAssertTrue(remotePaths.contains("content/posts/b.md"))
  }

  func testPrepareArticleRepositoryPublishRejectsNewPathOwnerAddedWhileReviewWasFrozen()
    async throws
  {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))

    var renamed = fixture.draft
    renamed.slug = "b"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    let remoteBefore = try git(
      ["rev-parse", "refs/remotes/origin/main"], at: fixture.worktreeURL
    ).trimmedForPublishing
    let statusBefore = try git(
      ["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktreeURL)
    var didInsertOwner = false
    let cancellable = fixture.store.publishingStore.publishSession.$publishActionFeedback
      .sink { feedback in
        guard !didInsertOwner, feedback?.message.contains("已冻结") == true else { return }
        didInsertOwner = true
        let owner = ArticleDraft(
          siteProfileID: fixture.profile.id,
          title: "Old path owner",
          slug: "old-path-owner",
          bodyMarkdown: "占用旧路径的文章。",
          repositoryPath: "content/posts/article.md")
        fixture.store.publishingStore.drafts.append(owner)
      }

    let preparation = await fixture.store.prepareArticleRepositoryPublish(draftID: fixture.draft.id)
    cancellable.cancel()
    XCTAssertTrue(didInsertOwner, "The frozen-review seam must run deterministically")
    guard case .unavailable(let message) = preparation else {
      return XCTFail(
        "Expected unavailable after another article claims the old path, got \(preparation)")
    }
    XCTAssertTrue(message.contains("content/posts/article.md"), message)
    XCTAssertEqual(
      try git(["rev-parse", "refs/remotes/origin/main"], at: fixture.worktreeURL)
        .trimmedForPublishing,
      remoteBefore)
    XCTAssertEqual(
      try git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.worktreeURL),
      statusBefore)
  }

  func testArticleRenameJournalWriteFailureKeepsOldFileAndSkipsNewFile() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    let journalURL = fixture.persistenceURL.appendingPathExtension("article-moves")
    try FileManager.default.createDirectory(
      at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "journal path is occupied\n".write(to: journalURL, atomically: true, encoding: .utf8)
    let originalDocument = try String(contentsOf: fixture.articleURL, encoding: .utf8)
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))

    var renamed = fixture.draft
    renamed.slug = "b"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()

    XCTAssertEqual(
      try String(contentsOf: fixture.articleURL, encoding: .utf8), originalDocument)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.worktreeURL.appendingPathComponent("content/posts/b.md").path))
  }

  func testPendingMovePathsRejectsOtherArticleOwnershipAndIgnoresOtherBranch() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    XCTAssertTrue(fixture.store.focusDraft(fixture.draft.id, section: .writing))

    var renamed = fixture.draft
    renamed.slug = "b"
    fixture.store.updateDraft(renamed)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    renamed = try XCTUnwrap(fixture.store.draft(for: fixture.draft.id))
    let moveStore = SiteDraftFileStore(
      moveJournalURL: fixture.persistenceURL.appendingPathExtension("article-moves"))

    XCTAssertThrowsError(
      try moveStore.pendingMovePaths(
        draft: renamed,
        profile: fixture.profile,
        otherArticlePaths: ["content/posts/article.md"])
    ) { error in
      XCTAssertEqual(
        error as? SiteDraftFileStoreError,
        .projectFileChangedExternally("content/posts/article.md"))
    }

    var otherBranch = fixture.profile
    otherBranch.branch = "other"
    XCTAssertEqual(
      try moveStore.pendingMovePaths(
        draft: renamed, profile: otherBranch, otherArticlePaths: []),
      [])
  }

  func testPrepareAllChangesIncludesNonArticleFiles() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    await fixture.store.waitForPendingSiteDraftFileWrites()
    let themeURL = fixture.worktreeURL.appendingPathComponent("theme.css")
    try "body {}\n".write(to: themeURL, atomically: true, encoding: .utf8)

    let preparation = await fixture.store.prepareRepositoryWorktreePublish(
      commitMessage: "Publish all site changes")
    guard let confirmation = preparation else {
      return XCTFail(
        "Expected a review, got \(String(describing: fixture.store.publishActionMessage))")
    }
    XCTAssertTrue(confirmation.snapshot.paths.contains("theme.css"))
    _ = await fixture.store.publishRepositoryWorktree(confirmation)

    let remotePaths = try git(
      ["ls-tree", "-r", "--name-only", "refs/remotes/origin/main"], at: fixture.worktreeURL)
    XCTAssertTrue(remotePaths.contains("theme.css"))
    XCTAssertNil(fixture.store.releaseRecords.first?.articlePublishTrackingRequest)
  }

  private func makeFixture(draftFlag: Bool = true) throws -> Fixture {
    let baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("repopress-worktree-store-\(UUID().uuidString)", isDirectory: true)
    let worktreeURL = baseURL.appendingPathComponent("worktree", isDirectory: true)
    let ownerURL = baseURL.appendingPathComponent("owner", isDirectory: true)
    let remoteURL = ownerURL.appendingPathComponent("site.git", isDirectory: true)
    let articleURL = worktreeURL.appendingPathComponent(
      "content/posts/article.md",
      isDirectory: false
    )
    try FileManager.default.createDirectory(
      at: articleURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: ownerURL, withIntermediateDirectories: true)

    let profile = SiteProfile(
      name: "Test",
      localRepositoryRootPath: worktreeURL.path,
      repoOwner: "owner",
      repoName: "site",
      branch: "main",
      markdownPathPattern: "content/posts/{slug}.md"
    )
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Article",
      slug: "article",
      bodyMarkdown: "已写入项目的基线内容。"
    )
    draft.draft = draftFlag
    let baselineDocument = FrontMatterRenderer().renderDocument(draft: draft, profile: profile)
    try baselineDocument.write(to: articleURL, atomically: true, encoding: .utf8)
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: "content/posts/article.md",
      renderedContentDigest: ArticleDraft.repositoryDocumentDigest(baselineDocument)
    )

    _ = try git(["init", "--bare", "-b", "main", remoteURL.path], at: baseURL)
    _ = try git(["init", "-b", "main"], at: worktreeURL)
    _ = try git(["config", "user.email", "test@example.com"], at: worktreeURL)
    _ = try git(["config", "user.name", "RepoPress Tests"], at: worktreeURL)
    _ = try git(["add", "-A", "--", "."], at: worktreeURL)
    _ = try git(["commit", "-m", "base"], at: worktreeURL)
    _ = try git(["remote", "add", "origin", remoteURL.path], at: worktreeURL)
    _ = try git(["push", "-u", "origin", "main"], at: worktreeURL)

    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draft],
      softwareGuideSeedVersion: ArticleDraft.currentSoftwareGuideSeedVersion,
      releaseRecords: []
    )
    let persistenceURL = baseURL.appendingPathComponent("app-data/workbench.json")
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: persistenceURL
      ),
      initialSnapshotSource: .preloaded(
        WorkbenchSnapshotLoadResult(snapshot: snapshot)
      )
    )
    return Fixture(
      baseURL: baseURL,
      worktreeURL: worktreeURL,
      profile: profile,
      draft: draft,
      articleURL: articleURL,
      store: store,
      persistenceURL: persistenceURL
    )
  }

  @discardableResult
  private func git(_ arguments: [String], at rootURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", rootURL.path] + arguments
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let output = String(
      decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    let error = String(
      decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositoryWorktreePublishStoreTests.Git",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: error]
      )
    }
    return output
  }
}
