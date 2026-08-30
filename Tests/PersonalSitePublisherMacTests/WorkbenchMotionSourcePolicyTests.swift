import Foundation
import XCTest

/// Keeps the whole app target free of motion that bypasses `WorkbenchMotion`.
/// Tests live outside the scanned source root, so the patterns below cannot
/// match their own string literals.
final class WorkbenchMotionSourcePolicyTests: XCTestCase {
  func testAppSourcesContainNoUnscopedMotionOrSmoothWebScrolling() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceRoot =
      repositoryRoot
      .appendingPathComponent("Sources/PersonalSitePublisherMac", isDirectory: true)
    let sourceURLs = try XCTUnwrap(
      FileManager.default.enumerator(
        at: sourceRoot,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    )
    .compactMap { $0 as? URL }
    .filter { $0.pathExtension == "swift" }
    .sorted { $0.path < $1.path }

    let forbiddenPatterns = [
      #"\bwithAnimation\s*\{"#,
      #"\brepeatForever\s*\("#,
      #"\bNSAnimationContext\s*\.\s*runAnimationGroup\b"#,
      #"\bAnimation\s*\."#,
      #"behavior\s*:\s*['\"]smooth['\"]"#,
    ]

    for sourceURL in sourceURLs {
      let relativePath = sourceURL.path.replacingOccurrences(
        of: repositoryRoot.path + "/",
        with: ""
      )
      let source = try String(contentsOf: sourceURL, encoding: .utf8)
      for pattern in forbiddenPatterns {
        XCTAssertNil(
          source.range(of: pattern, options: .regularExpression),
          "Unexpected motion policy escape in \(relativePath): \(pattern)"
        )
      }
    }
  }
}
