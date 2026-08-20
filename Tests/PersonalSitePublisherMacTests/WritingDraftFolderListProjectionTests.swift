import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class WritingDraftFolderListProjectionTests: XCTestCase {
  private let profileID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

  func testCollapsedTreeKeepsTopLevelHeadersVisible() {
    let projection = makeProjection()

    let entries = WritingDraftFolderListProjection.flatten(
      root: projection,
      expandedFolderIDs: [],
      loadedDraftIDs: allDraftIDs
    )

    XCTAssertEqual(entries.filter(\.isFolder).count, 2)
    XCTAssertEqual(entries.first?.draftID, rootDraftID)
    XCTAssertEqual(
      entries.dropFirst().compactMap { $0.folder?.name },
      ["2025", "2026"]
    )
  }

  func testExpansionRevealsNestedHeadersAndDraftsInCoreOrder() {
    let projection = makeProjection()
    let expandedIDs = Set(projection.allFolderIDs)

    let entries = WritingDraftFolderListProjection.flatten(
      root: projection,
      expandedFolderIDs: expandedIDs,
      loadedDraftIDs: allDraftIDs
    )

    XCTAssertEqual(entries.first?.draftID, rootDraftID)
    XCTAssertEqual(entries.compactMap(\.folder).map(\.name), ["2025", "swift", "2026", "swift"])
    XCTAssertEqual(entries.map(\.depth), [0, 0, 1, 2, 2, 0, 1, 2])
  }

  func testLoadedDraftIDsControlPaginationWithoutHidingFolderHeaders() {
    let projection = makeProjection()
    let expandedIDs = Set(projection.allFolderIDs)
    let loadedIDs: Set<UUID> = [rootDraftID, firstNestedDraftID]

    let entries = WritingDraftFolderListProjection.flatten(
      root: projection,
      expandedFolderIDs: expandedIDs,
      loadedDraftIDs: loadedIDs
    )

    XCTAssertEqual(Set(entries.compactMap(\.draftID)), loadedIDs)
    XCTAssertEqual(entries.filter(\.isFolder).count, 4)
    XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
  }

  func testEntryIDsAreStableAndUniqueAcrossRepeatedFlattening() {
    let projection = makeProjection()
    let expandedIDs = Set(projection.allFolderIDs)

    let first = WritingDraftFolderListProjection.flatten(
      root: projection,
      expandedFolderIDs: expandedIDs,
      loadedDraftIDs: allDraftIDs
    )
    let second = WritingDraftFolderListProjection.flatten(
      root: projection,
      expandedFolderIDs: expandedIDs,
      loadedDraftIDs: allDraftIDs
    )

    XCTAssertEqual(first, second)
    XCTAssertEqual(Set(first.map(\.id)).count, first.count)
  }

  private var rootDraftID: UUID {
    UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
  }

  private var firstNestedDraftID: UUID {
    UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
  }

  private var allDraftIDs: Set<UUID> {
    [
      rootDraftID,
      firstNestedDraftID,
      UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
      UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
    ]
  }

  private func makeProjection() -> DraftFolderNode {
    let profile = SiteProfile(
      id: profileID,
      name: "测试站点",
      contentRoot: "content",
      markdownPathPattern: "content/{slug}.md"
    )
    let drafts = [
      makeDraft(id: rootDraftID, title: "根目录", slug: "root"),
      makeDraft(id: firstNestedDraftID, title: "2025 A", slug: "2025/swift/one"),
      makeDraft(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
        title: "2025 B",
        slug: "2025/swift/two"
      ),
      makeDraft(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
        title: "2026 A",
        slug: "2026/swift/three"
      ),
    ]
    return DraftFolderProjection.make(
      drafts: drafts,
      profile: profile,
      sortOrder: .titleAscending
    )
  }

  private func makeDraft(id: UUID, title: String, slug: String) -> ArticleDraft {
    ArticleDraft(
      id: id,
      siteProfileID: profileID,
      title: title,
      slug: slug,
      updatedAt: Date(timeIntervalSince1970: 100)
    )
  }
}
