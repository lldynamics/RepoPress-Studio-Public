import Foundation
import XCTest

@testable import PersonalSitePublisherMac

final class WorkspaceTopBarPresentationTests: XCTestCase {
  func testDensityUsesTheThreeToolbarWidthBands() {
    XCTAssertEqual(WorkspaceTopBarPresentation.density(for: 1_180), .expanded)
    XCTAssertEqual(WorkspaceTopBarPresentation.density(for: 1_179), .compact)
    XCTAssertEqual(WorkspaceTopBarPresentation.density(for: 960), .compact)
    XCTAssertEqual(WorkspaceTopBarPresentation.density(for: 959), .minimal)
  }

  func testSearchContextCombinesOptionalArticleStatistics() {
    let locale = Locale(identifier: "en_US")
    let complete = WorkspaceTopBarPresentation.ContextStatistics(
      wordCount: 1_260,
      readingMinutes: 6,
      locale: locale
    )
    XCTAssertEqual(
      complete.displayText,
      String(format: "%lld 字 · %lld 分钟阅读", locale: locale, Int64(1_260), Int64(6))
    )
    XCTAssertEqual(
      complete.accessibilityValue,
      String(format: "字数 %lld，预计阅读 %lld 分钟", locale: locale, Int64(1_260), Int64(6))
    )

    XCTAssertEqual(
      WorkspaceTopBarPresentation.ContextStatistics(wordCount: 42, locale: locale).displayText,
      String(format: "%lld 字", locale: locale, Int64(42))
    )
    XCTAssertNil(WorkspaceTopBarPresentation.ContextStatistics().displayText)
  }

  func testSearchContextStatisticsUsesInjectedEnglishAndChineseBundles() throws {
    let englishBundle = try Self.makeLocalizedBundle(
      localization: "en",
      contents: Self.englishStrings
    )
    let chineseBundle = try Self.makeLocalizedBundle(
      localization: "zh-Hans",
      contents: Self.chineseStrings
    )
    defer {
      try? FileManager.default.removeItem(at: englishBundle.bundleURL)
      try? FileManager.default.removeItem(at: chineseBundle.bundleURL)
    }

    let english = WorkspaceTopBarPresentation.ContextStatistics(
      wordCount: 1_260,
      readingMinutes: 6,
      locale: Locale(identifier: "en_US"),
      bundle: englishBundle
    )
    XCTAssertEqual(english.displayText, "1,260 words · 6 min read")
    XCTAssertEqual(
      english.accessibilityValue,
      "1,260 words, estimated reading time 6 min"
    )

    let chinese = WorkspaceTopBarPresentation.ContextStatistics(
      wordCount: 42,
      readingMinutes: 6,
      locale: Locale(identifier: "en_US"),
      bundle: chineseBundle
    )
    XCTAssertEqual(chinese.displayText, "42 字 · 6 分钟阅读")
    XCTAssertEqual(chinese.accessibilityValue, "字数 42，预计阅读 6 分钟")

    let englishWordOnly = WorkspaceTopBarPresentation.ContextStatistics(
      wordCount: 1_260,
      locale: Locale(identifier: "en_US"),
      bundle: englishBundle
    )
    XCTAssertEqual(
      englishWordOnly.displayText,
      "1,260 words"
    )

    let chineseMinutesOnly = WorkspaceTopBarPresentation.ContextStatistics(
      readingMinutes: 6,
      locale: Locale(identifier: "en_US"),
      bundle: chineseBundle
    )
    XCTAssertEqual(
      chineseMinutesOnly.displayText,
      "6 分钟阅读"
    )
  }

  func testSearchWidthsContractAcrossDensities() {
    XCTAssertEqual(WorkspaceTopBarPresentation.searchWidth(for: .expanded), 340)
    XCTAssertEqual(WorkspaceTopBarPresentation.searchWidth(for: .compact), 216)
    XCTAssertEqual(WorkspaceTopBarPresentation.searchWidth(for: .minimal), 32)
  }

  func testPreviewAvailabilityKeepsEachActionStateSeparate() {
    let state = WorkspaceTopBarPresentation.PreviewAvailability(
      isLivePreviewEnabled: true,
      isLivePreviewRunning: true,
      isBrowserPreviewEnabled: false
    )

    XCTAssertEqual(state.livePreviewAccessibilityValue, "正在运行")
    XCTAssertEqual(state.browserPreviewAccessibilityValue, "不可用")
  }

  func testSidebarVisibilityProvidesShownAndHiddenAccessibilitySemantics() {
    XCTAssertEqual(
      WorkspaceTopBarPresentation.SidebarVisibility.visible.accessibilityValue,
      "侧栏已显示"
    )
    XCTAssertEqual(
      WorkspaceTopBarPresentation.SidebarVisibility.hidden.accessibilityValue,
      "侧栏已隐藏"
    )
  }

  private static func makeLocalizedBundle(
    localization: String,
    contents: String
  ) throws -> Bundle {
    let fileManager = FileManager.default
    let bundleURL = fileManager.temporaryDirectory
      .appendingPathComponent("WorkspaceTopBarPresentation-\(UUID().uuidString)")
      .appendingPathExtension("bundle")
    try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    let info: [String: Any] = [
      "CFBundleDevelopmentRegion": localization,
      "CFBundleIdentifier": "com.jinfang.RepoPress.TopBarPresentationTests",
      "CFBundleLocalizations": [localization],
    ]
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try infoData.write(to: bundleURL.appendingPathComponent("Info.plist"))

    try writeStrings(contents, localization: localization, bundleURL: bundleURL)

    guard let bundle = Bundle(path: bundleURL.path) else {
      throw LocalizedBundleFixtureError.unreadableBundle
    }
    return bundle
  }

  private static func writeStrings(
    _ contents: String,
    localization: String,
    bundleURL: URL
  ) throws {
    let localizationURL = bundleURL.appendingPathComponent("\(localization).lproj")
    try FileManager.default.createDirectory(
      at: localizationURL,
      withIntermediateDirectories: true
    )
    try contents.write(
      to: localizationURL.appendingPathComponent("Localizable.strings"),
      atomically: true,
      encoding: .utf8
    )
  }

  private static let englishStrings = """
    \"%lld 字 · %lld 分钟阅读\" = \"%lld words · %lld min read\";
    \"%lld 字\" = \"%lld words\";
    \"%lld 分钟阅读\" = \"%lld min read\";
    \"字数 %lld，预计阅读 %lld 分钟\" = \"%lld words, estimated reading time %lld min\";
    \"字数 %lld\" = \"%lld words\";
    \"预计阅读 %lld 分钟\" = \"Estimated reading time: %lld min\";
    """

  private static let chineseStrings = """
    \"%lld 字 · %lld 分钟阅读\" = \"%lld 字 · %lld 分钟阅读\";
    \"%lld 字\" = \"%lld 字\";
    \"%lld 分钟阅读\" = \"%lld 分钟阅读\";
    \"字数 %lld，预计阅读 %lld 分钟\" = \"字数 %lld，预计阅读 %lld 分钟\";
    \"字数 %lld\" = \"字数 %lld\";
    \"预计阅读 %lld 分钟\" = \"预计阅读 %lld 分钟\";
    """
}

private enum LocalizedBundleFixtureError: Error {
  case unreadableBundle
}
