import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class MarkdownPreviewEnhancementServicesTests: XCTestCase {
  func testLoadsPreferredBoundedSiteStylesheets() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cssDirectory = root.appendingPathComponent("static/css", isDirectory: true)
    try FileManager.default.createDirectory(
      at: cssDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("body { color: rebeccapurple; }\n</style><script>".utf8)
      .write(to: cssDirectory.appendingPathComponent("site.css"))
    try Data(".extra { display: grid; }".utf8)
      .write(to: cssDirectory.appendingPathComponent("extra.css"))

    let result = try XCTUnwrap(
      SitePreviewStyleService.load(from: root, siteKind: .zola)
    )
    XCTAssertEqual(result.sourcePaths.first, "static/css/site.css")
    XCTAssertTrue(result.css.contains("rebeccapurple"))
    XCTAssertTrue(result.css.contains(".extra"))
    XCTAssertFalse(result.css.localizedCaseInsensitiveContains("</style"))
    XCTAssertTrue(result.css.contains("<\\/style"))
  }

  func testSkipsGeneratedAndDependencyStylesheets() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let dependencyDirectory = root.appendingPathComponent(
      "node_modules/package",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: dependencyDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("body { display: none; }".utf8)
      .write(to: dependencyDirectory.appendingPathComponent("style.css"))

    XCTAssertNil(SitePreviewStyleService.load(from: root, siteKind: .astro))
  }

  func testAnnotatesRenderedHeadingsAndParsesSourceURL() throws {
    let markdown = """
      ## 第一节

      ```md
      ## 不是标题
      ```

      ### 第二节
      """
    let html = "<h2>第一节</h2><pre>## 不是标题</pre><h3>第二节</h3>"
    let annotated = MarkdownPreviewSourceLinkService.annotatingHeadingLinks(
      in: html,
      sourceMarkdown: markdown
    )

    XCTAssertEqual(annotated.components(separatedBy: "repopress-source-jump").count - 1, 2)
    let urlText = try XCTUnwrap(
      annotated.range(of: #"publisher-source://jump/\d+"#, options: .regularExpression)
        .map { String(annotated[$0]) }
    )
    let url = try XCTUnwrap(URL(string: urlText))
    XCTAssertEqual(MarkdownPreviewSourceLinkService.sourceLocation(from: url), 0)
  }
}
