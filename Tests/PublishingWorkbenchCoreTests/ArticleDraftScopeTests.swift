import Foundation
import PublishingSyncCore
import XCTest
@testable import PublishingWorkbenchCore

final class ArticleDraftScopeTests: XCTestCase {
  func testNewDraftBodiesAreEmptyAndGuidesHaveNoRepeatedTitleHeading() {
    let profile = SiteProfile.defaultProfile
    XCTAssertEqual(ArticleDraft.empty(profile: profile).bodyMarkdown, "")
    XCTAssertEqual(ArticleDraft.emptyGeneralDraft(editingProfile: profile).bodyMarkdown, "")
    for language in ["zh-Hans", "en"] {
      let guides = ArticleDraft.samples(profile: profile, preferredLanguage: language)
      XCTAssertEqual(guides.count, 6)
      for guide in guides {
        XCTAssertFalse(guide.bodyMarkdown.hasPrefix("# "), guide.title)
        XCTAssertFalse(guide.bodyMarkdown.isEmpty, guide.title)
      }
    }
  }

  func testGettingStartedGuideMatchesCurrentNavigationAndEditor() throws {
    let guide = try XCTUnwrap(
      ArticleDraft.samples(profile: .defaultProfile, preferredLanguage: "zh-Hans")
        .first { $0.softwareGuideID == "getting-started" }
    )

    XCTAssertEqual(ArticleDraft.currentSoftwareGuideSeedVersion, 11)
    XCTAssertTrue(guide.bodyMarkdown.contains("全局搜索（⇧⌘K）"))
    XCTAssertTrue(guide.bodyMarkdown.contains("五个一级入口"))
    XCTAssertTrue(guide.bodyMarkdown.contains("站点检查"))
    XCTAssertTrue(guide.bodyMarkdown.contains("通用草稿（General Drafts）"))
    XCTAssertFalse(guide.bodyMarkdown.contains("编辑 / 预览 / 分屏"))
  }

  func testEnglishGettingStartedGuideUsesCurrentNavigationAndEditor() throws {
    let guide = try XCTUnwrap(
      ArticleDraft.samples(profile: .defaultProfile, preferredLanguage: "en")
        .first { $0.softwareGuideID == "getting-started" }
    )

    XCTAssertTrue(guide.bodyMarkdown.contains("Global search (⇧⌘K)"))
    XCTAssertTrue(guide.bodyMarkdown.contains("five primary workspace entries"))
    XCTAssertTrue(guide.bodyMarkdown.contains("Site Checks"))
    XCTAssertTrue(guide.bodyMarkdown.contains("General Drafts"))
    XCTAssertFalse(guide.bodyMarkdown.contains("Edit, Preview, and Split"))
  }

  func testLegacyDraftWithoutScopeStorageDecodesAsSiteDraft() throws {
    let profileID = UUID()
    let draft = ArticleDraft(siteProfileID: profileID, title: "Legacy")
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any]
    )
    object.removeValue(forKey: "scopeStorage")

    let decoded = try JSONDecoder().decode(
      ArticleDraft.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertEqual(decoded.scope, .site(profileID))
    XCTAssertFalse(decoded.isGeneralDraft)
    XCTAssertTrue(decoded.belongs(toSiteProfileID: profileID))
  }

  func testGeneralDraftRoundTripKeepsScopeAndEditingContext() throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft.emptyGeneralDraft(editingProfile: profile)

    let decoded = try JSONDecoder().decode(
      ArticleDraft.self,
      from: JSONEncoder().encode(draft)
    )

    XCTAssertEqual(decoded.scope, .general)
    XCTAssertTrue(decoded.isGeneralDraft)
    XCTAssertEqual(decoded.siteProfileID, profile.id)
    XCTAssertFalse(decoded.belongs(toSiteProfileID: profile.id))
  }

  func testGeneralFolderRoundTripLegacyDefaultAndSiteConversion() throws {
    let profileID = UUID()
    var draft = ArticleDraft(siteProfileID: profileID, scope: .general, title: "Foldered")
    XCTAssertTrue(draft.setGeneralDraftFolderName(" Research "))
    XCTAssertEqual(draft.generalDraftFolderName, "Research")
    XCTAssertFalse(draft.setGeneralDraftFolderName("../site"))
    XCTAssertEqual(draft.generalDraftFolderName, "Research")

    let data = try JSONEncoder().encode(draft)
    let restored = try JSONDecoder().decode(ArticleDraft.self, from: data)
    XCTAssertEqual(restored.generalDraftFolderName, "Research")

    var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacyObject.removeValue(forKey: "generalDraftFolderNameStorage")
    let legacy = try JSONDecoder().decode(
      ArticleDraft.self,
      from: JSONSerialization.data(withJSONObject: legacyObject)
    )
    XCTAssertNil(legacy.generalDraftFolderName)

    draft.assignToSite(profileID)
    XCTAssertNil(draft.generalDraftFolderName)
  }
}

