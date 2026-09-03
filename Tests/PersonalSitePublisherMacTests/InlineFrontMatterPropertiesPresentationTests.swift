import XCTest

@testable import PersonalSitePublisherMac

final class InlineFrontMatterPropertiesPresentationTests: XCTestCase {
  func testEffectiveExpandedHonorsPersistentStateAndForceCompact() {
    XCTAssertTrue(
      InlineFrontMatterPropertiesPresentation.effectiveExpanded(
        isExpanded: true,
        forceCompact: false
      )
    )
    XCTAssertFalse(
      InlineFrontMatterPropertiesPresentation.effectiveExpanded(
        isExpanded: false,
        forceCompact: false
      )
    )
    XCTAssertFalse(
      InlineFrontMatterPropertiesPresentation.effectiveExpanded(
        isExpanded: true,
        forceCompact: true
      )
    )
  }

  func testSummaryUsesSlugFallbackAndNormalizedCollectionCounts() {
    let date = Date(timeIntervalSince1970: 0)
    let summary = InlineFrontMatterPropertiesPresentation.summary(
      slug: "  ",
      date: date,
      tags: ["Swift", " swift ", "  ", "Mac"],
      categories: ["写作", "写作"],
      sourceIssueMessage: nil
    )

    XCTAssertTrue(summary.hasPrefix("Front Matter · "))
    XCTAssertTrue(summary.contains("标签 2"))
    XCTAssertTrue(summary.contains("分类 1"))
    XCTAssertFalse(summary.contains("·  ·"))
  }

  func testSummaryPrefersSourceIssue摘要() {
    let summary = InlineFrontMatterPropertiesPresentation.summary(
      slug: "article",
      date: Date(timeIntervalSince1970: 0),
      tags: [],
      categories: [],
      sourceIssueMessage: "  缩进无效  "
    )

    XCTAssertEqual(summary, "Front Matter · 格式错误：缩进无效")
  }

  func testNormalizedTrimsDropsEmptyAndDeduplicatesCaseInsensitively() {
    let values = InlineFrontMatterCollectionEditing.normalized(
      ["  Swift  ", "", "swift", "  写作", "写作  ", "  "]
    )

    XCTAssertEqual(values, ["Swift", "写作"])
  }

  func testAddingPreservesOrderAndDoesNotAddBlankOrDuplicateValues() {
    XCTAssertEqual(
      InlineFrontMatterCollectionEditing.adding("  Mac  ", to: ["Swift", " iOS ", "swift"]),
      ["Swift", "iOS", "Mac"]
    )
    XCTAssertEqual(
      InlineFrontMatterCollectionEditing.adding("  SWIFT ", to: ["Swift"]),
      ["Swift"]
    )
    XCTAssertEqual(
      InlineFrontMatterCollectionEditing.adding(" \n ", to: ["Swift"]),
      ["Swift"]
    )
  }

  func testRemovingMatchesCaseInsensitivelyAndReturnsNormalizedValues() {
    XCTAssertEqual(
      InlineFrontMatterCollectionEditing.removing(" swift ", from: ["Swift", " iOS ", "IOS"]),
      ["iOS"]
    )
  }

  func testSuggestionsExcludeSelectedValuesThenSortAndDeduplicate() {
    let suggestions = InlineFrontMatterCollectionEditing.suggestions(
      from: ["  Zebra", "apple", "Blog", "APPLE", "  ", "Code"],
      excluding: [" blog "]
    )

    XCTAssertEqual(suggestions, ["apple", "Code", "Zebra"])
  }

  func testPresentationUsesStyleSpecificSourceTitlesAndForcesSourceForIssues() {
    XCTAssertEqual(
      InlineFrontMatterPropertiesPresentation.sourceTitle(for: .yaml),
      "YAML 源码"
    )
    XCTAssertEqual(
      InlineFrontMatterPropertiesPresentation.sourceTitle(for: .toml),
      "TOML 源码"
    )
    XCTAssertFalse(
      InlineFrontMatterPropertiesPresentation.showsSource(requested: false, hasIssue: false)
    )
    XCTAssertTrue(
      InlineFrontMatterPropertiesPresentation.showsSource(requested: true, hasIssue: false)
    )
    XCTAssertTrue(
      InlineFrontMatterPropertiesPresentation.showsSource(requested: false, hasIssue: true)
    )
  }
}
