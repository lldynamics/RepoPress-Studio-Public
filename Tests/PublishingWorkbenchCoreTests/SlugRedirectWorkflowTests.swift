import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class SlugRedirectWorkflowTests: XCTestCase {
  func testReviewedReferenceUpdateRejectsNewReferencesWithoutWriting() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    store.updateActiveProfile { $0.markdownPathPattern = "content/posts/{slug}.md" }
    let target = ArticleDraft(
      siteProfileID: store.activeProfileID, title: "Target",
      slug: "new-route", pendingSlugRedirectPaths: ["/old-route/"])
    var source = ArticleDraft(
      siteProfileID: store.activeProfileID, title: "Source",
      slug: "source", bodyMarkdown: "[first](/old-route/)")
    store.setDrafts([target, source])
    let review = try XCTUnwrap(store.slugChangeImpact(for: target.id))
    source.bodyMarkdown += "\n[added after review](/old-route/)"
    store.updateDraft(source)
    let priorVersionCount = store.versions(for: source.id).count

    let result = store.updateReferencesForPendingSlugChange(
      draftID: target.id,
      expectedImpact: review, expectedTargetSlug: target.slug)

    XCTAssertFalse(result.wasApplied)
    XCTAssertEqual(store.draft(for: source.id)?.bodyMarkdown, source.bodyMarkdown)
    XCTAssertEqual(store.draft(for: target.id)?.pendingSlugRedirectPaths, ["/old-route/"])
    XCTAssertEqual(store.versions(for: source.id).count, priorVersionCount)
  }

  func testReviewedReferenceUpdateRejectsChangedWikiTargetSlug() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    store.updateActiveProfile { $0.markdownPathPattern = "content/posts/{slug}.md" }
    let target = ArticleDraft(
      siteProfileID: store.activeProfileID, title: "Target",
      slug: "new-route", pendingSlugRedirectPaths: ["/old-route/"])
    let source = ArticleDraft(
      siteProfileID: store.activeProfileID, title: "Source",
      slug: "source", bodyMarkdown: "[[old-route]]")
    store.setDrafts([target, source])
    let review = try XCTUnwrap(store.slugChangeImpact(for: target.id))

    let result = store.updateReferencesForPendingSlugChange(
      draftID: target.id,
      expectedImpact: review, expectedTargetSlug: "different-reviewed-slug")

    XCTAssertFalse(result.wasApplied)
    XCTAssertEqual(store.draft(for: source.id)?.bodyMarkdown, source.bodyMarkdown)
  }

  func testOneClickReferenceUpdateUsesTokenRangesAndClearsPendingRoute() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    store.updateActiveProfile { profile in
      profile.markdownPathPattern = "content/posts/{slug}.md"
    }
    let target = ArticleDraft(
      siteProfileID: store.activeProfile.id,
      title: "Target",
      slug: "old-route"
    )
    let source = ArticleDraft(
      siteProfileID: store.activeProfile.id,
      title: "Source",
      slug: "source",
      bodyMarkdown: """
      [old](/old-route/#details) and [[old-route#part|legacy]]
      <a href="/old-route/?ref=legacy#top">HTML legacy</a>
      """
    )
    store.setDrafts([target, source])
    var renamed = try XCTUnwrap(store.draft(for: target.id))
    renamed.slug = "new-route"
    XCTAssertTrue(store.updateDraftFromEditor(renamed))

    let impact = try XCTUnwrap(store.slugChangeImpact(for: target.id))
    XCTAssertEqual(impact.affectedDraftCount, 1)
    XCTAssertEqual(impact.referenceCount, 3)

    let result = store.updateReferencesForPendingSlugChange(
      draftID: target.id,
      expectedImpact: impact, expectedTargetSlug: renamed.slug)

    XCTAssertTrue(result.wasApplied)
    XCTAssertEqual(
      store.draft(for: source.id)?.bodyMarkdown,
      """
      [old](/new-route/#details) and [[new-route#part|legacy]]
      <a href="/new-route/?ref=legacy#top">HTML legacy</a>
      """
    )
    XCTAssertEqual(store.draft(for: target.id)?.pendingSlugRedirectPaths, [])
    XCTAssertFalse(store.versions(for: source.id).isEmpty)
  }

  func testAliasResolutionWritesFrontMatterMetadataWithoutChangingReferences() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    store.updateActiveProfile { profile in
      profile.markdownPathPattern = "content/posts/{slug}.md"
    }
    let target = ArticleDraft(
      siteProfileID: store.activeProfile.id,
      title: "Target",
      slug: "old-route"
    )
    let source = ArticleDraft(
      siteProfileID: store.activeProfile.id,
      title: "Source",
      slug: "source",
      bodyMarkdown: "[old](/old-route/)"
    )
    store.setDrafts([target, source])
    var renamed = try XCTUnwrap(store.draft(for: target.id))
    renamed.slug = "new-route"
    XCTAssertTrue(store.updateDraftFromEditor(renamed))

    let result = store.addAliasesForPendingSlugChange(draftID: target.id)

    XCTAssertTrue(result.wasApplied)
    XCTAssertEqual(store.draft(for: target.id)?.aliases, ["/old-route/"])
    XCTAssertEqual(store.draft(for: target.id)?.pendingSlugRedirectPaths, [])
    XCTAssertEqual(store.draft(for: source.id)?.bodyMarkdown, "[old](/old-route/)")
  }

  func testEditorSlugChangeRecordsPreviousRouteForLaterResolution() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL())
    )
    store.updateActiveProfile { profile in
      profile.markdownPathPattern = "content/posts/{slug}.md"
    }
    let draft = ArticleDraft(
      siteProfileID: store.activeProfile.id,
      title: "Route",
      slug: "old-route"
    )
    store.setDrafts([draft])

    var edited = try XCTUnwrap(store.draft(for: draft.id))
    edited.slug = "new-route"
    XCTAssertTrue(store.updateDraftFromEditor(edited))

    let current = try XCTUnwrap(store.draft(for: draft.id))
    XCTAssertEqual(current.slug, "new-route")
    XCTAssertEqual(current.pendingSlugRedirectPaths, ["/old-route/"])
  }

  func testPendingRoutesRoundTripAndVersionRestoreIncludesRedirectMetadata() throws {
    var draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Route",
      slug: "new-route",
      aliases: ["/published-old-route/"],
      pendingSlugRedirectPaths: ["/old-route/"],
      permalink: "/canonical-route/"
    )
    draft.recordPendingSlugRedirectPath("old-route?source=legacy#top")
    XCTAssertEqual(draft.pendingSlugRedirectPaths, ["/old-route/"])

    let decoded = try JSONDecoder().decode(
      ArticleDraft.self,
      from: JSONEncoder().encode(draft)
    )
    XCTAssertEqual(decoded.pendingSlugRedirectPaths, draft.pendingSlugRedirectPaths)

    var changed = draft
    changed.aliases = []
    changed.pendingSlugRedirectPaths = []
    changed.permalink = nil
    let restored = DraftVersionComparisonService().restoringContent(
      from: draft,
      into: changed
    )
    XCTAssertEqual(restored.aliases, draft.aliases)
    XCTAssertEqual(restored.pendingSlugRedirectPaths, draft.pendingSlugRedirectPaths)
    XCTAssertEqual(restored.permalink, draft.permalink)
  }
}