@MainActor
final class WorkbenchDraftScopeTests: XCTestCase {
  func testGeneralFolderMoveChangesOnlyGeneralDraftOrganization() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "GeneralFolderMove")
    let siteDraft = try XCTUnwrap(store.visibleDrafts.first)
    store.createGeneralDraft()
    let generalDraft = try XCTUnwrap(store.selectedDraft)

    XCTAssertEqual(
      store.moveGeneralDrafts([siteDraft.id, generalDraft.id], toFolder: "Research"),
      1
    )
    let moved = try XCTUnwrap(store.draft(for: generalDraft.id))
    XCTAssertEqual(moved.generalDraftFolderName, "Research")
    XCTAssertEqual(moved.slug, generalDraft.slug)
    XCTAssertEqual(moved.repositoryPath, generalDraft.repositoryPath)
    XCTAssertGreaterThan(moved.editorMetadataRevision, generalDraft.editorMetadataRevision)
    XCTAssertNil(store.draft(for: siteDraft.id)?.generalDraftFolderName)

    XCTAssertEqual(store.moveGeneralDrafts([generalDraft.id], toFolder: "bad/name"), 0)
    XCTAssertEqual(store.draft(for: generalDraft.id)?.generalDraftFolderName, "Research")
    XCTAssertEqual(store.moveGeneralDrafts([generalDraft.id], toFolder: nil), 1)
    XCTAssertNil(store.draft(for: generalDraft.id)?.generalDraftFolderName)
  }

  func testWritingScopeSeparatesSiteAndGeneralDrafts() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftScope")
    let siteDraftID = try XCTUnwrap(store.visibleDrafts.first?.id)

    store.createGeneralDraft()
    let generalDraft = try XCTUnwrap(store.selectedDraft)

    XCTAssertEqual(store.draftListContentScope, .general)
    XCTAssertEqual(generalDraft.scope, .general)
    XCTAssertEqual(store.writingDrafts.map(\.id), [generalDraft.id])
    XCTAssertFalse(store.visibleDrafts.contains(where: { $0.id == generalDraft.id }))
    XCTAssertEqual(store.preflightIssues(for: generalDraft).map(\.field), ["scope"])
    XCTAssertNil(store.publishPackage)

    store.setDraftListContentScope(.currentSite)

    XCTAssertEqual(store.writingDrafts.map(\.id), [siteDraftID])
    XCTAssertEqual(store.selectedDraftID, siteDraftID)

    store.setDraftListContentScope(.general)

    XCTAssertEqual(store.selectedDraftID, generalDraft.id)
  }

  func testDeletingEditingContextSiteDoesNotDeleteGeneralDraft() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "GeneralDraftSiteDeletion")
    let originalProfileID = store.activeProfileID
    store.createGeneralDraft()
    let generalDraftID = try XCTUnwrap(store.selectedDraftID)
    _ = store.createProfile(named: "Second")
    store.selectProfile(originalProfileID)

    _ = store.deleteActiveProfile()

    let retained = try XCTUnwrap(store.drafts.first(where: { $0.id == generalDraftID }))
    XCTAssertTrue(retained.isGeneralDraft)
    XCTAssertEqual(retained.siteProfileID, store.activeProfileID)
  }

  func testGeneralDraftCanBeRestoredAfterItsEditingContextSiteIsDeleted() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "GeneralDraftRecycleRecovery")
    let originalProfileID = store.activeProfileID
    store.createGeneralDraft()
    let generalDraftID = try XCTUnwrap(store.selectedDraftID)
    store.deleteDraft(id: generalDraftID)
    _ = store.createProfile(named: "Second")
    store.selectProfile(originalProfileID)
    _ = store.deleteActiveProfile()

    XCTAssertTrue(store.restoreRecycledDraft(generalDraftID))

    let restored = try XCTUnwrap(store.drafts.first(where: { $0.id == generalDraftID }))
    XCTAssertTrue(restored.isGeneralDraft)
    XCTAssertEqual(restored.siteProfileID, store.activeProfileID)
    XCTAssertEqual(store.draftListContentScope, .general)
  }

  func testCopyingGeneralDraftToEditingContextSiteKeepsSourceAndCreatesSiteDraft() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "GeneralDraftCopy")
    let targetProfileID = store.activeProfileID
    store.createGeneralDraft()
    var source = try XCTUnwrap(store.selectedDraft)
    source.slug = "general-copy-\(UUID().uuidString.lowercased())"
    store.updateDraft(source)

    let copied = try XCTUnwrap(store.copyDraft(source.id, toProfileID: targetProfileID))

    XCTAssertEqual(copied.scope, .site(targetProfileID))
    XCTAssertFalse(copied.isGeneralDraft)
    XCTAssertEqual(store.draftListContentScope, .currentSite)
    XCTAssertEqual(store.selectedDraftID, copied.id)
    XCTAssertTrue(store.drafts.contains(where: { $0.id == source.id && $0.isGeneralDraft }))
  }
}

