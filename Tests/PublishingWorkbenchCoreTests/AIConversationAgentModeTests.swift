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

  @MainActor
  func testStoreModesAreIsolatedPerConversationAndUpdateTimestamp() throws {
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "AIConversationAgentModeIsolation"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      )
    )
    let first = try XCTUnwrap(store.aiStore.startNewGeneralAIChatConversation())
    let second = try XCTUnwrap(store.aiStore.startNewGeneralAIChatConversation())
    let originalUpdatedAt = try XCTUnwrap(
      store.aiConversations.first(where: { $0.id == first.id })?.updatedAt
    )

    XCTAssertTrue(
      store.aiStore.setAIConversationAgentMode(.textOnly, for: first.id)
    )

    XCTAssertEqual(
      store.aiStore.aiConversationAgentMode(for: first.id),
      .textOnly
    )
    XCTAssertEqual(
      store.aiStore.aiConversationAgentMode(for: second.id),
      .inheritConnection
    )
    let updatedAt = try XCTUnwrap(
      store.aiConversations.first(where: { $0.id == first.id })?.updatedAt
    )
    XCTAssertGreaterThanOrEqual(updatedAt, originalUpdatedAt)
  }

  @MainActor
  func testStoreRejectsMissingAndArchivedConversations() throws {
    let directory = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "AIConversationAgentModeFailClosed"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")
      )
    )
    let conversation = try XCTUnwrap(
      store.aiStore.startNewGeneralAIChatConversation()
    )

    XCTAssertTrue(store.aiStore.archiveAIChatConversation(conversation.id))
    XCTAssertNil(store.aiStore.aiConversationAgentMode(for: conversation.id))
    XCTAssertFalse(
      store.aiStore.setAIConversationAgentMode(.textOnly, for: conversation.id)
    )
    XCTAssertEqual(
      store.aiConversations.first(where: { $0.id == conversation.id })?.agentMode,
      .inheritConnection
    )

    let missingID = UUID()
    XCTAssertNil(store.aiStore.aiConversationAgentMode(for: missingID))
    XCTAssertFalse(
      store.aiStore.setAIConversationAgentMode(.textOnly, for: missingID)
    )
  }
}
