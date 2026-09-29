import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIConversationAgentModeTests: XCTestCase {
  func testLegacySnapshotDefaultsToInheritConnection() throws {
    let conversation = AIConversation(
      scope: .general,
      agentMode: .textOnly,
      title: "旧快照"
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder.workbench.encode(conversation)
      ) as? [String: Any]
    )
    object.removeValue(forKey: "agentMode")

    let decoded = try JSONDecoder.workbench.decode(
      AIConversation.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertEqual(decoded.agentMode, .inheritConnection)
  }

  func testAgentModeRoundTripsThroughConversationPersistence() throws {
    let conversation = AIConversation(
      scope: .draft(UUID()),
      agentMode: .textOnly,
      title: "仅问答"
    )

    let decoded = try JSONDecoder.workbench.decode(
      AIConversation.self,
      from: JSONEncoder.workbench.encode(conversation)
    )

    XCTAssertEqual(decoded.agentMode, .textOnly)
    XCTAssertEqual(decoded.id, conversation.id)
    XCTAssertEqual(decoded.scope, conversation.scope)
    XCTAssertEqual(decoded.title, conversation.title)
  }

  func testConversationModeCanOnlyNarrowConnectionAuthority() {
    XCTAssertTrue(
      AIConversationAgentMode.inheritConnection
        .effectiveAllowsTools(connectionAllowsTools: true)
    )
    XCTAssertFalse(
      AIConversationAgentMode.inheritConnection
        .effectiveAllowsTools(connectionAllowsTools: false)
    )
    XCTAssertFalse(
      AIConversationAgentMode.textOnly
        .effectiveAllowsTools(connectionAllowsTools: true)
    )
    XCTAssertFalse(
      AIConversationAgentMode.textOnly
        .effectiveAllowsTools(connectionAllowsTools: false)
    )
  }
}
