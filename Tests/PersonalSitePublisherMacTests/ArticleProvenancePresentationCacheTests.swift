import Foundation
import PublishingDomainContracts
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class ArticleProvenancePresentationCacheTests: XCTestCase {
  func testUnchangedInputsReuseClassificationAcrossPresentationReads() {
    let cache = ArticleProvenancePresentationCache()
    let id = UUID()
    var count = 0
    for _ in 0..<10 {
      let value = cache.provenance(draftID: id, tags: ["AI辅助"], bodyMarkdown: "正文") {
        count += 1
        return .aiAssisted
      }
      XCTAssertEqual(value, .aiAssisted)
    }
    XCTAssertEqual(count, 1)
  }

  func testIdentityTagsAndSameLengthBodyEditsEachInvalidate() {
    let cache = ArticleProvenancePresentationCache()
    let firstID = UUID()
    let secondID = UUID()
    var count = 0
    func resolve(_ id: UUID, _ tags: [String], _ body: String) {
      _ = cache.provenance(draftID: id, tags: tags, bodyMarkdown: body) {
        count += 1
        return .humanOriginal
      }
    }

    resolve(firstID, [], "甲乙")
    resolve(secondID, [], "甲乙")
    XCTAssertEqual(count, 2)
    resolve(secondID, ["AI辅助"], "甲乙")
    XCTAssertEqual(count, 3)
    resolve(secondID, [], "甲乙")
    XCTAssertEqual(count, 4)
    resolve(secondID, [], "丙丁")
    XCTAssertEqual(count, 5)
    // Only the current entry is retained, even if an earlier draft returns.
    resolve(firstID, [], "甲乙")
    XCTAssertEqual(count, 6)
  }

  func testDisclosureInsertionAndRemovalUseTheNewClassification() {
    let cache = ArticleProvenancePresentationCache()
    let id = UUID()
    let body = "正文"
    let disclosure =
      body + "\n<!-- repopress:provenance:start -->\n创作说明\n<!-- repopress:provenance:end -->"
    var count = 0
    func resolve(_ body: String, as result: ArticleProvenance) -> ArticleProvenance {
      cache.provenance(draftID: id, tags: [], bodyMarkdown: body) {
        count += 1
        return result
      }
    }

    XCTAssertEqual(resolve(body, as: .humanOriginal), .humanOriginal)
    XCTAssertEqual(resolve(disclosure, as: .hybrid), .hybrid)
    XCTAssertEqual(resolve(disclosure, as: .hybrid), .hybrid)
    XCTAssertEqual(resolve(body, as: .humanOriginal), .humanOriginal)
    XCTAssertEqual(count, 3)
  }
}
