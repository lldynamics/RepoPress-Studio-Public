import XCTest

@testable import PersonalSitePublisherMac

final class WritingDraftFolderPresentationStateTests: XCTestCase {
  func testDisplayModeUsesStableRawValuesForAppStorage() {
    XCTAssertEqual(WritingDraftListDisplayMode.flat.rawValue, "flat")
    XCTAssertEqual(WritingDraftListDisplayMode.folders.rawValue, "folders")
    XCTAssertEqual(WritingDraftListDisplayMode(rawValue: "folders"), .folders)
  }

  func testToggleAddsAndRemovesUserExpansion() {
    var state = WritingDraftFolderExpansionState()

    state.toggle("posts")
    XCTAssertEqual(state.userExpandedFolderIDs, ["posts"])
    XCTAssertTrue(state.isExpanded("posts"))

    state.toggle("posts")
    XCTAssertTrue(state.userExpandedFolderIDs.isEmpty)
    XCTAssertFalse(state.isExpanded("posts"))
  }

  func testEffectiveExpansionIsUnionOfUserAndTransientIDs() {
    var state = WritingDraftFolderExpansionState(initiallyExpandedFolderIDs: ["user"])

    state.revealSearchResultAncestors(["search"])

    XCTAssertEqual(state.expandedFolderIDs, ["user", "search"])
    XCTAssertEqual(state.effectiveExpandedFolderIDs, ["user", "search"])
    XCTAssertEqual(state.userExpandedFolderIDs, ["user"])
    XCTAssertEqual(state.transientlyRevealedFolderIDs, ["search"])
  }

  func testReconcileDropsStaleUserAndTransientIDs() {
    var state = WritingDraftFolderExpansionState(initiallyExpandedFolderIDs: ["live", "stale"])
    state.revealSearchResultAncestors(["live-search", "stale-search"])

    state.reconcile(validFolderIDs: ["live", "live-search"])

    XCTAssertEqual(state.userExpandedFolderIDs, ["live"])
    XCTAssertEqual(state.transientlyRevealedFolderIDs, ["live-search"])
    XCTAssertEqual(state.expandedFolderIDs, ["live", "live-search"])
  }

  func testProgrammaticSelectionRevealsAllSuppliedAncestors() {
    var state = WritingDraftFolderExpansionState()

    state.revealAncestorsForSelection(["posts", "posts/2026", "posts/2026/june"])

    XCTAssertEqual(
      state.userExpandedFolderIDs,
      ["posts", "posts/2026", "posts/2026/june"]
    )
    XCTAssertEqual(state.expandedFolderIDs, state.userExpandedFolderIDs)
  }

  func testClearingSearchRevealRestoresUserExpansionChoices() {
    var state = WritingDraftFolderExpansionState(initiallyExpandedFolderIDs: ["kept"])
    state.revealSearchResultAncestors(["kept", "temporarily-open"])

    state.clearTransientReveal()

    XCTAssertEqual(state.userExpandedFolderIDs, ["kept"])
    XCTAssertEqual(state.expandedFolderIDs, ["kept"])
    XCTAssertTrue(state.transientlyRevealedFolderIDs.isEmpty)
  }

  func testRootInitializerIsDeterministicAndInMemory() {
    let roots = ["archive", "posts"]
    let first = WritingDraftFolderExpansionState(rootFolderIDs: roots)
    let second = WritingDraftFolderExpansionState(rootFolderIDs: roots)

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.userExpandedFolderIDs, Set(roots))
    XCTAssertTrue(first.transientlyRevealedFolderIDs.isEmpty)
  }

  func testSetExpandedChangesOnlyUserChoice() {
    var state = WritingDraftFolderExpansionState()
    state.revealSearchResultAncestors(["search"])

    state.setExpanded(false, for: "search")

    XCTAssertFalse(state.userExpandedFolderIDs.contains("search"))
    XCTAssertTrue(state.isExpanded("search"))
    state.setExpanded(true, for: "search")
    XCTAssertTrue(state.userExpandedFolderIDs.contains("search"))
  }
}
