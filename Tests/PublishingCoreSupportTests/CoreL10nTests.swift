import Foundation
import XCTest
import os

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

  func testLocalizationIsFoundInFlatAndStandardBundleLayouts() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("core-l10n-layouts-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // The native SwiftPM driver writes a flat bundle with lowercased folder
    // names; Swift Build and packaged apps write Contents/Resources.
    let layouts = [
      ("Flat.bundle", "", "zh-hans.lproj"),
      ("Standard.bundle", "Contents/Resources", "zh-Hans.lproj"),
    ]
    for (name, resources, chineseFolder) in layouts {
      let bundleURL = root.appendingPathComponent(name, isDirectory: true)
      let resourceURL =
        resources.isEmpty
        ? bundleURL : bundleURL.appendingPathComponent(resources, isDirectory: true)
      if !resources.isEmpty {
        try FileManager.default.createDirectory(
          at: bundleURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(
          #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.layout</string></dict></plist>"#
            .utf8
        ).write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
      }
      for (folder, value) in [("en.lproj", "Missing title"), (chineseFolder, "标题为空")] {
        let folderURL = resourceURL.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("\"标题为空\" = \"\(value)\";\n".utf8)
          .write(to: folderURL.appendingPathComponent("Localizable.strings"))
      }
      let bundle = try XCTUnwrap(Bundle(url: bundleURL), name)
      for (language, expected) in [("en", "Missing title"), ("zh-Hans", "标题为空")] {
        let localization = try XCTUnwrap(
          CoreL10n.localization(language, in: bundle), "\(name) \(language)")
        XCTAssertEqual(
          localization.localizedString(forKey: "标题为空", value: nil, table: nil), expected,
          "\(name) \(language)")
      }
    }
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

  func testExplicitLocaleResolutionCanAlternateAcrossConcurrentReads() {
    let failures = ConcurrentReadFailures()

    DispatchQueue.concurrentPerform(iterations: 128) { index in
      let isChinese = index.isMultiple(of: 2)
      let locale = Locale(identifier: isChinese ? "zh-CN" : "en-US")
      let expected = isChinese ? "标题为空" : "Missing title"
      let value = CoreL10n.text("标题为空", locale: locale)
      if value != expected {
        failures.append("text[\(index)] = \(value)")
      }

      let formatted = CoreL10n.format(
        "%@ 已被另一篇草稿占用。",
        locale: locale,
        arguments: ["content/post.md"]
      )
      let expectedFormatted =
        isChinese
        ? "content/post.md 已被另一篇草稿占用。"
        : "content/post.md is already used by another draft."
      if formatted != expectedFormatted {
        failures.append("format[\(index)] = \(formatted)")
      }
    }

    XCTAssertTrue(failures.isEmpty, failures.values.joined(separator: "; "))
  }
}

private final class ConcurrentReadFailures: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: [String]())

  var values: [String] {
    state.withLock { $0 }
  }

  var isEmpty: Bool {
    state.withLock { $0.isEmpty }
  }

  func append(_ value: String) {
    state.withLock { $0.append(value) }
  }
}
