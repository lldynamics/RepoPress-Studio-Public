import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIPublishingChatMessageCompositionServiceTests: XCTestCase {
  func testMessageDisplayContentIncludesImageAttachmentNames() {
    let message = AIPublishingChatMessage(
      role: .user,
      content: "帮我看图。",
      imageAttachments: [
        AIChatImageAttachment(
          filename: "cover.png", mimeType: "image/png", data: Data("cover".utf8)),
        AIChatImageAttachment(
          filename: "inline.jpg", mimeType: "image/jpeg", data: Data("inline".utf8)),
      ]
    )

    let displayContent = AIPublishingChatMessageCompositionService.displayContent(for: message)

    XCTAssertEqual(displayContent, "帮我看图。\n\n已附加图片：cover.png, inline.jpg")
  }

  func testMessageDisplayContentUsesAttachmentLineForImageOnlyMessage() {
    let message = AIPublishingChatMessage(
      role: .user,
      content: " \n ",
      imageAttachments: [
        AIChatImageAttachment(
          filename: "diagram.png", mimeType: "image/png", data: Data("image".utf8))
      ]
    )

    let displayContent = AIPublishingChatMessageCompositionService.displayContent(for: message)

    XCTAssertEqual(displayContent, "已附加图片：diagram.png")
  }

}
