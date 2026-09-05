import AppKit
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class P3AppKitAcceptanceTests: XCTestCase {
  func testAppKitPasteOverrideRoutesTheGeneralPasteboardThroughSmartPaste() {
    let pasteboard = TestMarkdownPasteboardSource(
      strings: [.string: "https://example.com/article"]
    )
    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    textView.string = "Existing draft"
    textView.pasteboardProvider = { pasteboard }
    var receivedText: String?
    textView.smartPasteHandler = { _, pasteboard in
      receivedText = pasteboard.string(forType: .string)
      return true
    }

    textView.paste(nil)

    XCTAssertEqual(receivedText, "https://example.com/article")
  }

}
