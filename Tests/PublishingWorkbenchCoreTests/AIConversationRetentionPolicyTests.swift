import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class AIConversationRetentionPolicyTests: XCTestCase {
  func testRetentionLimitsConversationsPerDraftAndKeepsPreferredConversation() {
    let draftID = UUID()
    let baseDate = Date(timeIntervalSince1970: 1_000)
    let conversations = (0...AIConversationRetentionPolicy.maximumConversationsPerDraft).map {
      AIConversation(
        draftID: draftID,
        title: "对话 \($0)",
        createdAt: baseDate.addingTimeInterval(TimeInterval($0)),
        updatedAt: baseDate.addingTimeInterval(TimeInterval($0))
      )
    }
    let preferredID = conversations[0].id

    let retained = AIConversationRetentionPolicy.limited(
      conversations,
      preserving: [preferredID]
    )

    XCTAssertEqual(
      retained.count,
      AIConversationRetentionPolicy.maximumConversationsPerDraft
    )
    XCTAssertTrue(retained.contains { $0.id == preferredID })
    XCTAssertFalse(retained.contains { $0.id == conversations[1].id })
  }

  func testRetentionKeepsVisibleConversationsAheadOfArchivedConversations() {
    let baseDate = Date(timeIntervalSince1970: 2_000)
    let draftIDs = (0..<4).map { _ in UUID() }
    var conversations = (0..<AIConversationRetentionPolicy.maximumConversationCount).map {
      AIConversation(
        draftID: draftIDs[$0 % draftIDs.count],
        title: "可见 \($0)",
        createdAt: baseDate.addingTimeInterval(TimeInterval($0)),
        updatedAt: baseDate.addingTimeInterval(TimeInterval($0))
      )
    }
    let archived = AIConversation(
      draftID: draftIDs[0],
      title: "已归档",
      createdAt: baseDate.addingTimeInterval(10_000),
      updatedAt: baseDate.addingTimeInterval(10_000),
      archivedAt: baseDate.addingTimeInterval(10_000)
    )
    conversations.append(archived)

    let retained = AIConversationRetentionPolicy.limited(conversations)

    XCTAssertEqual(
      retained.count,
      AIConversationRetentionPolicy.maximumConversationCount
    )
    XCTAssertFalse(retained.contains { $0.id == archived.id })
  }

  func testPreparedConversationBoundsPersistedText() {
    let oversizedContent = String(
      repeating: "a",
      count: AIConversation.maximumTextCharacters + 100
    )
    let conversation = AIConversation(
      draftID: UUID(),
      messages: [
        AIPublishingChatMessage(role: .user, content: "较早的问题"),
        AIPublishingChatMessage(role: .assistant, content: oversizedContent),
      ]
    )

    let prepared = conversation.prepared()

    XCTAssertEqual(prepared.messages.count, 1)
    XCTAssertEqual(
      prepared.messages[0].content.count,
      AIConversation.maximumTextCharacters
    )
  }

  func testStoreAppliesConversationLimitBeforeRestart() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let persistenceURL = temporaryDirectory.appendingPathComponent("workbench.json")
    defer {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let draft = try XCTUnwrap(store.selectedDraft)

    for _ in 0...AIConversationRetentionPolicy.maximumConversationsPerDraft {
      XCTAssertNotNil(store.startNewAIChatConversation(draft: draft))
    }

    XCTAssertEqual(
      store.aiChatConversations(for: draft.id).count,
      AIConversationRetentionPolicy.maximumConversationsPerDraft
    )
    XCTAssertNotNil(store.activeAIChatConversationID(for: draft.id))
  }

  func testGeneralConversationsUseExplicitScopeAndAreNotFilteredByDraftIDs() {
    let general = (0..<45).map { index in
      AIConversation(
        scope: .general,
        title: "通用 \(index)",
        createdAt: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }
    let orphanDraft = AIConversation(draftID: UUID(), title: "不存在的文章")

    let limited = AIConversationRetentionPolicy.limited(
      general + [orphanDraft],
      validDraftIDs: [],
      preserving: [general.last!.id]
    )

    XCTAssertEqual(limited.filter { $0.scope == .general }.count, 40)
    XCTAssertFalse(limited.contains { $0.id == orphanDraft.id })
    XCTAssertTrue(limited.contains { $0.id == general.last!.id })
  }

  func testActiveConversationMigrationUsesScopeKey() {
    let conversation = AIConversation(scope: .general, title: "通用")
    let result = AIConversationRetentionPolicy.validActiveConversationIDsByScope(
      ["general": conversation.id],
      conversations: [conversation]
    )

    XCTAssertEqual(result, ["general": conversation.id])
  }
}
