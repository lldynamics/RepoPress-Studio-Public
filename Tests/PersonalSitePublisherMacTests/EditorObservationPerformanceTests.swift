import Combine
import Foundation
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class EditorObservationPerformanceTests: XCTestCase {
  func testScrollPersistenceDoesNotPublishWholeComposerSession() {
    let state = MarkdownComposerEditorSessionState(
      editorBody: "正文",
      editorDocument: "正文",
      selectedRange: NSRange(location: 0, length: 0),
      isFindReplacePresented: false,
      findQuery: "",
      replacementText: "",
      isFindCaseSensitive: false,
      isFindWholeWord: false,
      isFindRegularExpression: false,
      findMatchSnapshot: .empty,
      editorScrollRestorationUpdate: nil,
      editorScrollProgress: 0,
      editorBodyRevision: 0
    )
    var changes = 0
    let cancellable = state.objectWillChange.sink { changes += 1 }

    state.editorScrollProgress = 0.5

    XCTAssertEqual(changes, 0)
    XCTAssertEqual(state.editorScrollProgress, 0.5)
    withExtendedLifetime(cancellable) {}
  }
}