final class ArticlePublishReminderPlanTests: XCTestCase {
  func testOnlyFutureExplicitRemindersProduceNotificationPlans() {
    let now = Date(timeIntervalSince1970: 1_000)
    var future = ArticleDraft.empty(profile: .defaultProfile)
    future.publishReminderAt = now.addingTimeInterval(60)
    var past = future
    past.id = UUID()
    past.publishReminderAt = now.addingTimeInterval(-1)
    var unscheduled = future
    unscheduled.id = UUID()
    unscheduled.publishReminderAt = nil
    unscheduled.date = now.addingTimeInterval(3_600)
    let plans = ArticlePublishReminderPlan.plans(for: [future, past, unscheduled], now: now)
    XCTAssertEqual(plans.map(\.draftID), [future.id])
    XCTAssertEqual(plans.first?.date, future.publishReminderAt)
    XCTAssertEqual(future.date, past.date)
  }

  func testReminderPersistsAndDoesNotChangeRepositoryContentFingerprint() throws {
    var draft = ArticleDraft.empty(profile: .defaultProfile)
    let previousFingerprint = draft.repositoryContentFingerprint
    let previousMetadata = ArticleDraftMetadataProjection(draft: draft)
    draft.publishReminderAt = Date(timeIntervalSince1970: 5_000)
    let decoded = try JSONDecoder().decode(ArticleDraft.self, from: JSONEncoder().encode(draft))
    XCTAssertEqual(decoded.publishReminderAt, draft.publishReminderAt)
    XCTAssertEqual(draft.repositoryContentFingerprint, previousFingerprint)
    XCTAssertNotEqual(ArticleDraftMetadataProjection(draft: draft), previousMetadata)
    var legacy = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any]
    )
    legacy.removeValue(forKey: "publishReminderAt")
    let restored = try JSONDecoder().decode(
      ArticleDraft.self, from: JSONSerialization.data(withJSONObject: legacy)
    )
    XCTAssertNil(restored.publishReminderAt)
  }

  func testWorkflowFragmentPreservesGeneratorBoundary() {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .hugo
    let hugo = ScheduledPublishWorkflowTemplate(profile: profile)
    XCTAssertTrue(hugo.supportsFutureContent)
    XCTAssertTrue(hugo.triggerYAML.contains("17 * * * *"))
    XCTAssertTrue(hugo.triggerYAML.contains("workflow_dispatch"))
    profile.siteKind = .jekyll
    XCTAssertTrue(
      ScheduledPublishWorkflowTemplate(profile: profile).supportsFutureContent,
      "Jekyll skips future-dated posts unless `future` is enabled")
    profile.siteKind = .zola
    XCTAssertFalse(ScheduledPublishWorkflowTemplate(profile: profile).supportsFutureContent)
    profile.siteKind = .hexo
    XCTAssertFalse(ScheduledPublishWorkflowTemplate(profile: profile).supportsFutureContent)
  }

  func testControlledSitesCannotStartAnUnsignedAutomaticRebase() {
    var profile = SiteProfile.defaultProfile
    profile.gitExecutionPolicy = .init(sshCommitSigningEnabled: true, sshSigningKey: "/key.pub")
    // A missing root deliberately proves rejection happens before repository
    // access, fetching, stash creation or history rewriting.
    XCTAssertThrowsError(try RepositoryRebaseSyncService().prepare(profile: profile)) { error in
      XCTAssertTrue(error is RepositoryControlledRebaseError)
    }
    profile.gitExecutionPolicy = nil
    XCTAssertFalse(profile.requiresControlledCommitExecution)
  }

  func testRestoringBackupDoesNotRestoreLocalExecutionPermissions() {
    var profile = SiteProfile.defaultProfile
    profile.gitExecutionPolicy = .init(
      sshCommitSigningEnabled: true, sshSigningKey: "/key.pub",
      trustedHooksRepositoryPath: "/repo", trustedHooksGitDirectoryPath: "/repo/.git"
    )
    let snapshot = WorkbenchSnapshot(
      profiles: [profile], activeProfileID: profile.id, drafts: [], releaseRecords: []
    )
    let restored = snapshot.removingLocalGitExecutionPermissions()
    XCTAssertNil(restored.profiles.first?.gitExecutionPolicy)
    XCTAssertEqual(restored.activeProfileID, profile.id)
    XCTAssertNotNil(snapshot.profiles.first?.gitExecutionPolicy)
  }
}

