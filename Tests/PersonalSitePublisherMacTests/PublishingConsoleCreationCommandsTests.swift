import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class PublishingConsoleCreationCommandsTests: XCTestCase {
  func testWritingSceneOwnsPrimaryNewCommand() {
    let target = PublishingConsoleCreationTarget(
      writingAvailable: true,
      knowledgeLibraryAvailable: true
    )

    XCTAssertEqual(target, .writing)
    XCTAssertEqual(target.primaryTitle, String(localized: "新建文章"))
    XCTAssertTrue(target.isEnabled)
  }

  func testLibrarySceneUsesNoteCreationWhenWritingIsAbsent() {
    let target = PublishingConsoleCreationTarget(
      writingAvailable: false,
      knowledgeLibraryAvailable: true
    )

    XCTAssertEqual(target, .knowledgeLibrary)
    XCTAssertEqual(target.primaryTitle, String(localized: "新建笔记"))
  }

  func testNoFocusedCreationSceneDisablesAllContextualCreation() {
    let target = PublishingConsoleCreationTarget(
      writingAvailable: false,
      knowledgeLibraryAvailable: false
    )

    XCTAssertEqual(target, .unavailable)
    XCTAssertEqual(target.primaryTitle, String(localized: "新建"))
    XCTAssertFalse(target.isEnabled)
  }

  func testPrimaryCreationRoutesOnlyToWritingClosure() {
    var writingCalls = 0
    var noteCalls = 0
    let writing = makeWritingActions { writingCalls += 1 }
    let knowledge = KnowledgeLibraryCommandActions(
      focusSearch: {}, importSources: {}, createNote: { noteCalls += 1 },
      selectPreviousDocument: {}, selectNextDocument: {}
    )

    PublishingConsoleCreationCommands.performPrimaryCreation(
      target: .writing, writing: writing, knowledgeLibrary: knowledge
    )

    XCTAssertEqual(writingCalls, 1)
    XCTAssertEqual(noteCalls, 0)
  }

  func testPrimaryCreationRoutesOnlyToKnowledgeClosure() {
    var writingCalls = 0
    var noteCalls = 0
    let writing = makeWritingActions { writingCalls += 1 }
    let knowledge = KnowledgeLibraryCommandActions(
      focusSearch: {}, importSources: {}, createNote: { noteCalls += 1 },
      selectPreviousDocument: {}, selectNextDocument: {}
    )

    PublishingConsoleCreationCommands.performPrimaryCreation(
      target: .knowledgeLibrary, writing: writing, knowledgeLibrary: knowledge
    )

    XCTAssertEqual(writingCalls, 0)
    XCTAssertEqual(noteCalls, 1)
  }

  func testUnavailablePrimaryCreationDoesNotFallbackToAnyClosure() {
    var writingCalls = 0
    var noteCalls = 0
    let writing = makeWritingActions { writingCalls += 1 }
    let knowledge = KnowledgeLibraryCommandActions(
      focusSearch: {}, importSources: {}, createNote: { noteCalls += 1 },
      selectPreviousDocument: {}, selectNextDocument: {}
    )

    PublishingConsoleCreationCommands.performPrimaryCreation(
      target: .unavailable, writing: writing, knowledgeLibrary: knowledge
    )

    XCTAssertEqual(writingCalls, 0)
    XCTAssertEqual(noteCalls, 0)
  }

  private func makeWritingActions(createDraft: @escaping () -> Void) -> WritingDraftCommandActions {
    WritingDraftCommandActions(
      createDraft: createDraft,
      focusSearch: {},
      openVersionHistory: {},
      selectPreviousDraft: {},
      selectNextDraft: {}
    )
  }
}
