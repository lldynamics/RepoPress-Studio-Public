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
  func testSelectedValuesAndAdditionalSuggestionsDoNotOverlap() {
    let additional = (1...14).map { String(format: "候选%02d", $0) }

    let selected = TaxonomySuggestionField.selectedValues(["中文标签甲", "中文标签乙", "中文标签甲"])
    let offered = TaxonomySuggestionField.additionalSuggestions(
      values: ["中文标签甲", "中文标签乙"],
      suggestions: ["中文标签乙"] + additional
    )

    XCTAssertEqual(selected, ["中文标签甲", "中文标签乙"])
    XCTAssertEqual(offered, Array(additional.prefix(12)))
  }
}
