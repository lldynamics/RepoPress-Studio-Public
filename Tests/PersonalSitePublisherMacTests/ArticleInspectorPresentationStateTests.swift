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
}
