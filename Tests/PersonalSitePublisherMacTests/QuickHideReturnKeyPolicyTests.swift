import AppKit
@testable import PersonalSitePublisherMac
import XCTest

final class QuickHideReturnKeyPolicyTests: XCTestCase {
  func testMatchesMainAndNumericReturnWithoutBlockingModifiers() {
    XCTAssertTrue(
      QuickHideReturnKeyPolicy.matches(
        keyCode: 36,
        modifierFlags: []
      )
    )
    XCTAssertTrue(
      QuickHideReturnKeyPolicy.matches(
        keyCode: 76,
        modifierFlags: .numericPad
      )
    )
  }

  func testRejectsModifiedReturnAndUnrelatedKeys() {
    for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
      XCTAssertFalse(
        QuickHideReturnKeyPolicy.matches(
          keyCode: 36,
          modifierFlags: modifier
        )
      )
    }
    XCTAssertFalse(
      QuickHideReturnKeyPolicy.matches(
        keyCode: 37,
        modifierFlags: []
      )
    )
  }
}
