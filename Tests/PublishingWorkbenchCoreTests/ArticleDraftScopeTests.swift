import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class ArticleDraftScopeTests: XCTestCase {
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
}

@MainActor
final class WorkbenchDraftScopeTests: XCTestCase {
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
