import Combine
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

@MainActor
final class MacMarkdownComposerFrontMatterConflictTests: XCTestCase {
  func testInvalidFrontMatterRecoveryRejectsMetadataChangedInAnotherWindow() throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MacMarkdownComposerFrontMatterConflict-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workbench.json")),
      safeMode: true
    )
    let original = try XCTUnwrap(store.selectedDraft)
    let recoveryMetadataRevision = original.editorMetadataRevision

    var secondWindowDraft = original
    secondWindowDraft.tags = ["another-window"]
    XCTAssertTrue(store.updateDraftFromEditor(secondWindowDraft))

    let current = try XCTUnwrap(store.draft(for: original.id))
    XCTAssertNotEqual(current.editorMetadataRevision, recoveryMetadataRevision)
    XCTAssertFalse(
      MacMarkdownFrontMatterRecoveryConflictPolicy.hasMatchingMetadataRevision(
        baseline: recoveryMetadataRevision,
        current: current.editorMetadataRevision
      )
    )
    XCTAssertFalse(
      MacMarkdownFrontMatterRecoveryConflictPolicy.hasMatchingMetadataRevision(
        baseline: nil,
        current: current.editorMetadataRevision
      )
    )
  }
}

@MainActor
final class MarkdownArticleHeaderMetadataTests: XCTestCase {
  func testNoticeRespectsOwnershipThemeResolutionAndSitePreference() {
    var profile = SiteProfile.defaultProfile
    var draft = ArticleDraft(
      siteProfileID: profile.id, title: "Title", bodyMarkdown: "# Title\nBody")
    func shows(_ resolved: Bool?, conflict: Bool = false) -> Bool {
      MarkdownDuplicateTitleNoticePolicy.shouldShow(
        draft: draft, profile: profile, body: draft.bodyMarkdown,
        hasFrontMatterIssue: conflict, resolvedWarning: resolved)
    }
    XCTAssertFalse(shows(nil), "Wait for automatic theme inspection.")
    XCTAssertTrue(shows(true))
    XCTAssertFalse(shows(false), "A theme that needs body H1 should not warn.")
    XCTAssertFalse(shows(true, conflict: true))
    profile.warnsWhenBodyH1DuplicatesTitle = false
    XCTAssertFalse(shows(true))
    profile.warnsWhenBodyH1DuplicatesTitle = true
    XCTAssertFalse(shows(false))
    XCTAssertTrue(shows(true))
    draft.assignToGeneralDraft(editingProfileID: profile.id)
    XCTAssertFalse(shows(true))
    draft = ArticleDraft(siteProfileID: UUID(), title: "Title", bodyMarkdown: "# Title")
    XCTAssertFalse(shows(true))
  }

  func testOnlyDraftIsChosenByHandAndPublishingStatesStayVisible() {
    var draft = ArticleDraft(siteProfileID: UUID(), title: "Site article", draft: true)
    XCTAssertEqual(ArticleStatePicker.availableStates(for: draft), [.draft])
    XCTAssertTrue(draft.setArticleState(.ready))
    XCTAssertEqual(ArticleStatePicker.availableStates(for: draft), [.draft, .ready])
    draft.status = .published
    XCTAssertEqual(ArticleStatePicker.availableStates(for: draft), [.draft, .published])
    draft.assignToGeneralDraft()
    XCTAssertEqual(ArticleStatePicker.availableStates(for: draft), [.localOnly])
  }

  func testBoundArticleUsesItsOwnerAndPreservesEveryLifecycleStatus() {
    let profile = SiteProfile(name: "Owner", localRepositoryRootPath: "/tmp/header-owner")
    for status in DraftStatus.allCases {
      let draft = ArticleDraft(
        siteProfileID: profile.id, title: "Article", draft: status == .draft, status: status,
        repositoryPath: "content/posts/article.md"
      )
      let metadata = MarkdownArticleHeaderMetadata(draft: draft, profile: profile)
      XCTAssertEqual(metadata.status, status)
      XCTAssertEqual(metadata.statusTitle, draft.articleState.displayName)
      XCTAssertEqual(metadata.relativePath, "content/posts/article.md")
      XCTAssertEqual(metadata.fileURL?.path, "/tmp/header-owner/content/posts/article.md")
    }
  }

  func testUnboundSiteArticleKeepsProposedPathWithoutFinderTarget() {
    let profile = SiteProfile(name: "Owner", localRepositoryRootPath: "/tmp/header-owner")
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Article", slug: "article")
    let metadata = MarkdownArticleHeaderMetadata(draft: draft, profile: profile)
    XCTAssertEqual(metadata.relativePath, profile.markdownPath(for: draft))
    XCTAssertNil(metadata.fileURL)
  }

