import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

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

}
