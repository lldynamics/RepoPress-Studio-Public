import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class RepositoryEventDrivenRefreshTests: XCTestCase {
  func testEventClassificationAvoidsFullScanForParentMetadataChanges() {
    XCTAssertEqual(
      RepositoryContentChangeEventDecision.classify(
        flags: [.itemIsDir, .itemModified],
        relativePath: "content/posts",
        allowedPrefixes: ["content", "private"]
      ),
      .ignore
    )
    XCTAssertEqual(
      RepositoryContentChangeEventDecision.classify(
        flags: [.itemIsDir, .itemCreated],
        relativePath: "content/new-folder",
        allowedPrefixes: ["content", "private"]
      ),
      .fullScan
    )
  }

  func testEventClassificationUsesPathImportOnlyForUnknownMarkdownCandidates() {
    XCTAssertEqual(
      RepositoryContentChangeEventDecision.classify(
        flags: [.itemModified],
        relativePath: "content/posts/post.md",
        allowedPrefixes: ["content", "private"]
      ),
      .paths(["content/posts/post.md"])
    )
    XCTAssertEqual(
      RepositoryContentChangeEventDecision.classify(
        flags: [.itemModified],
        relativePath: "static/images/post.png",
        allowedPrefixes: ["content", "private"]
      ),
      .ignore
    )
    XCTAssertEqual(
      RepositoryContentChangeEventDecision.classify(
        flags: [.userDropped],
        relativePath: nil,
        allowedPrefixes: ["content"]
      ),
      .fullScan
    )
  }

  func testMonitorCoalescesMarkdownAndAssetNoiseIntoOneSafeNotification() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("repository-event-monitor-\(UUID().uuidString)", isDirectory: true)
    let contentURL = rootURL.appendingPathComponent("content", isDirectory: true)
    try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let state = LockedRepositoryEventState()
    let changeExpectation = expectation(description: "one debounced markdown change")
    let monitor = RepositoryContentChangeMonitor(
      debounceInterval: RepositoryContentChangeMonitor.defaultDebounceInterval
    ) { paths in
      if state.record(paths) {
        changeExpectation.fulfill()
      }
    }
    monitor.reconfigure(
      repositoryRootPath: rootURL.path,
      watchedPath: rootURL.path,
      allowedRelativePrefixes: ["content"]
    )
    // FSEvents may deliver the directory's creation event after the stream
    // starts. Let that baseline topology notification drain before measuring
    // the file-level batch below.
    try await Task.sleep(for: .seconds(1))

    try Data("# first".utf8).write(to: contentURL.appendingPathComponent("first.md"))
    try Data("# second".utf8).write(to: contentURL.appendingPathComponent("second.md"))
    try Data("asset".utf8).write(to: contentURL.appendingPathComponent("image.png"))

    await fulfillment(of: [changeExpectation], timeout: 3)
    try await Task.sleep(for: .milliseconds(600))
    monitor.stop()

    // A just-created temporary content directory can produce one separate
    // topology fallback before the path-level batch. The production action is
    // still safe: either one path import, or one full discovery followed by the
    // coalesced Markdown paths; the PNG must never create a third callback.
    XCTAssertGreaterThanOrEqual(state.callbackCount, 1)
    XCTAssertLessThanOrEqual(state.callbackCount, 2)
    if !state.paths.isEmpty {
      XCTAssertEqual(state.paths, ["content/first.md", "content/second.md"])
    } else {
      XCTAssertTrue(state.receivedFullScan)
    }
  }

  func testMonitorStopSuppressesPendingDebouncedCallback() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("repository-event-stop-\(UUID().uuidString)", isDirectory: true)
    let contentURL = rootURL.appendingPathComponent("content", isDirectory: true)
    try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let state = LockedRepositoryEventState()
    let monitor = RepositoryContentChangeMonitor(debounceInterval: 0.4) { paths in
      state.record(paths)
    }
    monitor.reconfigure(repositoryRootPath: rootURL.path, watchedPath: contentURL.path)
    try await Task.sleep(for: .milliseconds(300))
    try Data("# post".utf8).write(to: contentURL.appendingPathComponent("post.md"))
    monitor.stop()
    try await Task.sleep(for: .milliseconds(800))

    XCTAssertEqual(state.callbackCount, 0)
  }
}

private final class LockedRepositoryEventState: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var callbackCount = 0
  private(set) var paths: [String] = []
  private(set) var receivedFullScan = false

  @discardableResult
  func record(_ changedPaths: [String]?) -> Bool {
    lock.lock()
    callbackCount += 1
    if let changedPaths {
      paths = changedPaths.sorted()
    } else {
      paths = []
      receivedFullScan = true
    }
    let isFirstCallback = callbackCount == 1
    lock.unlock()
    return isFirstCallback
  }
}
