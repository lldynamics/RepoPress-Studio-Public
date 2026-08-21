import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class KnowledgeRemoteAIContextAuthorizationTests: XCTestCase {
  func testAutomaticContextBindsTheExactChunkAndValidates() async throws {
    let rootURL = try temporaryDirectory(prefix: "knowledge-binding-context")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    _ = try await commit(
      title: "绑定资料",
      text: "蓝鲸航线的授权片段必须精确绑定到当前分片。",
      allowsRemoteAIUse: true,
      library: library
    )

    let context = try XCTUnwrap(try library.context(query: "蓝鲸航线"))
    let binding = try XCTUnwrap(context.authorizationBindings.first)
    let citation = try XCTUnwrap(context.citations.first)
    XCTAssertEqual(binding.documentID, citation.documentID)
    XCTAssertEqual(binding.chunkID, citation.chunkID)
    XCTAssertNotNil(binding.chunkID)
    let initiallyValid = try await library.validateKnowledgeAuthorizationBindings(
      context.authorizationBindings,
      policy: .automatic
    )
    XCTAssertTrue(initiallyValid)

    let mismatched = KnowledgeAuthorizationBinding(
      documentID: binding.documentID,
      revisionID: binding.revisionID,
      chunkID: binding.chunkID,
      contentHash: "not-the-stored-hash"
    )
    let mismatchedValid = try await library.validateKnowledgeAuthorizationBindings(
      [mismatched],
      policy: .automatic
    )
    XCTAssertFalse(mismatchedValid)
  }

  func testExplicitSnapshotBindsNormalizedRevisionAndPolicyOffStillValidates() async throws {
    let rootURL = try temporaryDirectory(prefix: "knowledge-binding-explicit")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let documentID = try await commit(
      title: "显式资料",
      text: "显式引用需要锁定整篇资料的规范化版本。",
      allowsRemoteAIUse: true,
      library: library
    )

    let snapshotValue = try await library.explicitAIContextSnapshot(documentID: documentID)
    let snapshot = try XCTUnwrap(snapshotValue)
    let revision = try XCTUnwrap(library.revisions(documentID: documentID).first)
    XCTAssertFalse(snapshot.text.isEmpty)
    XCTAssertNil(snapshot.authorizationBinding.chunkID)
    XCTAssertEqual(snapshot.authorizationBinding.revisionID, revision.id)
    XCTAssertEqual(snapshot.authorizationBinding.contentHash, revision.normalizedContentHash)
    let explicitValid = try await library.validateKnowledgeAuthorizationBindings(
      [snapshot.authorizationBinding],
      policy: .off
    )
    XCTAssertTrue(explicitValid)
  }

  func testAuthorizationRejectsPermissionArchiveRevisionAndIgnoresUnrelatedDocument() async throws {
    let rootURL = try temporaryDirectory(prefix: "knowledge-binding-lifecycle")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let sourceURL = rootURL.appendingPathComponent("versioned.md")
    try "第一版资料：琥珀航线。".write(to: sourceURL, atomically: true, encoding: .utf8)
    let firstID = try await commit(
      title: "版本资料",
      text: "第一版资料：琥珀航线。",
      allowsRemoteAIUse: true,
      library: library,
      sourceURL: sourceURL
    )
    let secondID = try await commit(
      title: "无关资料",
      text: "另一条不会影响绑定的资料。",
      allowsRemoteAIUse: true,
      library: library
    )
    let context = try XCTUnwrap(try library.context(query: "琥珀航线"))
    let binding = try XCTUnwrap(context.authorizationBindings.first)

    try library.setAllowsRemoteAIUse(false, documentID: secondID)
    let unrelatedMutationValid = try await library.validateKnowledgeAuthorizationBindings(
      [binding],
      policy: .automatic
    )
    XCTAssertTrue(unrelatedMutationValid)

    try library.setAllowsRemoteAIUse(false, documentID: firstID)
    let revokedValid = try await library.validateKnowledgeAuthorizationBindings(
      [binding],
      policy: .automatic
    )
    XCTAssertFalse(revokedValid)
    try library.setAllowsRemoteAIUse(true, documentID: firstID)

    try library.moveToRecycleBin(documentIDs: [firstID])
    let archivedValid = try await library.validateKnowledgeAuthorizationBindings(
      [binding],
      policy: .automatic
    )
    XCTAssertFalse(archivedValid)
    try library.restoreFromRecycleBin(documentIDs: [firstID])

    try "第二版资料：蓝鲸轨道。".write(to: sourceURL, atomically: true, encoding: .utf8)
    let refresh = try await library.makeSourceRefreshPreview(documentID: firstID)
    _ = try await library.applySourceRefresh(refresh)
    let revisedValid = try await library.validateKnowledgeAuthorizationBindings(
      [binding],
      policy: .automatic
    )
    XCTAssertFalse(revisedValid)
  }

  func testPinnedOnlyUsesAuthoritativePinSetAndSnapshotDecodingIsBackwardCompatible() async throws {
    let rootURL = try temporaryDirectory(prefix: "knowledge-binding-pinned")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let library = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let documentID = try await commit(
      title: "固定资料",
      text: "固定资料的权限应该经过权威 pin 状态校验。",
      allowsRemoteAIUse: true,
      library: library
    )
    let snapshotValue = try await library.explicitAIContextSnapshot(documentID: documentID)
    let snapshot = try XCTUnwrap(snapshotValue)
    let binding = snapshot.authorizationBinding

    try library.setPinned(true, documentID: documentID)
    let pinnedValid = try await library.validateKnowledgeAuthorizationBindings(
      [binding],
      policy: .pinnedOnly
    )
    XCTAssertTrue(pinnedValid)
    try library.setPinned(false, documentID: documentID)
    let unpinnedValid = try await library.validateKnowledgeAuthorizationBindings(
      [binding],
      policy: .pinnedOnly
    )
    XCTAssertFalse(unpinnedValid)

    let context = KnowledgeContextSnapshot(query: "旧", citations: [])
    let encoded = try JSONEncoder().encode(context)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "authorizationBindings")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(KnowledgeContextSnapshot.self, from: legacyData)
    XCTAssertTrue(decoded.authorizationBindings.isEmpty)

    let populated = KnowledgeContextSnapshot(
      query: "sanitizer",
      citations: [],
      authorizationBindings: [binding]
    )
    let sanitized = AIOutboundPayloadPrivacyService().sanitizedKnowledgeContext(populated)
    XCTAssertEqual(sanitized?.authorizationBindings, [binding])
  }

  private func commit(
    title: String,
    text: String,
    allowsRemoteAIUse: Bool,
    library: KnowledgeLibraryService,
    sourceURL: URL? = nil
  ) async throws -> UUID {
    let hash = KnowledgeChunkingService.contentHash(for: text)
    let candidate = KnowledgeImportCandidate(
      kind: .markdown,
      title: title,
      sourceURL: sourceURL,
      sourceName: "\(title).md",
      allowsRemoteAIUse: allowsRemoteAIUse,
      originalContentHash: hash,
      normalizedText: text,
      normalizedContentHash: hash,
      sections: [KnowledgeExtractedSection(headingPath: title, text: text)]
    )
    let preview = KnowledgeImportPreview(sourceName: "fixture", candidates: [candidate])
    let result = try await library.commit(preview)
    return try XCTUnwrap(result.documentIDs.first)
  }

  private func temporaryDirectory(prefix: String) throws -> URL {
    try TestWorkbenchFactory.temporaryDirectoryURL(prefix: prefix)
  }
}
