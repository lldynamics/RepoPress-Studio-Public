import XCTest
@testable import PublishingWorkbenchCore

final class ReleaseRecordDraftResolverTests: XCTestCase {
  func testDoesNotFallBackToUnrelatedLatestRecord() {
    let profileID = UUID()
    let draft = makeDraft(profileID: profileID, title: "当前文章")
    let unrelatedRecord = makeRecord(
      profileID: profileID,
      draftID: UUID(),
      draftTitle: "另一篇文章"
    )

    let result = ReleaseRecordDraftResolver.latestRecord(
      for: draft,
      in: [unrelatedRecord]
    )

    XCTAssertNil(result)
  }

  func testExactDraftIDWinsOverNewerLegacyTitleMatch() {
    let profileID = UUID()
    let draft = makeDraft(profileID: profileID, title: "同名文章")
    let exactRecord = makeRecord(
      profileID: profileID,
      draftID: draft.id,
      draftTitle: draft.title,
      createdAt: Date(timeIntervalSince1970: 100)
    )
    let newerLegacyRecord = makeRecord(
      profileID: profileID,
      draftID: nil,
      draftTitle: draft.title,
      createdAt: Date(timeIntervalSince1970: 200)
    )

    let result = ReleaseRecordDraftResolver.latestRecord(
      for: draft,
      in: [newerLegacyRecord, exactRecord]
    )

    XCTAssertEqual(result?.id, exactRecord.id)
  }

  func testMatchesBatchRecordContainingDraftID() {
    let profileID = UUID()
    let draft = makeDraft(profileID: profileID, title: "批量文章")
    let batchRecord = makeRecord(
      profileID: profileID,
      draftTitle: nil,
      batchItems: [
        ReleaseRecordBatchItem(
          draftID: draft.id,
          draftTitle: draft.title,
          markdownPath: "content/posts/batch.md",
          changedPaths: ["content/posts/batch.md"]
        )
      ]
    )

    let result = ReleaseRecordDraftResolver.latestRecord(
      for: draft,
      in: [batchRecord]
    )

    XCTAssertEqual(result?.id, batchRecord.id)
  }

  func testMatchesStrictLegacyRecordByTitleAndProfile() {
    let profileID = UUID()
    let draft = makeDraft(profileID: profileID, title: "旧版文章")
    let legacyRecord = makeRecord(
      profileID: profileID,
      draftID: nil,
      draftTitle: draft.title
    )

    let result = ReleaseRecordDraftResolver.latestRecord(
      for: draft,
      in: [legacyRecord]
    )

    XCTAssertEqual(result?.id, legacyRecord.id)
  }

  func testRejectsLegacyRecordsWithoutMatchingProfileOrSingleDraftShape() {
    let profileID = UUID()
    let draft = makeDraft(profileID: profileID, title: "旧版文章")
    let otherProfileRecord = makeRecord(
      profileID: UUID(),
      draftID: nil,
      draftTitle: draft.title
    )
    let unscopedRecord = makeRecord(
      profileID: nil,
      draftID: nil,
      draftTitle: draft.title
    )
    let batchRecord = makeRecord(
      profileID: profileID,
      draftID: nil,
      draftTitle: draft.title,
      batchItems: [
        ReleaseRecordBatchItem(
          draftID: UUID(),
          draftTitle: "另一篇文章",
          markdownPath: "content/posts/other.md",
          changedPaths: ["content/posts/other.md"]
        )
      ]
    )

    let result = ReleaseRecordDraftResolver.latestRecord(
      for: draft,
      in: [otherProfileRecord, unscopedRecord, batchRecord]
    )

    XCTAssertNil(result)
  }

  private func makeDraft(profileID: UUID, title: String) -> ArticleDraft {
    ArticleDraft(
      id: UUID(),
      siteProfileID: profileID,
      title: title,
      slug: "test-draft"
    )
  }

  private func makeRecord(
    profileID: UUID?,
    draftID: UUID? = nil,
    draftTitle: String?,
    batchItems: [ReleaseRecordBatchItem] = [],
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "发布记录",
      summary: "发布完成",
      siteProfileID: profileID,
      draftID: draftID,
      draftTitle: draftTitle,
      batchItems: batchItems,
      createdAt: createdAt
    )
  }
}
