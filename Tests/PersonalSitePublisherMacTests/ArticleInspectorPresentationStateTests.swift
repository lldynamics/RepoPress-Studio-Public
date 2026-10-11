import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class ArticleInspectorPresentationStateTests: XCTestCase {
  func testSelectionSurvivesAssistantSurfaceSwapForSameArticleAndSection() {
    let state = ArticleInspectorPresentationState()
    let draftID = UUID()

    state.select(.seo, for: draftID, section: .writing)

    XCTAssertEqual(
      state.selectedTab(for: draftID, section: .writing, defaultTab: .knowledge),
      .seo
    )
  }

  func testSelectionIsIndependentByArticleAndWorkspaceSection() {
    let state = ArticleInspectorPresentationState()
    let firstDraftID = UUID()
    let secondDraftID = UUID()

    state.select(.seo, for: firstDraftID, section: .writing)
    state.select(.images, for: firstDraftID, section: .images)

    XCTAssertEqual(
      state.selectedTab(for: firstDraftID, section: .writing, defaultTab: .knowledge),
      .seo
    )
    XCTAssertEqual(
      state.selectedTab(for: firstDraftID, section: .images, defaultTab: .images),
      .images
    )
    XCTAssertEqual(
      state.selectedTab(for: secondDraftID, section: .writing, defaultTab: .knowledge),
      .knowledge
    )
  }

  func testInformationDefaultsExpandOnlyMetadata() {
    let state = ArticleInspectorPresentationState()
    let draftID = UUID()

    XCTAssertTrue(state.isExpanded(.metadata, for: draftID, section: .writing))
    for group in [ArticleInspectorTab.seo, .images, .knowledge] {
      XCTAssertFalse(state.isExpanded(group, for: draftID, section: .writing))
    }
  }

  func testSEOSocialPreviewNavigationReopensTheGroupAndSelectsItForScreenshotCapture() {
    let state = ArticleInspectorPresentationState()
    let draftID = UUID()
    state.select(.seo, for: draftID, section: .writing)
    state.setExpanded(false, group: .seo, for: draftID, section: .writing)

    XCTAssertTrue(state.revealSEOSocialPreview(for: draftID, section: .writing))
    XCTAssertFalse(state.isExpanded(.metadata, for: draftID, section: .writing))
    XCTAssertTrue(state.isExpanded(.metadata, for: UUID(), section: .writing))
    XCTAssertTrue(state.isExpanded(.seo, for: draftID, section: .writing))
    XCTAssertEqual(
      state.selectedTab(for: draftID, section: .writing, defaultTab: .metadata), .seo)
    XCTAssertFalse(state.isExpanded(.seo, for: UUID(), section: .writing))
    XCTAssertFalse(state.revealSEOSocialPreview(for: draftID, section: .images))
    XCTAssertEqual(
      state.selectedTab(for: draftID, section: .images, defaultTab: .images), .images)
  }

  func testAdvancedMetadataDefaultsCollapsedAndStaysLocalToArticleSectionAndWindow() {
    let state = ArticleInspectorPresentationState()
    let otherWindow = ArticleInspectorPresentationState()
    let draftID = UUID()
    let advanced = state.advancedMetadataBinding(for: draftID, section: .writing)
    XCTAssertFalse(advanced.wrappedValue)
    advanced.wrappedValue = true
    XCTAssertTrue(state.advancedMetadataBinding(for: draftID, section: .writing).wrappedValue)
    XCTAssertFalse(state.advancedMetadataBinding(for: UUID(), section: .writing).wrappedValue)
    XCTAssertFalse(state.advancedMetadataBinding(for: draftID, section: .images).wrappedValue)
    XCTAssertFalse(
      otherWindow.advancedMetadataBinding(for: draftID, section: .writing).wrappedValue)
  }

  func testSlugRepairReopensBothCollapsedGroupsWhileCommonFieldsKeepAdvancedQuiet() {
    let state = ArticleInspectorPresentationState()
    let draftID = UUID()
    state.setExpanded(false, group: .metadata, for: draftID, section: .writing)
    state.revealMetadataField("summary", for: draftID, section: .writing)
    XCTAssertTrue(state.isExpanded(.metadata, for: draftID, section: .writing))
    let advanced = state.advancedMetadataBinding(for: draftID, section: .writing)
    XCTAssertFalse(advanced.wrappedValue)

    state.setExpanded(false, group: .metadata, for: draftID, section: .writing)
    state.revealMetadataField("slug", for: draftID, section: .writing)
    XCTAssertTrue(state.isExpanded(.metadata, for: draftID, section: .writing))
    XCTAssertTrue(advanced.wrappedValue)
    advanced.wrappedValue = false
    state.revealMetadataField("slug", for: draftID, section: .writing)
    XCTAssertTrue(advanced.wrappedValue)
  }

  func testExpansionSurvivesRebindingWithoutReopeningCollapsedSelection() {
    let state = ArticleInspectorPresentationState()
    let draftID = UUID()
    state.select(.seo, for: draftID, section: .writing)
    state.setExpanded(false, group: .seo, for: draftID, section: .writing)
    state.setExpanded(false, group: .metadata, for: draftID, section: .writing)

    let selection = state.binding(for: draftID, section: .writing, defaultTab: .metadata)
    let expansion = state.expansionBinding(for: .seo, draftID: draftID, section: .writing)

    XCTAssertEqual(selection.wrappedValue, .seo)
    XCTAssertFalse(expansion.wrappedValue)
    XCTAssertFalse(state.isExpanded(.metadata, for: draftID, section: .writing))
  }

  func testRepeatedNavigationReopensCollapsedSelectedGroup() {
    let state = ArticleInspectorPresentationState()
    let draftID = UUID()
    let selection = state.binding(for: draftID, section: .writing, defaultTab: .metadata)
    selection.wrappedValue = .images
    state.setExpanded(false, group: .images, for: draftID, section: .writing)

    selection.wrappedValue = .images

    XCTAssertEqual(selection.wrappedValue, .images)
    XCTAssertTrue(state.isExpanded(.images, for: draftID, section: .writing))
  }

  func testExpansionIsIndependentByArticleSectionAndWindow() {
    let firstWindow = ArticleInspectorPresentationState()
    let secondWindow = ArticleInspectorPresentationState()
    let firstDraftID = UUID()
    let secondDraftID = UUID()
    firstWindow.setExpanded(true, group: .knowledge, for: firstDraftID, section: .writing)
    firstWindow.setExpanded(false, group: .metadata, for: firstDraftID, section: .writing)

    XCTAssertFalse(firstWindow.isExpanded(.knowledge, for: secondDraftID, section: .writing))
    XCTAssertFalse(firstWindow.isExpanded(.knowledge, for: firstDraftID, section: .images))
    XCTAssertFalse(secondWindow.isExpanded(.knowledge, for: firstDraftID, section: .writing))
    XCTAssertTrue(firstWindow.isExpanded(.metadata, for: secondDraftID, section: .writing))
    XCTAssertTrue(secondWindow.isExpanded(.metadata, for: firstDraftID, section: .writing))
  }

  func testManualExpansionKeepsOtherGroupsAndNavigationSelection() {
    let state = ArticleInspectorPresentationState()
    let draftID = UUID()
    state.select(.seo, for: draftID, section: .writing)

    state.expansionBinding(for: .knowledge, draftID: draftID, section: .writing).wrappedValue = true

    XCTAssertTrue(state.isExpanded(.knowledge, for: draftID, section: .writing))
    XCTAssertTrue(state.isExpanded(.seo, for: draftID, section: .writing))
    XCTAssertTrue(state.isExpanded(.metadata, for: draftID, section: .writing))
    XCTAssertEqual(state.selectedTab(for: draftID, section: .writing, defaultTab: .metadata), .seo)
  }

  func testImageAndCheckSelectionDoesNotChangeWritingExpansion() {
    let state = ArticleInspectorPresentationState()
    let draftID = UUID()
    state.select(.images, for: draftID, section: .images)
    state.select(.checks, for: draftID, section: .contentHealth)

    XCTAssertFalse(state.isExpanded(.images, for: draftID, section: .writing))
    XCTAssertEqual(
      state.selectedTab(for: draftID, section: .images, defaultTab: .metadata), .images)
    XCTAssertEqual(
      state.selectedTab(for: draftID, section: .contentHealth, defaultTab: .metadata), .checks)
  }
}
