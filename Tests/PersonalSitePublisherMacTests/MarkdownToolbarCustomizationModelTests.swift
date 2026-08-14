import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownToolbarCustomizationModelTests: XCTestCase {
  func testRoundTripWritesCurrentSchemaAndPreservesOrder() {
    let configuration = MarkdownToolbarConfiguration(
      headerItemIDs: [.saveStatus, .aiChat, .preparePublish],
      formattingItemIDs: [.italic, .heading2, .diagnostics]
    )

    let decoded = MarkdownToolbarConfiguration.decodeFromJSON(configuration.encodeToJSON())

    XCTAssertEqual(decoded.schemaVersion, MarkdownToolbarConfiguration.currentSchemaVersion)
    XCTAssertEqual(decoded.headerItemIDs, [.saveStatus, .aiChat, .preparePublish])
    XCTAssertEqual(decoded.formattingItemIDs, [.italic, .heading2, .diagnostics])
    XCTAssertTrue(configuration.encodeToJSON().contains("\"schemaVersion\":1"))
  }

  func testLegacyUnversionedJSONKeepsKnownHiddenItemsHidden() {
    let legacyJSON = """
      {
        "headerItemIDs": ["saveStatus", "aiChat", "preparePublish"],
        "formattingItemIDs": ["bold", "link"]
      }
      """

    let decoded = MarkdownToolbarConfiguration.decodeFromJSON(legacyJSON)

    XCTAssertEqual(decoded.schemaVersion, MarkdownToolbarConfiguration.currentSchemaVersion)
    XCTAssertEqual(decoded.headerItemIDs, [.saveStatus, .aiChat, .preparePublish])
    XCTAssertEqual(decoded.formattingItemIDs, [.bold, .link])
    XCTAssertFalse(decoded.headerItemIDs.contains(.outline))
    XCTAssertFalse(decoded.formattingItemIDs.contains(.heading1))
  }

  func testNormalizationRemovesDuplicatesAndCrossCategoryItems() {
    let configuration = MarkdownToolbarConfiguration(
      headerItemIDs: [.aiChat, .bold, .aiChat, .preparePublish],
      formattingItemIDs: [.bold, .saveStatus, .bold]
    )

    let normalized = configuration.normalized

    XCTAssertEqual(normalized.headerItemIDs, [.saveStatus, .aiChat, .preparePublish])
    XCTAssertEqual(normalized.formattingItemIDs, [.bold])
  }

  func testNormalizationRestoresMissingMandatoryItemsWithoutReenablingOptionalItems() {
    let configuration = MarkdownToolbarConfiguration(
      headerItemIDs: [.aiChat],
      formattingItemIDs: []
    )

    let normalized = configuration.normalized

    XCTAssertEqual(normalized.headerItemIDs, [.saveStatus, .aiChat, .preparePublish])
    XCTAssertTrue(normalized.headerItemIDs.contains(.saveStatus))
    XCTAssertTrue(normalized.headerItemIDs.contains(.preparePublish))
    XCTAssertEqual(normalized.formattingItemIDs, [])
  }

  func testUnknownFutureItemsAreIgnoredWhileKnownChoicesSurvive() {
    let futureJSON = """
      {
        "schemaVersion": 99,
        "headerItemIDs": ["saveStatus", "futureHeaderAction", "preparePublish"],
        "formattingItemIDs": ["futureFormattingAction", "italic"]
      }
      """

    let decoded = MarkdownToolbarConfiguration.decodeFromJSON(futureJSON)

    XCTAssertEqual(decoded.headerItemIDs, [.saveStatus, .preparePublish])
    XCTAssertEqual(decoded.formattingItemIDs, [.italic])
  }

  func testCorruptJSONFallsBackToDefaultConfiguration() {
    let decoded = MarkdownToolbarConfiguration.decodeFromJSON("not-json")

    XCTAssertEqual(decoded, .defaultConfiguration)
  }
}
