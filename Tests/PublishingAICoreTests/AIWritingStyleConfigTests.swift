import XCTest

@testable import PublishingAICore

final class AIWritingStyleConfigTests: XCTestCase {
  func testDecodesLegacyConfigWithoutTerminologyFields() throws {
    let data = try XCTUnwrap(
      """
      {"preset":"technicalNote","tone":"准确","audience":"开发者","summaryGuidance":"摘要","tagGuidance":"标签","seoGuidance":"SEO"}
      """.data(using: .utf8)
    )

    let decoded = try JSONDecoder().decode(AIWritingStyleConfig.self, from: data)

    XCTAssertEqual(decoded.preset, .technicalNote)
    XCTAssertEqual(decoded.preferredTerminology, [])
    XCTAssertEqual(decoded.avoidedExpressions, [])
    XCTAssertEqual(decoded.exemplarArticleIDs, [])
  }

  func testDecodesLegacyJinfangZolaPresetAsTechnicalNoteAndPreservesRules() throws {
    let data = try XCTUnwrap(
      """
      {
        "preset":"jinfangZola",
        "tone":"保留的语气",
        "audience":"保留的读者",
        "summaryGuidance":"保留的摘要规则",
        "tagGuidance":"保留的标签规则",
        "seoGuidance":"保留的 SEO 规则",
        "preferredTerminology":["RepoPress Studio"],
        "avoidedExpressions":["赋能"]
      }
      """.data(using: .utf8)
    )

    let decoded = try JSONDecoder().decode(AIWritingStyleConfig.self, from: data)

    XCTAssertEqual(decoded.preset, .technicalNote)
    XCTAssertEqual(decoded.tone, "保留的语气")
    XCTAssertEqual(decoded.audience, "保留的读者")
    XCTAssertEqual(decoded.summaryGuidance, "保留的摘要规则")
    XCTAssertEqual(decoded.tagGuidance, "保留的标签规则")
    XCTAssertEqual(decoded.seoGuidance, "保留的 SEO 规则")
    XCTAssertEqual(decoded.preferredTerminology, ["RepoPress Studio"])
    XCTAssertEqual(decoded.avoidedExpressions, ["赋能"])
    XCTAssertEqual(
      try JSONDecoder().decode(String.self, from: JSONEncoder().encode(decoded.preset)),
      "technicalNote"
    )
  }

  func testDefaultPresetIsTechnicalNote() {
    XCTAssertEqual(AIWritingStyleConfig().preset, .technicalNote)
    XCTAssertEqual(AIWritingStyleConfig.default.preset, .technicalNote)
  }

  func testPresetDoesNotErasePersonalTerminology() {
    var style = AIWritingStyleConfig(
      preferredTerminology: ["RepoPress Studio"],
      avoidedExpressions: ["赋能"]
    )

    style.applyPreset(.technicalNote)

    XCTAssertEqual(style.preferredTerminology, ["RepoPress Studio"])
    XCTAssertEqual(style.avoidedExpressions, ["赋能"])
    XCTAssertTrue(style.promptInstructions.contains("优先使用术语：RepoPress Studio"))
    XCTAssertTrue(style.promptInstructions.contains("避免表达：赋能"))
  }

  func testTerminologyIsBoundedAndDeduplicated() {
    let longTerm = String(repeating: "术", count: 100)
    let style = AIWritingStyleConfig(
      preferredTerminology: Array(repeating: "RepoPress", count: 3) + [longTerm]
        + (0..<30).map { "术语\($0)" }
    )

    XCTAssertLessThanOrEqual(
      style.preferredTerminology.count, AIWritingStyleConfig.maximumTerminologyCount)
    XCTAssertEqual(style.preferredTerminology.filter { $0 == "RepoPress" }.count, 1)
    XCTAssertLessThanOrEqual(
      style.preferredTerminology.first(where: { $0.hasPrefix("术") })?.count ?? 0,
      AIWritingStyleConfig.maximumTerminologyCharacterCount
    )
  }
}
