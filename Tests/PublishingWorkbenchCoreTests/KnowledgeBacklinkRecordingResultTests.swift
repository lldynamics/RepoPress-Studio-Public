import Foundation
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeBacklinkRecordingResultTests: XCTestCase {
  @MainActor
  func testInvalidCitationReturnsFailureWithoutThrowingAwayArticleApplicationResult() async {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-backlink-result-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = KnowledgeStore(service: KnowledgeLibraryService(rootURL: rootURL))
    let target = KnowledgeBacklinkTarget(
      kind: .articleDraft,
      id: UUID().uuidString,
      title: "已写入的文章正文",
      location: "正文"
    )
    let invalidCitation = KnowledgeCitation(
      id: "K1",
      documentID: UUID(),
      revisionID: UUID(),
      chunkID: UUID(),
      title: "不存在的资料",
      excerpt: "此 fixture 故意不导入资料库。"
    )

    let result = await store.recordBacklinks(citations: [invalidCitation], target: target)

    guard case .failed(let message) = result else {
      return XCTFail("Expected a recoverable backlink recording failure")
    }
    XCTAssertFalse(message.isEmpty)
    XCTAssertTrue(store.statusMessage?.contains("资料引用记录未保存") == true)
  }
}
