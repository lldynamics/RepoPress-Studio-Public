import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class ArticleProvenanceLocalizationTests: XCTestCase {
  func testArticleProvenanceUsesStableSemanticDisplayNameKeys() {
    let expected: [ArticleProvenance: String] = [
      .humanOriginal: "display.article-provenance.human-original",
      .aiAssisted: "display.article-provenance.ai-assisted",
      .aiAuthored: "display.article-provenance.ai-authored",
      .hybrid: "display.article-provenance.hybrid",
    ]

    for provenance in ArticleProvenance.allCases {
      XCTAssertEqual(provenance.workbenchDisplayNameSemanticKey, expected[provenance])
      XCTAssertFalse(provenance.localizedDisplayName.isEmpty)
    }
  }
}
