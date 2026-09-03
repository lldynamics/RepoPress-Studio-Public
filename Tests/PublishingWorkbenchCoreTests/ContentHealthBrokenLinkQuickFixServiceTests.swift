import XCTest

@testable import PublishingWorkbenchCore

final class ContentHealthBrokenLinkQuickFixServiceTests: XCTestCase {
  private let service = ContentHealthBrokenLinkQuickFixService()

  func testReplacementPlanReplacesEveryExactBrokenTargetAndPreservesQueryAndFragment() throws {
    let draftID = UUID()
    let oldTarget = "assets/missing.png?width=640#preview"
    let body = """
      ![首图](assets/missing.png?width=640#preview)
      [资料](assets/missing.png?width=640#preview)
      """
    let references = try references(
      in: body,
      draftID: draftID,
      fullTarget: oldTarget,
      pathTarget: "assets/missing.png",
      count: 2
    )

    let plan = try service.replacementPlan(
      bodyMarkdown: body,
      references: references,
      sourceDraftID: draftID,
      oldTarget: oldTarget,
      newTarget: "../../assets/fixed.png"
    )
    let result = try service.apply(plan, to: body)

    XCTAssertEqual(result.replacementCount, 2)
    XCTAssertEqual(
      result.bodyMarkdown,
      """
      ![首图](../../assets/fixed.png?width=640#preview)
      [资料](../../assets/fixed.png?width=640#preview)
      """
    )
  }

  func testReplacementUsesUTF16RangesAndDoesNotTouchUnreportedCodeOrPlainText() throws {
    let draftID = UUID()
    let oldTarget = "missing.png"
    let body = """
      中文前缀 [链接](missing.png)
      `missing.png`
      普通文本 missing.png
      ```md
      [代码](missing.png)
      ```
      """
    let reference = try XCTUnwrap(
      references(
        in: body,
        draftID: draftID,
        fullTarget: oldTarget,
        pathTarget: oldTarget,
        count: 1
      ).first
    )
    let plan = try service.replacementPlan(
      bodyMarkdown: body,
      references: [reference],
      sourceDraftID: draftID,
      oldTarget: oldTarget,
      newTarget: "assets/fixed.png"
    )
    let result = try service.apply(plan, to: body)

    XCTAssertEqual(
      result.bodyMarkdown,
      """
      中文前缀 [链接](assets/fixed.png)
      `missing.png`
      普通文本 missing.png
      ```md
      [代码](missing.png)
      ```
      """
    )
  }

  func testReplacementRejectsNonRepairableTargetsAndNonBrokenReferences() throws {
    XCTAssertFalse(service.isRepairableLocalRelativePath("", syntax: .markdown))
    XCTAssertFalse(service.isRepairableLocalRelativePath("/assets/a.png", syntax: .markdown))
    XCTAssertFalse(service.isRepairableLocalRelativePath("#section", syntax: .markdown))
    XCTAssertFalse(
      service.isRepairableLocalRelativePath("https://example.com/a.png", syntax: .markdown))
    XCTAssertFalse(service.isRepairableLocalRelativePath("page", syntax: .wiki))
    XCTAssertTrue(service.isRepairableLocalRelativePath("assets/a.png?x=1#part", syntax: .markdown))

    let draftID = UUID()
    let body = "[链接](missing.png)"
    var validReference = try XCTUnwrap(
      references(
        in: body,
        draftID: draftID,
        fullTarget: "missing.png",
        pathTarget: "missing.png",
        count: 1
      ).first
    )
    validReference.resolution = .validInternal
    XCTAssertThrowsError(
      try service.replacementPlan(
        bodyMarkdown: body,
        references: [validReference],
        sourceDraftID: draftID,
        oldTarget: "missing.png",
        newTarget: "assets/fixed.png"
      )
    ) { error in
      XCTAssertEqual(error as? ContentHealthBrokenLinkQuickFixError, .noMatchingBrokenReferences)
    }
  }

  func testResourcePlanEncodesSpacesHashAndUnicodeAndIsRelativeToSourceMarkdown() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let resource = fixture.appendingPathComponent("assets/空 格#.png")
    try FileManager.default.createDirectory(
      at: resource.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("image".utf8).write(to: resource)

    let plan = try service.resourcePlan(
      selectedURL: resource,
      repositoryRootURL: fixture,
      sourceRepositoryPath: "content/posts/article.md"
    )

    XCTAssertEqual(plan.selectedRepositoryPath, "assets/空 格#.png")
    XCTAssertEqual(plan.replacementTarget, "../../assets/%E7%A9%BA%20%E6%A0%BC%23.png")
  }

  func testResourcePlanRejectsMissingOutsideAndSymlinkEscapingRepository() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let outside = fixture.deletingLastPathComponent().appendingPathComponent(
      "outside-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data("outside".utf8).write(to: outside)

    XCTAssertThrowsError(
      try service.resourcePlan(
        selectedURL: fixture.appendingPathComponent("assets/missing.png"),
        repositoryRootURL: fixture,
        sourceRepositoryPath: "content/article.md"
      )
    ) { error in
      XCTAssertEqual(error as? ContentHealthBrokenLinkQuickFixError, .selectedResourceDoesNotExist)
    }
    XCTAssertThrowsError(
      try service.resourcePlan(
        selectedURL: outside,
        repositoryRootURL: fixture,
        sourceRepositoryPath: "content/article.md"
      )
    ) { error in
      XCTAssertEqual(
        error as? ContentHealthBrokenLinkQuickFixError, .selectedResourceOutsideRepository)
    }

    let link = fixture.appendingPathComponent("assets/escaping.png")
    try FileManager.default.createDirectory(
      at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertThrowsError(
      try service.resourcePlan(
        selectedURL: link,
        repositoryRootURL: fixture,
        sourceRepositoryPath: "content/article.md"
      )
    ) { error in
      XCTAssertEqual(
        error as? ContentHealthBrokenLinkQuickFixError, .selectedResourceOutsideRepository)
    }
  }

  private func references(
    in body: String,
    draftID: UUID,
    fullTarget: String,
    pathTarget: String,
    count: Int
  ) throws -> [SiteLinkReference] {
    let source = body as NSString
    var searchRange = NSRange(location: 0, length: source.length)
    return try (0..<count).map { _ in
      let range = source.range(of: pathTarget, options: [], range: searchRange)
      guard range.location != NSNotFound else {
        throw NSError(domain: "ContentHealthBrokenLinkQuickFixServiceTests", code: 1)
      }
      searchRange = NSRange(location: NSMaxRange(range), length: source.length - NSMaxRange(range))
      return SiteLinkReference(
        sourceDraftID: draftID,
        sourceTitle: "文章",
        anchorText: "链接",
        target: fullTarget,
        syntax: .markdown,
        targetUTF16Range: range,
        resolution: .brokenInternal
      )
    }
  }

  private func makeFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("content-health-broken-link-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
