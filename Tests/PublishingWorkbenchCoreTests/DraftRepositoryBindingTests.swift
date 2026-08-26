import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class DraftRepositoryBindingTests: XCTestCase {
  func testRepositoryIdentityChangeInvalidatesRemoteRevisionButKeepsProjectPath() {
    var originalProfile = SiteProfile.defaultProfile
    originalProfile.repoOwner = "owner"
    originalProfile.repoName = "site"
    originalProfile.branch = "main"
    var draft = ArticleDraft(
      siteProfileID: originalProfile.id,
      title: "Bound",
      slug: "bound",
      bodyMarkdown: "Repository-bound content",
      repositoryPath: "content/posts/bound.md",
      repositorySHA: "old-sha",
      repositoryImportFingerprint: "old-fingerprint"
    )
    draft.normalizeRepositoryBinding(for: originalProfile)

    var replacementProfile = originalProfile
    replacementProfile.branch = "preview"
    draft.normalizeRepositoryBinding(for: replacementProfile)

    XCTAssertEqual(draft.repositoryPath, "content/posts/bound.md")
    XCTAssertNil(draft.repositorySHA)
    XCTAssertNil(draft.repositoryImportFingerprint)
    XCTAssertEqual(draft.repositoryBinding?.identity?.branch, "preview")
    XCTAssertEqual(draft.repositoryBinding?.verification, .legacyUnverified)
    XCTAssertEqual(draft.repositoryBinding?.syncState, .projectSaved)
  }

  func testRenderedRepositoryDigestIgnoresInternalWorkflowStatus() {
    let profile = SiteProfile.defaultProfile
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Digest",
      slug: "digest",
      bodyMarkdown: "The rendered document stays the same."
    )
    let draftDigest = draft.renderedRepositoryContentDigest(profile: profile)

    draft.status = .published

    XCTAssertEqual(
      draft.renderedRepositoryContentDigest(profile: profile),
      draftDigest
    )
  }

  func testProjectWriteAfterEditingPreservesRemoteBaselineAndStaysLocalChanged() {
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Baseline",
      slug: "baseline",
      bodyMarkdown: "Remote baseline"
    )
    let baselineDigest = draft.renderedRepositoryContentDigest(profile: profile)
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/baseline.md",
      remoteRevision: "remote-sha",
      renderedContentDigest: baselineDigest
    )

    draft.bodyMarkdown = "Locally edited"
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: "content/posts/baseline.md",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )

    XCTAssertEqual(draft.repositoryBinding?.renderedContentDigest, baselineDigest)
    XCTAssertEqual(
      draft.repositoryBinding?.projectFileContentDigest,
      draft.renderedRepositoryContentDigest(profile: profile)
    )
    XCTAssertEqual(draft.repositorySyncState(for: profile), .localChanged)
  }

  func testProjectWriteOfRemoteBaselineRemainsSynced() {
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Unchanged",
      slug: "unchanged",
      bodyMarkdown: "Same repository bytes"
    )
    let baselineDigest = draft.renderedRepositoryContentDigest(profile: profile)
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/unchanged.md",
      remoteRevision: "remote-sha",
      renderedContentDigest: baselineDigest
    )

    draft.recordProjectFile(
      profile: profile,
      repositoryPath: "content/posts/unchanged.md",
      renderedContentDigest: baselineDigest
    )

    XCTAssertEqual(draft.repositoryBinding?.renderedContentDigest, baselineDigest)
    XCTAssertEqual(draft.repositoryBinding?.projectFileContentDigest, baselineDigest)
    XCTAssertEqual(draft.repositorySyncState(for: profile), .synced)
  }

  func testPendingReviewSurvivesSameBytesProjectWriteAndLaterEditBecomesLocalChanged() {
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Pending review",
      slug: "pending-review",
      bodyMarkdown: "Bytes submitted to the review branch."
    )
    let submittedDigest = draft.renderedRepositoryContentDigest(profile: profile)
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: "content/posts/pending-review.md",
      renderedContentDigest: submittedDigest
    )
    draft.markRepositoryAwaitingReview(profile: profile)

    draft.recordProjectFile(
      profile: profile,
      repositoryPath: "content/posts/pending-review.md",
      renderedContentDigest: submittedDigest
    )

    XCTAssertEqual(draft.repositorySyncState(for: profile), .awaitingReview)
    XCTAssertEqual(draft.repositoryBinding?.pendingReviewContentDigest, submittedDigest)

    draft.bodyMarkdown = "Edited after opening the review request."
    XCTAssertEqual(draft.repositorySyncState(for: profile), .localChanged)
  }

  func testEditorContentUpdateCannotOverwriteRepositoryState() throws {
    let store = try TestWorkbenchFactory.makeStore()
    var profile = store.activeProfile
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    store.updateActiveProfile(profile)
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Before",
      slug: "before",
      bodyMarkdown: "Before content",
      repositoryPath: "content/posts/before.md",
      repositorySHA: "old-sha"
    )
    store.setDrafts([draft])
    var editorValue = try XCTUnwrap(store.drafts.first)

    var repositoryUpdate = editorValue
    repositoryUpdate.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/before.md",
      remoteRevision: "new-sha",
      renderedContentDigest: repositoryUpdate.renderedRepositoryContentDigest(profile: profile)
    )
    store.publishingStore.drafts[0] = repositoryUpdate

    editorValue.title = "After"
    XCTAssertTrue(store.updateDraftFromEditor(editorValue))
    XCTAssertEqual(store.drafts.first?.title, "After")
    XCTAssertEqual(store.drafts.first?.repositorySHA, "new-sha")
    XCTAssertEqual(store.drafts.first?.repositoryBinding?.remoteRevision, "new-sha")
  }

  func testLegacyDraftDecodingMigratesToScopedBinding() throws {
    let profile = SiteProfile.defaultProfile
    let legacy = ArticleDraft(
      siteProfileID: profile.id,
      title: "Legacy",
      slug: "legacy",
      repositoryPath: "content/posts/legacy.md",
      repositorySHA: "legacy-sha"
    )
    let encoder = JSONEncoder()
    let data = try encoder.encode(legacy)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object.removeValue(forKey: "repositoryBinding")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    var decoded = try JSONDecoder().decode(ArticleDraft.self, from: legacyData)
    XCTAssertNil(decoded.repositoryBinding)
    decoded.normalizeRepositoryBinding(for: profile)

    XCTAssertEqual(decoded.repositoryBinding?.identity, DraftRepositoryIdentity(profile: profile))
    XCTAssertEqual(decoded.repositoryBinding?.remoteRevision, "legacy-sha")
    XCTAssertEqual(decoded.repositoryBinding?.verification, .legacyUnverified)
  }
}
