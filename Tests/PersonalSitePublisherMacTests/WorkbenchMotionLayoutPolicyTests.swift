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

  func testInspectorWidthResetControlAppearsOnlyAfterResize() {
    typealias Policy = WorkspaceInspectorWidthResetPolicy
    XCTAssertFalse(Policy.showsResetControl(measuredWidth: nil, defaultWidth: 320))
    XCTAssertFalse(Policy.showsResetControl(measuredWidth: 320, defaultWidth: nil))
    XCTAssertFalse(Policy.showsResetControl(measuredWidth: 320, defaultWidth: 320))
    XCTAssertFalse(Policy.showsResetControl(measuredWidth: 327.5, defaultWidth: 320))
    XCTAssertTrue(Policy.showsResetControl(measuredWidth: 420, defaultWidth: 320))
    XCTAssertTrue(Policy.showsResetControl(measuredWidth: 440, defaultWidth: 500))
  }

}
