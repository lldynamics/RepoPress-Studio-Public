import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class WorkbenchMotionLayoutPolicyTests: XCTestCase {
  func testInspectorWidthStateKeepsArticleTripleTogether() {
    let state = WorkspaceInspectorWidthState(isAIAssistantPresented: false)

    XCTAssertEqual(state.constraints, WorkspaceInspectorColumnWidthPolicy.article)
    XCTAssertEqual(state.preferredWidth, 320)
  }

  func testInspectorWidthStateSwitchesToCompleteAITriple() {
    let state = WorkspaceInspectorWidthState(isAIAssistantPresented: true)

    XCTAssertEqual(state.constraints, WorkspaceInspectorColumnWidthPolicy.aiCollaboration)
    XCTAssertEqual(state.preferredWidth, 500)
    XCTAssertEqual(state.constraints.minimum, 420)
    XCTAssertEqual(state.constraints.ideal, 500)
    XCTAssertEqual(state.constraints.maximum, 620)
  }

  func testReduceMotionPolicySuppressesStatusAndDrawerMotion() {
    let policy = WorkbenchMotionPolicy(reduceMotion: true)

    XCTAssertEqual(policy.style(for: .statusChange), .none)
    XCTAssertEqual(policy.style(for: .drawerPresentation), .none)
  }
}
