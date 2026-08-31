import Foundation
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeDocumentModelsTests: XCTestCase {
  func testLegacyDocumentPayloadMigratesAISettingAndClampsNegativeByteCount() throws {
    let documentID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    let revisionID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    let payload = """
      {
        "id": "\(documentID.uuidString)",
        "kind": "article",
        "title": "Legacy document",
        "authors": ["Alice"],
        "summary": "compatibility",
        "tags": ["migration"],
        "sourceName": "legacy.md",
        "sourceByteCount": -42,
        "allowsAIUse": true,
        "isArchived": false,
        "importedAt": 0,
        "updatedAt": 0,
        "currentRevisionID": "\(revisionID.uuidString)"
      }
      """

    let document = try JSONDecoder().decode(KnowledgeDocument.self, from: Data(payload.utf8))
    XCTAssertEqual(document.id, documentID)
    XCTAssertEqual(document.currentRevisionID, revisionID)
    XCTAssertEqual(document.sourceByteCount, 0)
    XCTAssertTrue(document.allowsLocalSemanticIndex)
    XCTAssertTrue(document.allowsRemoteAIUse)

    let encoded = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any]
    )
    XCTAssertEqual(encoded["allowsRemoteAIUse"] as? Bool, true)
    XCTAssertNil(encoded["allowsAIUse"])
  }

  func testBacklinkGroupRejectsEmptyInputSortsByRecencyAndDeduplicatesChunkIDs() {
    XCTAssertNil(KnowledgeBacklinkGroup(backlinks: []))
    let documentID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    let firstChunkID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    let secondChunkID = UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
    let oldest = backlink(
      documentID: documentID,
      chunkID: firstChunkID,
      targetTitle: "Original target",
      createdAt: 10
    )
    let newest = backlink(
      documentID: documentID,
      chunkID: secondChunkID,
      targetTitle: "Newest target",
      createdAt: 30
    )
    let duplicateChunk = backlink(
      documentID: documentID,
      chunkID: firstChunkID,
      targetTitle: "Newest target",
      createdAt: 20
    )

    let group = KnowledgeBacklinkGroup(backlinks: [oldest, newest, duplicateChunk])
    XCTAssertEqual(group?.targetTitle, "Newest target")
    XCTAssertEqual(
      group?.backlinks.map(\.createdAt),
      [
        Date(timeIntervalSince1970: 30),
        Date(timeIntervalSince1970: 20),
        Date(timeIntervalSince1970: 10),
      ])
    XCTAssertEqual(group?.citedChunkIDs, [firstChunkID, secondChunkID])
    XCTAssertEqual(KnowledgeBacklinkTargetKind.articleDraft.displayName, "文章")
    XCTAssertEqual(KnowledgeBacklinkTargetKind.aiResponse.displayName, "AI 回复")
  }

  func testRevisionAndHealthSnapshotsClampCountsAndReportAttentionOnlyForRepairWork() {
    let unchanged = KnowledgeRevisionDifference(
      previousLineCount: -1,
      currentLineCount: -2,
      addedLineCount: -3,
      removedLineCount: -4,
      previousExcerpt: "before",
      currentExcerpt: "after"
    )
    XCTAssertEqual(unchanged.previousLineCount, 0)
    XCTAssertEqual(unchanged.currentLineCount, 0)
    XCTAssertFalse(unchanged.hasChanges)

    let changed = KnowledgeRevisionDifference(
      previousLineCount: 2,
      currentLineCount: 3,
      addedLineCount: 1,
      removedLineCount: 0,
      previousExcerpt: "before",
      currentExcerpt: "after"
    )
    XCTAssertTrue(changed.hasChanges)

    let healthy = KnowledgeLibraryHealthSnapshot(
      currentParserVersion: 4,
      documentCount: -1,
      indexedChunkCount: -1,
      outdatedParserDocumentCount: 0,
      locallyRepairableDocumentCount: -1,
      lowQualityChunkCount: 0,
      semanticRepairChunkCount: 0
    )
    XCTAssertEqual(healthy.documentCount, 0)
    XCTAssertEqual(healthy.indexedChunkCount, 0)
    XCTAssertEqual(healthy.locallyRepairableDocumentCount, 0)
    XCTAssertFalse(healthy.needsAttention)

    let attentionRequired = KnowledgeLibraryHealthSnapshot(
      currentParserVersion: 4,
      documentCount: 1,
      indexedChunkCount: 1,
      outdatedParserDocumentCount: 1,
      locallyRepairableDocumentCount: 0,
      lowQualityChunkCount: 0,
      semanticRepairChunkCount: 0
    )
    XCTAssertTrue(attentionRequired.needsAttention)
  }

  private func backlink(
    documentID: UUID,
    chunkID: UUID,
    targetTitle: String,
    createdAt: TimeInterval
  ) -> KnowledgeBacklink {
    KnowledgeBacklink(
      documentID: documentID,
      chunkID: chunkID,
      targetKind: .articleDraft,
      targetID: "draft-1",
      targetTitle: targetTitle,
      createdAt: Date(timeIntervalSince1970: createdAt)
    )
  }
}