final class ArticleStateTests: XCTestCase {
  func testStateProjectionResolvesConflictingLegacyFields() {
    var draft = ArticleDraft(siteProfileID: UUID(), title: "Article", draft: true, status: .ready)
    XCTAssertEqual(draft.articleState, .draft)
    draft.draft = false
    XCTAssertEqual(draft.articleState, .ready)
    draft.status = .published
    XCTAssertEqual(draft.articleState, .published)
    draft.visibility = .private
    XCTAssertEqual(draft.articleState, .published)
    draft.status = .failed
    XCTAssertEqual(draft.articleState, .ready)
    draft.draft = true
    XCTAssertEqual(draft.articleState, .draft)
    draft.assignToGeneralDraft()
    XCTAssertEqual(draft.articleState, .localOnly)
  }

  func testUnboundSiteDraftDoesNotBecomeLocalOnly() {
    let draft = ArticleDraft(siteProfileID: UUID(), title: "Article")
    XCTAssertNil(draft.repositoryBinding)
    XCTAssertEqual(draft.articleState, .draft)
  }

  func testPrivateVisibilityAloneDoesNotCreatePublicationEvidence() {
    var draft = ArticleDraft(
      siteProfileID: UUID(), title: "Private", draft: false, visibility: .private, status: .ready)
    XCTAssertEqual(draft.articleState, .ready)
    draft.status = .published
    XCTAssertEqual(draft.articleState, .published)
    draft.draft = true
    XCTAssertEqual(draft.articleState, .draft)
  }

  func testStateEditsKeepPrivateVisibilityAndRepositoryPath() {
    let profile = SiteProfile.defaultProfile
    var draft = ArticleDraft(siteProfileID: profile.id, title: "Private", visibility: .private)
    let path = profile.markdownPath(for: draft)
    XCTAssertTrue(draft.setArticleState(.ready))
    XCTAssertFalse(draft.draft)
    XCTAssertEqual(draft.status, .ready)
    XCTAssertTrue(draft.isPrivate)
    XCTAssertEqual(profile.markdownPath(for: draft), path)
    XCTAssertTrue(draft.setArticleState(.draft))
    XCTAssertTrue(draft.draft)
    XCTAssertEqual(draft.status, .draft)
    XCTAssertTrue(draft.isPrivate)
    XCTAssertFalse(draft.setArticleState(.draft))
  }

  func testManualStateEditsCannotInventPublishedOrChangeOwnership() {
    var draft = ArticleDraft(siteProfileID: UUID(), title: "Article")
    let original = draft
    XCTAssertFalse(draft.setArticleState(.published))
    XCTAssertFalse(draft.setArticleState(.localOnly))
    XCTAssertEqual(draft, original)
    draft.assignToGeneralDraft()
    let general = draft
    XCTAssertFalse(draft.setArticleState(.ready))
    XCTAssertFalse(draft.setArticleState(.draft))
    XCTAssertEqual(draft, general)
  }

