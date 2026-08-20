import XCTest

@testable import PublishingWorkbenchCore

final class DraftFolderProjectionTests: XCTestCase {
  private let profileID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

  func testBuildsNestedFoldersStripsContentRootAndKeepsStableFullPathIDs() {
    let profile = makeProfile(pattern: "content/{slug}.md")
    let drafts = [
      makeDraft(id: "00000000-0000-4000-8000-000000000001", slug: "2026/swift/one"),
      makeDraft(id: "00000000-0000-4000-8000-000000000002", slug: "2026/swift/two"),
      makeDraft(id: "00000000-0000-4000-8000-000000000003", slug: "2025/swift/three"),
    ]

    let root = DraftFolderProjection.make(
      drafts: drafts,
      profile: profile,
      sortOrder: .titleAscending
    )

    XCTAssertEqual(root.kind, .root)
    XCTAssertEqual(root.children.map(\.directoryPath), ["2025", "2026"])
    let year2026 = tryUnwrap(root.children.first { $0.name == "2026" })
    let swift = tryUnwrap(year2026.children.first { $0.name == "swift" })
    XCTAssertEqual(swift.directoryPath, "2026/swift")
    XCTAssertEqual(swift.canonicalDirectory, "content/2026/swift")
    XCTAssertTrue(swift.id.contains(profile.id.uuidString.lowercased()))
    XCTAssertTrue(swift.id.contains("content/2026/swift"))
    XCTAssertEqual(swift.totalDraftCount, 2)
  }

  func testRootPathDraftLivesOnRootAndHasNoVisibleFolderAncestors() {
    let profile = makeProfile(pattern: "content/{slug}.md")
    let draft = makeDraft(
      id: "00000000-0000-4000-8000-000000000010",
      slug: "at-root"
    )

    let root = DraftFolderProjection.make(drafts: [draft], profile: profile)

    XCTAssertEqual(root.drafts, [draft.id])
    XCTAssertTrue(root.children.isEmpty)
    XCTAssertEqual(root.ancestorFolderIDs(containing: draft.id), [])
    XCTAssertEqual(root.totalDraftCount, 1)
  }

  func testSameLeafNamesUnderDifferentParentsHaveDistinctIDs() {
    let profile = makeProfile(pattern: "content/{slug}.md")
    let drafts = [
      makeDraft(id: "00000000-0000-4000-8000-000000000020", slug: "2025/shared/one"),
      makeDraft(id: "00000000-0000-4000-8000-000000000021", slug: "2026/shared/two"),
    ]

    let root = DraftFolderProjection.make(drafts: drafts, profile: profile)
    let sharedNodes = root.children.compactMap { year in
      year.children.first { $0.name == "shared" }
    }

    XCTAssertEqual(sharedNodes.count, 2)
    XCTAssertEqual(Set(sharedNodes.map(\.id)).count, 2)
    XCTAssertEqual(
      Set(sharedNodes.compactMap(\.canonicalDirectory)),
      ["content/2025/shared", "content/2026/shared"]
    )
  }

  func testMaskedDraftUsesProtectedVirtualNodeWithoutPath() {
    let profile = makeProfile(pattern: "content/posts/{slug}.md")
    let draft = makeDraft(
      id: "00000000-0000-4000-8000-000000000030",
      slug: "secret",
      visibility: .private,
      repositoryPath: "private/very-secret/secret.md"
    )

    let root = DraftFolderProjection.make(
      drafts: [draft],
      profile: profile,
      maskedDraftIDs: [draft.id]
    )
    let protected = tryUnwrap(root.children.first { $0.kind == .protectedContent })

    XCTAssertNil(protected.directoryPath)
    XCTAssertNil(protected.canonicalDirectory)
    XCTAssertEqual(protected.drafts, [draft.id])
    XCTAssertFalse(protected.id.contains("very-secret"))
    XCTAssertFalse(protected.id.contains("secret.md"))
    XCTAssertEqual(root.ancestorFolderIDs(containing: draft.id), [protected.id])
  }

