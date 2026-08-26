import Foundation
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownSelectionBubblePresentationStateTests: XCTestCase {
  func testSelectionStartsHiddenUntilMatchingSelectionIsRevealed() {
    var state = MarkdownSelectionBubblePresentationState()
    let selection = NSRange(location: 4, length: 6)

    state.selectionDidChange(to: selection)

    XCTAssertFalse(state.shouldRender(for: selection))
    XCTAssertTrue(state.revealIfCurrentSelection(selection))
    XCTAssertTrue(state.shouldRender(for: selection))
  }

  func testChangingSelectionInvalidatesPreviousReveal() {
    var state = MarkdownSelectionBubblePresentationState()
    let firstSelection = NSRange(location: 4, length: 6)
    let secondSelection = NSRange(location: 20, length: 3)

    state.selectionDidChange(to: firstSelection)
    XCTAssertTrue(state.revealIfCurrentSelection(firstSelection))
    state.selectionDidChange(to: secondSelection)

    XCTAssertFalse(state.shouldRender(for: secondSelection))
    XCTAssertFalse(state.revealIfCurrentSelection(firstSelection))
    XCTAssertTrue(state.revealIfCurrentSelection(secondSelection))
  }

  func testSelectionGenerationRejectsStaleTaskAfterReturningToSameRange() {
    var state = MarkdownSelectionBubblePresentationState()
    let firstSelection = NSRange(location: 4, length: 6)
    let secondSelection = NSRange(location: 20, length: 3)

    let firstGeneration = state.selectionDidChange(to: firstSelection)
    _ = state.selectionDidChange(to: secondSelection)
    let latestGeneration = state.selectionDidChange(to: firstSelection)

    XCTAssertNotEqual(firstGeneration, latestGeneration)
    XCTAssertFalse(
      state.revealIfCurrentSelection(firstSelection, generation: firstGeneration)
    )
    XCTAssertTrue(
      state.revealIfCurrentSelection(firstSelection, generation: latestGeneration)
    )
  }

  func testEmptySelectionHidesImmediately() {
    var state = MarkdownSelectionBubblePresentationState()
    let selection = NSRange(location: 4, length: 6)

    state.selectionDidChange(to: selection)
    XCTAssertTrue(state.revealIfCurrentSelection(selection))
    state.selectionDidChange(to: NSRange(location: 10, length: 0))

    XCTAssertFalse(state.isVisible)
    XCTAssertFalse(state.shouldRender(for: selection))
    XCTAssertFalse(state.revealIfCurrentSelection(selection))
  }

  func testSameVisibleSelectionDoesNotResetPresentation() {
    var state = MarkdownSelectionBubblePresentationState()
    let selection = NSRange(location: 4, length: 6)

    state.selectionDidChange(to: selection)
    XCTAssertTrue(state.revealIfCurrentSelection(selection))
    state.selectionDidChange(to: selection)

    XCTAssertTrue(state.shouldRender(for: selection))
  }

  func testStaleTaskIdentityCannotRevealAnotherDraftOrSelection() {
    let draftID = UUID()
    let otherDraftID = UUID()
    let selection = NSRange(location: 4, length: 6)
    let sameSelection = MarkdownSelectionBubbleTaskID(
      draftID: draftID,
      selectedRange: selection
    )
    let sameIdentity = MarkdownSelectionBubbleTaskID(
      draftID: draftID,
      selectedRange: selection
    )
    let changedSelection = MarkdownSelectionBubbleTaskID(
      draftID: draftID,
      selectedRange: NSRange(location: 5, length: 6)
    )
    let changedDraft = MarkdownSelectionBubbleTaskID(
      draftID: otherDraftID,
      selectedRange: selection
    )

    XCTAssertEqual(sameSelection, sameIdentity)
    XCTAssertNotEqual(sameSelection, changedSelection)
    XCTAssertNotEqual(sameSelection, changedDraft)
  }

  func testPresentationDelayIsTwoHundredMilliseconds() {
    XCTAssertEqual(
      MarkdownSelectionBubblePresentationState.presentationDelay,
      .milliseconds(200)
    )
  }
}