  func testDraftFlagAloneInvalidatesListMetadata() {
    let before = ArticleDraft(siteProfileID: UUID(), title: "Article")
    var after = before
    after.draft = false
    XCTAssertFalse(after.hasSameListMetadata(as: before))
    XCTAssertNotEqual(after.listMetadataProjection, before.listMetadataProjection)
    after.markUpdated(at: before.updatedAt.addingTimeInterval(1), replacing: before)
    XCTAssertGreaterThan(after.metadataUpdatedAt, before.metadataUpdatedAt)
  }

  func testOnlySyncFailureAndDivergenceAreProblems() {
    for state in [DraftRepositorySyncState.diverged, .failed] {
      XCTAssertTrue(state.hasSyncProblem)
    }
    for state in [
      DraftRepositorySyncState.localOnly, .projectSaved, .localChanged, .synced, .awaitingReview,
    ] {
      XCTAssertFalse(state.hasSyncProblem)
    }
  }
}

@MainActor
final class WorkbenchArticleStateTests: XCTestCase {
  func testTitleEditsPreserveExistingManualAndTimestampSlugs() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "ArticleTitleSlugPreservation")
    for slug in ["manually-chosen-url", "2026-10-11-1404"] {
      let original = ArticleDraft(
        siteProfileID: store.activeProfile.id, title: "Before", slug: slug)
      store.setDrafts([original])
      var edited = original
      edited.title = "A new article title"
      store.updateDraftFromEditor(edited)
      XCTAssertEqual(store.draft(for: original.id)?.title, edited.title)
      XCTAssertEqual(store.draft(for: original.id)?.slug, slug)
    }
  }

  func testStateCommandPersistsAndAutosavesYAMLWithoutPublishing() async throws {
    try await assertStateCommandPersistsAndAutosaves(
      style: .yaml, expectedDraftFlag: "draft: false")
  }

  func testStateCommandPersistsAndAutosavesTOMLWithoutPublishing() async throws {
    try await assertStateCommandPersistsAndAutosaves(
      style: .toml, expectedDraftFlag: "draft = false")
  }

  private func assertStateCommandPersistsAndAutosaves(
    style: FrontMatterStyle, expectedDraftFlag: String
  ) async throws {
    let root = try temporaryDirectoryURL(prefix: "ArticleStatePersistence")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
    let fileURL = root.appendingPathComponent("app-data/workbench.json")
    let store = try TestWorkbenchFactory.makeStore(fileURL: fileURL)
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = root.path
      profile.includeDraftFlagInFrontMatter = true
      profile.frontMatterStyle = style
    }
    store.createDraft()
    let draftID = try XCTUnwrap(store.selectedDraftID)
    let added = await store.writeSiteDraftToProject(draftID: draftID)
    XCTAssertTrue(added)
    let releaseRecordCount = store.releaseRecords.count
    store.setArticleState(.ready, for: draftID)
    await store.waitForPendingSiteDraftFileWrites()
    let ready = try XCTUnwrap(store.draft(for: draftID))
    XCTAssertFalse(ready.draft)
    XCTAssertEqual(ready.articleState, .ready)
    let path = try XCTUnwrap(ready.repositoryPath)
    let document = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    XCTAssertTrue(document.contains(expectedDraftFlag))
    XCTAssertEqual(store.releaseRecords.count, releaseRecordCount)
    XCTAssertTrue(store.flushPendingChanges())
    let restored = try TestWorkbenchFactory.makeStore(fileURL: fileURL)
    XCTAssertEqual(restored.draft(for: draftID)?.articleState, .ready)
    XCTAssertEqual(restored.draft(for: draftID)?.status, .ready)
    XCTAssertEqual(restored.releaseRecords.count, releaseRecordCount)
  }

  func testStateCommandEditsTheRequestedDraftAndPreservesOtherDrafts() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "ArticleStateCommand")
    let first = ArticleDraft(
      siteProfileID: store.activeProfile.id, title: "First", visibility: .private)
    let second = ArticleDraft(siteProfileID: store.activeProfile.id, title: "Second")
    store.setDrafts([first, second])
    store.selectDraft(second.id)
    store.setArticleState(.ready, for: first.id)
    let updated = try XCTUnwrap(store.draft(for: first.id))
    XCTAssertEqual(updated.articleState, .ready)
    XCTAssertTrue(updated.isPrivate)
    XCTAssertEqual(store.draft(for: second.id), second)
    XCTAssertEqual(store.selectedDraftID, second.id)
    store.setArticleState(.published, for: first.id)
    XCTAssertEqual(store.draft(for: first.id), updated)
  }
}
