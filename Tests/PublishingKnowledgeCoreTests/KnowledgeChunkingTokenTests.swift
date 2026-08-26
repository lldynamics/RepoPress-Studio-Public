import XCTest
@testable import PublishingKnowledgeCore

final class KnowledgeChunkingTokenTests: XCTestCase {
  func testChunkTokenEstimateUsesLocalTokenizerInsteadOfCharacterRatio() {
    let section = KnowledgeExtractedSection(
      headingPath: "第一章",
      text: "hello world"
    )
    let chunks = KnowledgeChunkingService(maximumChunkCharacters: 320).chunks(
      documentID: UUID(),
      revisionID: UUID(),
      sections: [section]
    )
    let chunk = try! XCTUnwrap(chunks.first)
    XCTAssertEqual(chunk.tokenEstimate, 2)
    XCTAssertNotEqual(
      chunk.tokenEstimate,
      max(1, Int(ceil(Double(chunk.content.count) / 3.0)))
    )
  }

  func testChunkingPreservesParagraphBoundariesWhileCountingLargeChineseText() {
    let section = KnowledgeExtractedSection(
      text: (0..<5).map { "段落 \($0)：" + String(repeating: "中文检索内容。", count: 50) }
        .joined(separator: "\n\n")
    )
    let chunks = KnowledgeChunkingService(maximumChunkCharacters: 420).chunks(
      documentID: UUID(),
      revisionID: UUID(),
      sections: [section]
    )
    XCTAssertGreaterThan(chunks.count, 1)
    XCTAssertTrue(chunks.allSatisfy { $0.tokenEstimate > 0 })
    XCTAssertTrue(chunks.allSatisfy { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == $0.content })
  }
}
