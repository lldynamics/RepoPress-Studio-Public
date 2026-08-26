import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class LocalBPETokenizerTests: XCTestCase {
  func testCl100kOfficialVectors() {
    let tokenizer = LocalBPETokenizer(encoding: .cl100kBase)
    XCTAssertTrue(tokenizer.isExact)
    XCTAssertEqual(tokenizer.encode("hello world"), [15_339, 1_917])
    XCTAssertEqual(
      tokenizer.encode("你好，世界"),
      [57_668, 53_901, 3_922, 3_574, 244, 98_220]
    )
    XCTAssertEqual(tokenizer.tokenCount("👋🌍"), 6)
  }

  func testO200kOfficialVectors() {
    let tokenizer = LocalBPETokenizer(encoding: .o200kBase)
    XCTAssertTrue(tokenizer.isExact)
    XCTAssertEqual(tokenizer.encode("hello world"), [24_912, 2_375])
    XCTAssertEqual(tokenizer.encode("你好，世界"), [177_519, 979, 28_428])
    XCTAssertEqual(tokenizer.encode("👋🌍"), [28_823, 233, 64_364, 235])
  }

  func testMissingResourceUsesConservativeByteUpperBound() {
    let missingURL = URL(fileURLWithPath: "/private/tmp/repopress-missing-tokenizer.tiktoken")
    let tokenizer = LocalBPETokenizer(encoding: .cl100kBase, resourceURL: missingURL)
    let text = "hello 世界 👋"
    XCTAssertFalse(tokenizer.isExact)
    XCTAssertEqual(tokenizer.tokenCount(text), text.utf8.count)
    XCTAssertEqual(tokenizer.precision, .conservativeFallback)
  }

  func testUnknownModelDoesNotGuessAnEncoding() {
    XCTAssertNil(LocalBPETokenizer.encoding(forModel: "codex-default"))
    let tokenizer = LocalBPETokenizer(model: "vendor-private-model")
    XCTAssertNil(tokenizer.encoding)
    XCTAssertFalse(tokenizer.isExact)
    XCTAssertEqual(tokenizer.tokenCount("hello"), 5)
  }

  func testLongRepetitiveTextUsesHeapMergeWithinBound() {
    let tokenizer = LocalBPETokenizer(encoding: .o200kBase)
    let text = String(repeating: "中文内容与重复段落。", count: 4_000)
    measure {
      XCTAssertGreaterThan(tokenizer.tokenCount(text), 0)
    }
  }
}
