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
