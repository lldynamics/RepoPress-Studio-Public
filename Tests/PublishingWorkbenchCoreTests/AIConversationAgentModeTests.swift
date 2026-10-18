import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIConversationAgentModeTests: XCTestCase {
  func testRetiredAgentModeIsIgnoredAndDroppedOnSave() throws {
    let conversation = AIConversation(scope: .general, title: "旧快照")
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder.workbench.encode(conversation)
      ) as? [String: Any]
    )
    object["agentMode"] = "textOnly"

    let decoded = try JSONDecoder.workbench.decode(
      AIConversation.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
    let savedAgain = try JSONEncoder.workbench.encode(decoded)

    XCTAssertEqual(decoded.title, "旧快照")
    XCTAssertFalse(String(decoding: savedAgain, as: UTF8.self).contains("agentMode"))
  }
}
