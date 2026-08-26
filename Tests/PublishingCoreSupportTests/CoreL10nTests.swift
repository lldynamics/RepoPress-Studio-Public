import Foundation
import XCTest

@testable import PublishingCoreSupport

final class CoreL10nTests: XCTestCase {
  func testModuleResourcesResolveChineseAndEnglish() {
    XCTAssertEqual(
      CoreL10n.text("标题为空", locale: Locale(identifier: "zh-Hans")),
      "标题为空"
    )
    XCTAssertEqual(
      CoreL10n.text("标题为空", locale: Locale(identifier: "en")),
      "Missing title"
    )
  }

  func testChineseLocalePrefixUsesSimplifiedChineseResource() {
    XCTAssertEqual(
      CoreL10n.text("标题为空", locale: Locale(identifier: "zh-CN")),
      "标题为空"
    )
  }

  func testNonChineseLocaleUsesEnglishResource() {
    XCTAssertEqual(
      CoreL10n.text("标题为空", locale: Locale(identifier: "fr-FR")),
      "Missing title"
    )
  }

  func testFormatPreservesStringAndIntegerArguments() {
    XCTAssertEqual(
      CoreL10n.format(
        "%@ 已被另一篇草稿占用。",
        locale: Locale(identifier: "en"),
        arguments: ["content/post.md"]
      ),
      "content/post.md is already used by another draft."
    )
    XCTAssertEqual(
      CoreL10n.format(
        "已校验 %d 个自动备份；%d 个校验失败",
        locale: Locale(identifier: "en"),
        arguments: [3, 1]
      ),
      "Validated 3 automatic backups; 1 failed validation."
    )
  }

  func testUnknownKeyFallsBackToSourceKey() {
    let key = "__publishing_core_support_missing_key__"
    XCTAssertEqual(CoreL10n.text(key, locale: Locale(identifier: "en")), key)
  }

  func testAIEndpointNamesResolveChineseAndEnglishResources() {
    XCTAssertEqual(
      CoreL10n.text("OpenAI 兼容", locale: Locale(identifier: "zh-Hans")),
      "开放AI兼容接口"
    )
    XCTAssertEqual(
      CoreL10n.text("OpenAI 兼容", locale: Locale(identifier: "en")),
      "OpenAI-compatible endpoint"
    )
    XCTAssertEqual(
      CoreL10n.text("自定义云端接口", locale: Locale(identifier: "en")),
      "Custom cloud endpoint"
    )
  }
}
