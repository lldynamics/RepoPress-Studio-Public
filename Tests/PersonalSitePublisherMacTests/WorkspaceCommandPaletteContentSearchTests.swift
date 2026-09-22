import Foundation
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingKnowledgeCore

@MainActor
final class WorkspaceCommandPaletteContentSearchTests: XCTestCase {
  func testSupersededQueryCannotReplaceNewerResults() async throws {
    let oldResult = makeKnowledgeResult(title: "旧查询")
    let newResult = makeKnowledgeResult(title: "新查询")
    let controller = WorkspaceCommandPaletteContentSearch(
      knowledgeSearch: { _, query, _ in
        if query == "旧" {
          // A storage query can finish after its caller is cancelled. The
          // controller must still suppress that late result.
          try? await Task.sleep(for: .milliseconds(300))
          return [oldResult]
        }
        return [newResult]
      },
      rssSearch: { _, _, _ in [] }
    )
    let (knowledge, rssStore, rootURL) = try makeStores()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    controller.update(query: "旧", scope: .resources, knowledge: knowledge, rssStore: rssStore)
    try await Task.sleep(for: .milliseconds(210))
    controller.update(query: "新", scope: .resources, knowledge: knowledge, rssStore: rssStore)
    try await Task.sleep(for: .milliseconds(250))

    XCTAssertEqual(controller.knowledgeResults.map(\.document.title), ["新查询"])
    XCTAssertEqual(controller.state, .ready)
  }

  func testScopeAndEmptyQueryControlWhichPersistentSourceIsRead() async throws {
    var requestedSources: [String] = []
    let controller = WorkspaceCommandPaletteContentSearch(
      knowledgeSearch: { _, _, _ in
        requestedSources.append("knowledge")
        return []
      },
      rssSearch: { _, _, _ in
        requestedSources.append("rss")
        return []
      }
    )
    let (knowledge, rssStore, rootURL) = try makeStores()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    controller.update(query: "   ", scope: .all, knowledge: knowledge, rssStore: rssStore)
    XCTAssertTrue(requestedSources.isEmpty)

    controller.update(query: "资料", scope: .resources, knowledge: knowledge, rssStore: rssStore)
    try await Task.sleep(for: .milliseconds(220))
    XCTAssertEqual(requestedSources, ["knowledge"])

    controller.update(query: "RSS", scope: .rss, knowledge: knowledge, rssStore: rssStore)
    try await Task.sleep(for: .milliseconds(220))
    XCTAssertEqual(requestedSources, ["knowledge", "rss"])
  }

  private func makeStores() throws -> (KnowledgeStore, RSSReaderStore, URL) {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("palette-controller-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return (
      KnowledgeStore(
        service: KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))),
      RSSReaderStore(fileURL: rootURL.appendingPathComponent("reader.sqlite")),
      rootURL
    )
  }

  private func makeKnowledgeResult(title: String) -> KnowledgeSearchResult {
    let revisionID = UUID()
    let document = KnowledgeDocument(
      kind: .text,
      title: title,
      currentRevisionID: revisionID
    )
    let chunk = KnowledgeChunk(
      documentID: document.id,
      revisionID: revisionID,
      ordinal: 0,
      content: title,
      tokenEstimate: 1,
      contentHash: "test"
    )
    return KnowledgeSearchResult(
      document: document,
      chunk: chunk,
      score: 1,
      signals: [.fullText]
    )
  }
}