  func testGeneralDraftAndDangerousPathsUseUnfiledVirtualNode() {
    let generalProfile = makeProfile(pattern: "content/posts/{slug}.md")
    let general = makeDraft(
      id: "00000000-0000-4000-8000-000000000040",
      slug: "general",
      scope: .general
    )
    let generalRoot = DraftFolderProjection.make(drafts: [general], profile: generalProfile)
    XCTAssertEqual(generalRoot.children.map(\.kind), [.unfiled])
    XCTAssertEqual(generalRoot.children[0].drafts, [general.id])

    let dangerousPatterns = [
      "/content/posts/{slug}.md",
      "content\\posts\\{slug}.md",
      "https://example.com/{slug}.md",
      "content/../posts/{slug}.md",
    ]
    let dangerousIDs = [
      "00000000-0000-4000-8000-000000000041",
      "00000000-0000-4000-8000-000000000042",
      "00000000-0000-4000-8000-000000000043",
      "00000000-0000-4000-8000-000000000044",
    ]
    for (index, pattern) in dangerousPatterns.enumerated() {
      let profile = makeProfile(pattern: pattern)
      let draft = makeDraft(
        id: dangerousIDs[index],
        slug: "danger-\(index)"
      )
      let root = DraftFolderProjection.make(drafts: [draft], profile: profile)
      XCTAssertEqual(root.children.map(\.kind), [.unfiled], pattern)
      XCTAssertEqual(root.children[0].directoryPath, nil, pattern)
    }
  }

  func testDraftsAreSortedWithinEachFolderAndFolderOrderIsDeterministic() {
    let profile = makeProfile(pattern: "content/posts/{slug}.md")
    let older = makeDraft(
      id: "00000000-0000-4000-8000-000000000050",
      title: "Zeta",
      slug: "zeta",
      updatedAt: Date(timeIntervalSince1970: 10)
    )
    let newer = makeDraft(
      id: "00000000-0000-4000-8000-000000000051",
      title: "Alpha",
      slug: "alpha",
      updatedAt: Date(timeIntervalSince1970: 20)
    )
    let inOtherFolder = makeDraft(
      id: "00000000-0000-4000-8000-000000000052",
      title: "Other",
      slug: "other/topic",
      updatedAt: Date(timeIntervalSince1970: 30)
    )

    let first = DraftFolderProjection.make(
      drafts: [older, inOtherFolder, newer],
      profile: profile,
      sortOrder: .titleAscending
    )
    let second = DraftFolderProjection.make(
      drafts: [newer, older, inOtherFolder],
      profile: profile,
      sortOrder: .titleAscending
    )

    XCTAssertEqual(first, second)
    let posts = tryUnwrap(first.children.first { $0.name == "posts" })
    XCTAssertEqual(posts.drafts, [newer.id, older.id])
    XCTAssertEqual(first.totalDraftCount, 3)
    XCTAssertEqual(first.allFolderIDs, first.children.flatMap { [$0.id] + $0.allFolderIDs })
  }

  func testAncestorIDsIncludeEveryNestedFolderAndProjectionConvenienceAPIMatches() {
    let profile = makeProfile(pattern: "content/{slug}.md")
    let draft = makeDraft(
      id: "00000000-0000-4000-8000-000000000060",
      slug: "2026/swift/mac/topic"
    )
    let projection = DraftFolderProjection(
      drafts: [draft],
      profile: profile,
      sortOrder: .updatedNewest
    )

    let expected = projection.root.ancestorFolderIDs(containing: draft.id)
    XCTAssertEqual(expected.count, 3)
    XCTAssertEqual(projection.ancestorFolderIDs(for: draft.id), expected)
    XCTAssertEqual(projection.ancestorNodeIDs(for: draft.id), expected)
  }

  private func makeProfile(
    pattern: String,
    contentRoot: String = "content"
  ) -> SiteProfile {
    SiteProfile(
      id: profileID,
      name: "测试站点",
      contentRoot: contentRoot,
      markdownPathPattern: pattern
    )
  }

  private func makeDraft(
    id: String,
    title: String = "文章",
    slug: String,
    visibility: ArticleVisibility = .public,
    repositoryPath: String? = nil,
    scope: ArticleDraftScope? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 100)
  ) -> ArticleDraft {
    ArticleDraft(
      id: UUID(uuidString: id)!,
      siteProfileID: profileID,
      scope: scope,
      title: title,
      slug: slug,
      visibility: visibility,
      updatedAt: updatedAt,
      repositoryPath: repositoryPath
    )
  }

  private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
    XCTAssertNotNil(value, file: file, line: line)
    return value!
  }
}
