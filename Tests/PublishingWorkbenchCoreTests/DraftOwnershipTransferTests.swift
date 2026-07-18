import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class DraftOwnershipTransferTests: XCTestCase {
  func testSiteArticleCanMoveToGeneralAndUndoRestoresOwnership() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftTransferGeneral")
    var source = try XCTUnwrap(store.selectedDraft)
    source.repositoryPath = store.activeProfile.markdownPath(for: source)
    source.repositorySHA = "source-sha"
    store.updateDraft(source)

    let plan = store.draftOwnershipTransferPlan(
      draftIDs: [source.id],
      operation: .moveToGeneral
    )

    XCTAssertTrue(plan.canApply)
    XCTAssertNotNil(plan.items.first?.sourcePermalink)
    XCTAssertNil(plan.items.first?.targetPermalink)

    let result = try XCTUnwrap(store.applyDraftOwnershipTransfer(plan))
    let general = try XCTUnwrap(store.drafts.first(where: { $0.id == source.id }))
    XCTAssertTrue(general.isGeneralDraft)
    XCTAssertNil(general.repositoryPath)
    XCTAssertNil(general.repositorySHA)
    XCTAssertEqual(store.draftListContentScope, .general)

    XCTAssertTrue(store.undoLatestDraftOwnershipTransfer(expectedUndoID: result.undoID))
    let restored = try XCTUnwrap(store.drafts.first(where: { $0.id == source.id }))
    XCTAssertTrue(restored.belongs(toSiteProfileID: source.siteProfileID))
    XCTAssertEqual(restored.repositoryPath, source.repositoryPath)
    XCTAssertEqual(restored.repositorySHA, "source-sha")
  }

  func testGeneralDraftMovesToTargetSiteWithoutChangingIdentity() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftTransferToSite")
    let target = store.createProfile(named: "目标站点")
    store.createGeneralDraft()
    let source = try XCTUnwrap(store.selectedDraft)

    let plan = store.draftOwnershipTransferPlan(
      draftIDs: [source.id],
      operation: .moveToSite,
      targetProfileID: target.id
    )
    let result = try XCTUnwrap(store.applyDraftOwnershipTransfer(plan))

    XCTAssertEqual(result.affectedDraftIDs, [source.id])
    let moved = try XCTUnwrap(store.drafts.first(where: { $0.id == source.id }))
    XCTAssertTrue(moved.belongs(toSiteProfileID: target.id))
    XCTAssertFalse(moved.isGeneralDraft)
    XCTAssertEqual(store.activeProfileID, target.id)
    XCTAssertEqual(store.draftListContentScope, .currentSite)
  }

  func testCopyToSiteKeepsSourceAndUndoRemovesOnlyTheCopy() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftTransferCopy")
    let sourceProfileID = store.activeProfileID
    let source = try XCTUnwrap(store.selectedDraft)
    let target = store.createProfile(named: "目标站点")

    let plan = store.draftOwnershipTransferPlan(
      draftIDs: [source.id],
      operation: .copyToSite,
      targetProfileID: target.id
    )
    let result = try XCTUnwrap(store.applyDraftOwnershipTransfer(plan))
    let copiedID = try XCTUnwrap(result.affectedDraftIDs.first)

    XCTAssertNotEqual(copiedID, source.id)
    XCTAssertTrue(store.drafts.contains(where: {
      $0.id == source.id && $0.belongs(toSiteProfileID: sourceProfileID)
    }))
    XCTAssertTrue(store.drafts.contains(where: {
      $0.id == copiedID && $0.belongs(toSiteProfileID: target.id)
    }))

    XCTAssertTrue(store.undoLatestDraftOwnershipTransfer(expectedUndoID: result.undoID))
    XCTAssertTrue(store.drafts.contains(where: { $0.id == source.id }))
    XCTAssertFalse(store.drafts.contains(where: { $0.id == copiedID }))
  }

  func testOccupiedTargetPathBlocksTransfer() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftTransferOccupied")
    var source = try XCTUnwrap(store.selectedDraft)
    source.slug = "same-path"
    source.date = Date(timeIntervalSince1970: 1_700_000_000)
    store.updateDraft(source)

    let target = store.createProfile(named: "目标站点")
    store.createDraft()
    var occupied = try XCTUnwrap(store.selectedDraft)
    occupied.slug = source.slug.uppercased()
    occupied.date = source.date
    store.updateDraft(occupied)

    let plan = store.draftOwnershipTransferPlan(
      draftIDs: [source.id],
      operation: .moveToSite,
      targetProfileID: target.id
    )

    XCTAssertFalse(plan.canApply)
    XCTAssertEqual(plan.conflicts.map(\.kind), [.targetPathOccupied])
    XCTAssertNil(store.applyDraftOwnershipTransfer(plan))
    XCTAssertTrue(store.drafts.contains(where: {
      $0.id == source.id && $0.belongs(toSiteProfileID: source.siteProfileID)
    }))
  }

  func testBatchDuplicateTargetPathsAreDetectedBeforeMove() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftTransferBatchConflict")
    var first = try XCTUnwrap(store.selectedDraft)
    first.slug = "duplicate"
    first.date = Date(timeIntervalSince1970: 1_700_000_000)
    store.updateDraft(first)
    store.createDraft()
    var second = try XCTUnwrap(store.selectedDraft)
    second.slug = first.slug
    second.date = first.date
    store.updateDraft(second)
    let target = store.createProfile(named: "目标站点")

    let plan = store.draftOwnershipTransferPlan(
      draftIDs: [first.id, second.id],
      operation: .moveToSite,
      targetProfileID: target.id
    )

    XCTAssertFalse(plan.canApply)
    XCTAssertEqual(plan.conflicts.filter { $0.kind == .duplicateTargetPath }.count, 2)
  }

  func testBatchMoveCanBeUndoneWhenMovedDraftsWereNotEdited() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftTransferBatchUndo")
    let sourceProfileID = store.activeProfileID
    let first = try XCTUnwrap(store.selectedDraft)
    store.createDraft()
    var second = try XCTUnwrap(store.selectedDraft)
    second.slug = "second-draft"
    store.updateDraft(second)
    let target = store.createProfile(named: "目标站点")

    let plan = store.draftOwnershipTransferPlan(
      draftIDs: [first.id, second.id],
      operation: .moveToSite,
      targetProfileID: target.id
    )
    let result = try XCTUnwrap(store.applyDraftOwnershipTransfer(plan))

    XCTAssertEqual(result.affectedDraftIDs.count, 2)
    XCTAssertTrue(result.affectedDraftIDs.allSatisfy { id in
      store.drafts.first(where: { $0.id == id })?.belongs(toSiteProfileID: target.id) == true
    })

    XCTAssertTrue(store.undoLatestDraftOwnershipTransfer(expectedUndoID: result.undoID))
    XCTAssertTrue([first.id, second.id].allSatisfy { id in
      store.drafts.first(where: { $0.id == id })?.belongs(toSiteProfileID: sourceProfileID) == true
    })
  }

  func testUndoStopsRatherThanOverwritingEditsMadeAfterTransfer() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftTransferSafeUndo")
    let source = try XCTUnwrap(store.selectedDraft)
    let plan = store.draftOwnershipTransferPlan(
      draftIDs: [source.id],
      operation: .moveToGeneral
    )
    let result = try XCTUnwrap(store.applyDraftOwnershipTransfer(plan))
    var moved = try XCTUnwrap(store.selectedDraft)
    moved.title = "归属变更后的新编辑"
    store.updateDraft(moved)

    XCTAssertFalse(store.undoLatestDraftOwnershipTransfer(expectedUndoID: result.undoID))
    XCTAssertEqual(store.drafts.first(where: { $0.id == source.id })?.title, "归属变更后的新编辑")
  }
}
