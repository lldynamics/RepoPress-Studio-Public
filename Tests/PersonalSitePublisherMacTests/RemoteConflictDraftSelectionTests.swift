import XCTest
@testable import PersonalSitePublisherMac

final class RemoteConflictDraftSelectionTests: XCTestCase {
  func testRepeatedMergeDoesNotResetEditedDraft() {
    var state = RemoteConflictDraftSelection()
    state.select(path: "a.md", choice: .merge, local: "local", remote: "remote")
    state.updateMergeDraft("手工合并稿", for: "a.md")
    state.select(path: "a.md", choice: .merge, local: "local", remote: "remote")
    XCTAssertEqual(state.mergeDraft(for: "a.md"), "手工合并稿")
  }

  func testSwitchingAwayAndBackPreservesEachFileAndEmptyDraft() {
    var state = RemoteConflictDraftSelection()
    state.select(path: "a.md", choice: .merge, local: "", remote: "远端")
    state.updateMergeDraft("", for: "a.md")
    state.select(path: "a.md", choice: .useRemote, local: "local", remote: "远端")
    state.select(path: "a.md", choice: .merge, local: "local", remote: "远端")
    state.select(path: "b.md", choice: .merge, local: "另一文件", remote: "远端")
    XCTAssertEqual(state.mergeDraft(for: "a.md"), "")
    XCTAssertEqual(state.mergeDraft(for: "b.md"), "另一文件")
    XCTAssertEqual(state.choice(for: "a.md"), .merge)
  }

  func testReadOnlyChoicesDisplayTheirOwnVersionWithoutReplacingMergeDraft() {
    var state = RemoteConflictDraftSelection()
    XCTAssertEqual(state.displayedDocument(for: "a.md", local: "local", remote: "remote"), "local")
    state.select(path: "a.md", choice: .merge, local: "local", remote: "remote")
    state.updateMergeDraft("edited merge", for: "a.md")
    state.select(path: "a.md", choice: .useRemote, local: "local", remote: "remote")
    XCTAssertEqual(state.displayedDocument(for: "a.md", local: "local", remote: "remote"), "remote")
    state.updateMergeDraft("readonly update must be ignored", for: "a.md")
    state.select(path: "a.md", choice: .keepLocal, local: "local", remote: "remote")
    XCTAssertEqual(state.displayedDocument(for: "a.md", local: "local", remote: "remote"), "local")
    state.select(path: "a.md", choice: .merge, local: "local", remote: "remote")
    XCTAssertEqual(state.displayedDocument(for: "a.md", local: "local", remote: "remote"), "edited merge")
  }
}
