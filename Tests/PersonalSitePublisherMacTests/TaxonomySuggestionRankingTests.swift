import Foundation
import XCTest

@testable import PersonalSitePublisherMac

final class TaxonomySuggestionRankingTests: XCTestCase {
  func testTagsStayWithinCurrentSiteRankByArticleFrequencyAndKeepSelectedChineseValues() {
    let currentSiteID = UUID()
    let otherSiteID = UUID()
    let selected = ["中文标签甲", "中文标签乙"]
    let drafts: [(siteProfileID: UUID?, values: [String])] = [
      (siteProfileID: currentSiteID, values: ["Swift", "Alpha"]),
      (siteProfileID: currentSiteID, values: ["Swift", "Beta"]),
      (siteProfileID: currentSiteID, values: ["Swift", "Alpha"]),
      (siteProfileID: otherSiteID, values: ["Aardvark", "外站标签"]),
      (siteProfileID: otherSiteID, values: ["Aardvark"]),
    ]

    let suggestions = TaxonomySuggestionRanking.suggestions(
      selectedValues: selected,
      draftValues: drafts,
      siteProfileID: currentSiteID
    )

    XCTAssertEqual(suggestions, ["中文标签甲", "中文标签乙", "Swift", "Alpha", "Beta"])
  }

  func testCategoriesUseTheSameCurrentSiteFrequencyRules() {
    let currentSiteID = UUID()
    let otherSiteID = UUID()
    let drafts: [(siteProfileID: UUID?, values: [String])] = [
      (siteProfileID: currentSiteID, values: ["Guide", "News"]),
      (siteProfileID: currentSiteID, values: ["guide"]),
      (siteProfileID: currentSiteID, values: ["News"]),
      (siteProfileID: otherSiteID, values: ["Archive"]),
      (siteProfileID: otherSiteID, values: ["Archive"]),
    ]

    let suggestions = TaxonomySuggestionRanking.suggestions(
      selectedValues: [],
      draftValues: drafts,
      siteProfileID: currentSiteID
    )

    XCTAssertEqual(suggestions, ["Guide", "News"])
  }

  @MainActor
  func testVisibleSuggestionsKeepEverySelectionBeforeTheAdditionalLimit() {
    let additional = (1...14).map { String(format: "候选%02d", $0) }

    let visible = TaxonomySuggestionField.visibleSuggestions(
      values: ["中文标签甲", "中文标签乙"],
      suggestions: additional
    )

    XCTAssertEqual(Array(visible.prefix(2)), ["中文标签甲", "中文标签乙"])
    XCTAssertEqual(Array(visible.dropFirst(2)), Array(additional.prefix(12)))
  }
}
