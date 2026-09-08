import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class UIOptimizationResourceSelectionPolicyTests: XCTestCase {
  func testInitialScanSelectsEveryCandidate() {
    let result = AssetResourceSelectionPolicy.normalizedSelection(
      currentSelection: [],
      candidates: ["images/a.png", "images/b.png"],
      hasInitializedSelection: false
    )

    XCTAssertEqual(result.selection, ["images/a.png", "images/b.png"])
    XCTAssertTrue(result.hasInitializedSelection)
  }

  func testRescanPreservesExplicitClearAndLeavesNewCandidatesUnselected() {
    let result = AssetResourceSelectionPolicy.normalizedSelection(
      currentSelection: [],
      candidates: ["images/a.png", "images/new.png"],
      hasInitializedSelection: true
    )

    XCTAssertTrue(result.selection.isEmpty)
    XCTAssertTrue(result.hasInitializedSelection)
  }

  func testRescanDropsMissingSelectionButRetainsExistingExplicitSelection() {
    let result = AssetResourceSelectionPolicy.normalizedSelection(
      currentSelection: ["images/keep.png", "images/gone.png"],
      candidates: ["images/keep.png", "images/new.png"],
      hasInitializedSelection: true
    )

    XCTAssertEqual(result.selection, ["images/keep.png"])
  }

  func testResourceManagerNavigationAppliesOnlyToItsOwningProfile() {
    let ownerID = UUID()
    let request = AssetResourceManagerNavigationRequest(profileID: ownerID)

    XCTAssertEqual(
      ImageWorkbenchResourceNavigationPolicy.destination(
        for: request,
        activeProfileID: ownerID
      ),
      .assetResourceManager
    )
    XCTAssertNil(
      ImageWorkbenchResourceNavigationPolicy.destination(
        for: request,
        activeProfileID: UUID()
      )
    )
  }
  func testResourceNavigationIgnoresOtherWindowsAtTheSameSite() {
    let siteID = UUID()
    let windowID = UUID()
    let request = AssetResourceManagerNavigationRequest(profileID: siteID, windowID: windowID)
    XCTAssertNil(ImageWorkbenchResourceNavigationPolicy.destination(
      for: request, activeProfileID: siteID, windowID: UUID()
    ))
    XCTAssertNil(ImageWorkbenchResourceNavigationPolicy.destination(
      for: request, activeProfileID: siteID
    ))
    XCTAssertEqual(ImageWorkbenchResourceNavigationPolicy.destination(
      for: request, activeProfileID: siteID, windowID: windowID
    ), .assetResourceManager)
  }

}