  func testGeneralDraftDoesNotInventAPathInTheActiveSite() {
    let profile = SiteProfile(name: "Active", localRepositoryRootPath: "/tmp/header-active")
    let draft = ArticleDraft(siteProfileID: profile.id, scope: .general, title: "General")
    let metadata = MarkdownArticleHeaderMetadata(draft: draft, profile: profile)
    XCTAssertTrue(metadata.isGeneralDraft)
    XCTAssertEqual(metadata.statusTitle, ArticleState.localOnly.displayName)
    XCTAssertNil(metadata.relativePath)
    XCTAssertNil(metadata.fileURL)
  }

  func testMismatchedOrMissingOwnerCannotRevealAnotherSiteFile() {
    let profile = SiteProfile(name: "Other", localRepositoryRootPath: "/tmp/header-other")
    let draft = ArticleDraft(siteProfileID: UUID(), title: "Article", repositoryPath: "post.md")
    for owner in [profile, nil] {
      let metadata = MarkdownArticleHeaderMetadata(draft: draft, profile: owner)
      XCTAssertNil(metadata.relativePath)
      XCTAssertNil(metadata.fileURL)
    }
  }

  func testPathsCannotEscapeRepositoryRoot() {
    let profile = SiteProfile(name: "Owner", localRepositoryRootPath: "/tmp/header-owner")
    for path in ["../private.md", "/tmp/private.md", "content/../../private.md", "."] {
      let draft = ArticleDraft(siteProfileID: profile.id, title: "Article", repositoryPath: path)
      XCTAssertNil(MarkdownArticleHeaderMetadata(draft: draft, profile: profile).fileURL, path)
    }
  }

  func testPathMenuKeepsEveryParentReachableForLongAndShortPaths() {
    XCTAssertEqual(
      InteractiveBreadcrumbView.parentPaths(for: "content/posts/2026/10/article.md"),
      ["content", "content/posts", "content/posts/2026", "content/posts/2026/10"]
    )
    XCTAssertEqual(InteractiveBreadcrumbView.parentPaths(for: "article.md"), [])
    XCTAssertEqual(InteractiveBreadcrumbView.parentPaths(for: ""), [])
  }

  func testSwitchingArticlesDoesNotDropMetadataMatchingThePreviousArticle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json")),
      safeMode: true
    )
    let first = ArticleDraft(siteProfileID: store.activeProfileID, scope: .general, title: "First")
    var second = ArticleDraft(
      siteProfileID: store.activeProfileID, scope: .general, title: "Second", status: .ready
    )
    store.publishingStore.documents.drafts = [first, second]
    let state = MarkdownArticleHeaderMetadataState(store: store, draftID: first.id)
    state.trackDraft(second.id)
    XCTAssertEqual(state.value.status, .ready)
    let updated = expectation(description: "current article metadata replaces the old projection")
    let observation = state.$value.dropFirst().sink { value in
      if value.status == .draft { updated.fulfill() }
    }
    second.status = .draft
    store.publishingStore.documents.drafts = [first, second]
    await fulfillment(of: [updated], timeout: 1)
    XCTAssertEqual(state.value.status, .draft)
    withExtendedLifetime(observation) {}
  }

  func testHeaderObservationIgnoresBodyEditsAndTracksStatusChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json")),
      safeMode: true
    )
    var draft = try XCTUnwrap(store.selectedDraft)
    let state = MarkdownArticleHeaderMetadataState(store: store, draftID: draft.id)
    var changes = 0
    let subscription = state.objectWillChange.sink { changes += 1 }
    let bodyQuiet = expectation(description: "body-only mutation does not redraw header metadata")
    bodyQuiet.isInverted = true
    let bodyObservation = state.objectWillChange.sink { bodyQuiet.fulfill() }
    draft.bodyMarkdown += "\nNew body"
    XCTAssertTrue(store.updateDraftFromEditor(draft))
    await fulfillment(of: [bodyQuiet], timeout: 0.1)
    bodyObservation.cancel()
    XCTAssertEqual(changes, 0)
    draft = try XCTUnwrap(store.draft(for: draft.id))
    let updated = expectation(description: "committed article status is observed")
    let statusObservation = state.$value.dropFirst().sink { value in
      if value.status == .ready { updated.fulfill() }
    }
    draft.status = .ready
    XCTAssertTrue(store.updateDraftFromEditor(draft))
    await fulfillment(of: [updated], timeout: 1)
    XCTAssertEqual(state.value.status, .ready)
    withExtendedLifetime(statusObservation) {}
    XCTAssertEqual(changes, 1)
    state.trackDraft(UUID())
    XCTAssertNil(state.value.relativePath)
    XCTAssertNil(state.value.fileURL)
    withExtendedLifetime(subscription) {}
  }
}
