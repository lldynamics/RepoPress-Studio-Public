import XCTest

@testable import PersonalSitePublisherMac

final class MainWindowClosePolicyTests: XCTestCase {
  func testCleanWindowClosesWithoutInvokingSave() {
    var didSave = false

    let decision = MainWindowClosePolicy.decide(
      hasUnsavedChanges: false,
      isSaving: false,
      choice: nil,
      save: {
        didSave = true
        return true
      }
    )

    XCTAssertEqual(decision, .close)
    XCTAssertFalse(didSave)
  }

  func testWindowCannotCloseWhileSaveIsAlreadyRunning() {
    var didSave = false

    let decision = MainWindowClosePolicy.decide(
      hasUnsavedChanges: true,
      isSaving: true,
      choice: .discardAndClose,
      save: {
        didSave = true
        return true
      }
    )

    XCTAssertEqual(decision, .keepEditing)
    XCTAssertFalse(didSave)
  }

  func testSaveAndCloseOnlyClosesAfterSuccessfulSynchronousSave() {
    XCTAssertEqual(
      MainWindowClosePolicy.decide(
        hasUnsavedChanges: true,
        isSaving: false,
        choice: .saveAndClose,
        save: { true }
      ),
      .close
    )
    XCTAssertEqual(
      MainWindowClosePolicy.decide(
        hasUnsavedChanges: true,
        isSaving: false,
        choice: .saveAndClose,
        save: { false }
      ),
      .saveFailed
    )
  }

  func testContinueDismissAndDiscardChoicesRemainDistinct() {
    for choice in [MainWindowUnsavedCloseChoice.continueEditing, nil] {
      XCTAssertEqual(
        MainWindowClosePolicy.decide(
          hasUnsavedChanges: true,
          isSaving: false,
          choice: choice,
          save: {
            XCTFail("Save must not run")
            return false
          }
        ),
        .keepEditing
      )
    }

    XCTAssertEqual(
      MainWindowClosePolicy.decide(
        hasUnsavedChanges: true,
        isSaving: false,
        choice: .discardAndClose,
        save: {
          XCTFail("Save must not run")
          return false
        }
      ),
      .close
    )
  }
}
