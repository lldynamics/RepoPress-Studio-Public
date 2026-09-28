import Foundation
import PublishingCoreSupport
import PublishingTestSupport
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingKnowledgeCore

@MainActor
final class WorkspaceCommandPaletteContentSearchTests: XCTestCase {
  func testSupersededQueryCannotReplaceNewerResults() async throws {
    let oldResult = makeKnowledgeResult(title: "旧查询")
    let newResult = makeKnowledgeResult(title: "新查询")
    let clock = ManualClock()
    let oldSearch = ContentSearchGate()
    let controller = WorkspaceCommandPaletteContentSearch(
      knowledgeSearch: { _, query, _ in
        if query == "旧" {
          // A storage query can finish after its caller is cancelled. The
          // controller must still suppress that late result.
          await oldSearch.wait()
          return [oldResult]
        }
        return [newResult]
      },
      rssSearch: { _, _, _ in [] },
      clock: clock
    )
    let (knowledge, rssStore, rootURL) = try makeStores()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let oldTask = try XCTUnwrap(
      controller.update(
        query: "旧", scope: .resources, moduleVisibility: .init(), knowledge: knowledge,
        rssStore: rssStore))
    await clock.waitForSleepCount(1)
    clock.advance(by: DebounceIntervals.commandPaletteContent - .milliseconds(1))
    XCTAssertEqual(controller.state, .searching)
    clock.advance(by: .milliseconds(1))
    await oldSearch.waitUntilEntered()
    let newTask = try XCTUnwrap(
      controller.update(
        query: "新", scope: .resources, moduleVisibility: .init(), knowledge: knowledge,
        rssStore: rssStore))
    await clock.waitForSleepCount(2)
    clock.advance(by: DebounceIntervals.commandPaletteContent)
    await newTask.value

    XCTAssertEqual(controller.knowledgeResults.map(\.document.title), ["新查询"])
    XCTAssertEqual(controller.state, .ready)
    await oldSearch.release()
    await oldTask.value
    XCTAssertEqual(controller.knowledgeResults.map(\.document.title), ["新查询"])
  }

  func testScopeAndEmptyQueryControlWhichPersistentSourceIsRead() async throws {
    var requestedSources: [String] = []
    let clock = ManualClock()
    let controller = WorkspaceCommandPaletteContentSearch(
      knowledgeSearch: { _, _, _ in
        requestedSources.append("knowledge")
        return []
      },
      rssSearch: { _, _, _ in
        requestedSources.append("rss")
        return []
      },
      clock: clock
    )
    let (knowledge, rssStore, rootURL) = try makeStores()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    controller.update(
      query: "   ", scope: .all, moduleVisibility: .init(), knowledge: knowledge,
      rssStore: rssStore)
    XCTAssertTrue(requestedSources.isEmpty)

    let knowledgeTask = try XCTUnwrap(
      controller.update(
        query: "资料", scope: .resources, moduleVisibility: .init(), knowledge: knowledge,
        rssStore: rssStore))
    await clock.waitForSleepCount(1)
    clock.advance(by: DebounceIntervals.commandPaletteContent)
    await knowledgeTask.value
    XCTAssertEqual(requestedSources, ["knowledge"])

    let rssTask = try XCTUnwrap(
      controller.update(
        query: "RSS", scope: .rss, moduleVisibility: .init(), knowledge: knowledge,
        rssStore: rssStore))
    await clock.waitForSleepCount(2)
    clock.advance(by: DebounceIntervals.commandPaletteContent)
    await rssTask.value
    XCTAssertEqual(requestedSources, ["knowledge", "rss"])
  }

  func testDisabledModulesAreNeverQueriedOrAllowedToPublishStaleResults() async throws {
    var requestedSources: [String] = []
    let clock = ManualClock()
    let rssSearch = ContentSearchGate()
    let controller = WorkspaceCommandPaletteContentSearch(
      knowledgeSearch: { _, _, _ in
        requestedSources.append("knowledge")
        return []
      },
      rssSearch: { _, _, _ in
        requestedSources.append("rss")
        await rssSearch.wait()
        return []
      },
      clock: clock
    )
    let (knowledge, rssStore, rootURL) = try makeStores()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let oldTask = try XCTUnwrap(
      controller.update(
        query: "RSS", scope: .rss, moduleVisibility: .init(), knowledge: knowledge,
        rssStore: rssStore))
    await clock.waitForSleepCount(1)
    clock.advance(by: DebounceIntervals.commandPaletteContent)
    await rssSearch.waitUntilEntered()
    controller.update(
      query: "RSS", scope: .rss,
      moduleVisibility: .init(rssEnabled: false), knowledge: knowledge, rssStore: rssStore)
    await rssSearch.release()
    await oldTask.value

    XCTAssertEqual(requestedSources, ["rss"])
    XCTAssertTrue(controller.rssResults.isEmpty)
    XCTAssertEqual(controller.state, .idle)
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

private actor ContentSearchGate {
  private var entered = false
  private var entryWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  func wait() async {
    entered = true
    entryWaiter?.resume()
    entryWaiter = nil
    await withCheckedContinuation { releaseWaiter = $0 }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { entryWaiter = $0 }
  }

  func release() {
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}
