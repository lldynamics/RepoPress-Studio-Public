import XCTest
@testable import PublishingWorkbenchCore

final class AIConversationScopeMigrationTests: XCTestCase {
  func testLegacyDraftConversationDecodesIntoExplicitDraftScope() throws {
    let draftID = UUID()
    let conversation = AIConversation(draftID: draftID, title: "旧对话")
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder.workbench.encode(conversation)
      ) as? [String: Any]
    )
    object.removeValue(forKey: "scope")

    let decoded = try JSONDecoder.workbench.decode(
      AIConversation.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertEqual(decoded.scope, .draft(draftID))
    XCTAssertEqual(decoded.draftID, draftID)
    XCTAssertEqual(decoded.contextMode, .site)
  }

  func testOwnerlessConversationDoesNotBecomeGeneral() throws {
    let conversation = AIConversation(draftID: UUID(), title: "待迁移")
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder.workbench.encode(conversation)
      ) as? [String: Any]
    )
    object.removeValue(forKey: "scope")
    object.removeValue(forKey: "draftID")

    XCTAssertThrowsError(
      try JSONDecoder.workbench.decode(
        AIConversation.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    )
  }

  @MainActor
  func testV11LegacyDraftSnapshotMigratesToV12AndReloadsWithDraftScope() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIConversationV11Migration-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("workbench.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft.empty(profile: profile)
    let conversation = AIConversation(draftID: draft.id, title: "旧文章会话")
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draft],
      releaseRecords: [],
      aiConversations: [conversation],
      activeAIConversationIDsByDraftID: [draft.id: conversation.id]
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder.workbench.encode(snapshot)
      ) as? [String: Any]
    )
    object["formatVersion"] = 11
    var legacyConversation = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder.workbench.encode(conversation)
      ) as? [String: Any]
    )
    legacyConversation.removeValue(forKey: "scope")
    object["aiConversations"] = [legacyConversation]
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try JSONSerialization.data(withJSONObject: object).write(to: fileURL, options: .atomic)

    let persistence = WorkbenchPersistence(fileURL: fileURL)
    let loaded = try XCTUnwrap(persistence.load())
    XCTAssertEqual(loaded.formatVersion, WorkbenchSnapshot.currentFormatVersion)
    XCTAssertEqual(loaded.aiConversations.first?.scope, .draft(draft.id))

    XCTAssertEqual(try persistence.save(loaded), .saved)
    let reloaded = try XCTUnwrap(persistence.load())
    XCTAssertEqual(reloaded.formatVersion, WorkbenchSnapshot.currentFormatVersion)
    XCTAssertEqual(reloaded.aiConversations.first?.scope, .draft(draft.id))
    XCTAssertFalse(reloaded.aiConversations.contains { $0.scope == .general })
  }

  func testGeneralConversationPersistsConnectionBindingWithoutArticleBinding() throws {
    let connectionID = UUID()
    let conversation = AIConversation(
      scope: .general,
      connectionProfileID: connectionID,
      title: "通用问题"
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder.workbench.encode(conversation)
      ) as? [String: Any]
    )

    XCTAssertNotNil(object["scope"])
    XCTAssertNotNil(object["connectionProfileID"])
    XCTAssertNil(object["draftID"])
  }

  func testGeneralScopeNormalizesLegacySiteContextMode() throws {
    let conversation = AIConversation(
      scope: .general,
      title: "通用会话",
      contextMode: .site
    )
    let decoded = try JSONDecoder.workbench.decode(
      AIConversation.self,
      from: JSONEncoder.workbench.encode(conversation)
    )

    XCTAssertEqual(decoded.scope, .general)
    XCTAssertEqual(decoded.contextMode, .general)
  }
}
