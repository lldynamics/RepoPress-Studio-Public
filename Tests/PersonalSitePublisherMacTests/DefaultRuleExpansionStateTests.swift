import XCTest
@testable import PersonalSitePublisherMac

final class DefaultRuleExpansionStateTests: XCTestCase {
  func testOptionalRuleSectionsStartCollapsed() {
    let state = DefaultRuleExpansionState()

    XCTAssertFalse(state.advancedFrontMatter)
    XCTAssertFalse(state.frontMatterPreview)
    XCTAssertFalse(state.pathRules)
  }

  func testStructuredPathDestinationRevealsOnlyPathRules() {
    var state = DefaultRuleExpansionState()

    state.revealPathRules(
      for: .rules(.paths),
      legacyHealthDestination: nil
    )

    XCTAssertTrue(state.pathRules)
    XCTAssertFalse(state.advancedFrontMatter)
    XCTAssertFalse(state.frontMatterPreview)
  }

  func testLegacyHealthDestinationStillRevealsPathRules() {
    var state = DefaultRuleExpansionState()

    state.revealPathRules(
      for: nil,
      legacyHealthDestination: .defaultRules
    )

    XCTAssertTrue(state.pathRules)
  }

  func testTopLevelRulesDestinationDoesNotForceExpansion() {
    var state = DefaultRuleExpansionState()

    state.revealPathRules(
      for: .tab(.defaultRules),
      legacyHealthDestination: nil
    )

    XCTAssertFalse(state.advancedFrontMatter)
    XCTAssertFalse(state.frontMatterPreview)
    XCTAssertFalse(state.pathRules)
  }
}
