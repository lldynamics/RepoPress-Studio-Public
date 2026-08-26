import Foundation
import XCTest
@testable import PublishingWorkbenchCore

#if DEBUG
@MainActor
final class RepositoryImportBackgroundTests: XCTestCase {
  func testLocalImportUsesOneRemoteBatchAndParsesBaselinesOffMainActor() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let parseProbe = ImportThreadProbe()
    let importService = LocalContentImportService(
      fileManager: .default,
      contentIndexDirectoryURL: nil,
      isContentIndexEnabled: false,
      frontMatterParseObserver: { parseProbe.record() },
      imageReferenceScanObserver: nil
    )
    let store = try makeStore(importService: importService)
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.contentRoot = "content"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    _ = profile.rememberLocalRepositoryRoot(fixture.rootURL)
    store.updateActiveProfile(profile)

    let batchProbe = RemoteSnapshotProbe()
    store.repositoryStore.remoteFileSnapshotTestHook = {
      await batchProbe.record()
    }
    let summary = await store.importDraftsFromLocalRepositoryAsync()
    store.repositoryStore.remoteFileSnapshotTestHook = nil

    XCTAssertEqual(summary.insertedCount, 1)
    XCTAssertEqual(summary.updatedCount, 0)
    let batchInvocationCount = await batchProbe.count
    XCTAssertEqual(batchInvocationCount, 1)
    XCTAssertGreaterThanOrEqual(parseProbe.totalCount, 2)
    XCTAssertEqual(parseProbe.mainThreadCount, 0)
    let imported = try XCTUnwrap(
      store.drafts.first { $0.repositoryPath == fixture.articlePath }
    )
    XCTAssertEqual(imported.repositorySHA, fixture.remoteBlobSHA)
    XCTAssertNotNil(imported.repositoryImportFingerprint)
  }

  func testLocalImportDropsBatchResultWhenRepositoryProfileDrifts() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let store = try makeStore(importService: LocalContentImportService(isContentIndexEnabled: false))
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.contentRoot = "content"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    _ = profile.rememberLocalRepositoryRoot(fixture.rootURL)
    store.updateActiveProfile(profile)

    let gate = RemoteSnapshotGate()
    store.repositoryStore.remoteFileSnapshotTestHook = {
      await gate.waitUntilReleased()
    }
    let importTask = Task { @MainActor in
      await store.importDraftsFromLocalRepositoryAsync()
    }
    for _ in 0..<100 {
      if await gate.hasEntered { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let didEnter = await gate.hasEntered
    XCTAssertTrue(didEnter)

    let changedRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "RepositoryImportProfileDrift-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: changedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: changedRoot) }
    var changedProfile = store.activeProfile
    _ = changedProfile.rememberLocalRepositoryRoot(changedRoot)
    store.updateActiveProfile(changedProfile)

    await gate.release()
    let summary = await importTask.value
    store.repositoryStore.remoteFileSnapshotTestHook = nil

    XCTAssertEqual(summary.changedCount, 0)
    XCTAssertFalse(store.drafts.contains { $0.repositoryPath == fixture.articlePath })
  }

  func testLocalImportCancellationDoesNotPublishHydratedDrafts() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let store = try makeStore(importService: LocalContentImportService(isContentIndexEnabled: false))
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.contentRoot = "content"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    _ = profile.rememberLocalRepositoryRoot(fixture.rootURL)
    store.updateActiveProfile(profile)

    let gate = RemoteSnapshotGate()
    store.repositoryStore.remoteFileSnapshotTestHook = {
      await gate.waitUntilReleased()
    }
    let importTask = Task { @MainActor in
      await store.importDraftsFromLocalRepositoryAsync()
    }
    for _ in 0..<100 {
      if await gate.hasEntered { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let didEnter = await gate.hasEntered
    XCTAssertTrue(didEnter)

    importTask.cancel()
    await gate.release()
    let summary = await importTask.value
    store.repositoryStore.remoteFileSnapshotTestHook = nil

    XCTAssertEqual(summary.changedCount, 0)
    XCTAssertFalse(store.drafts.contains { $0.repositoryPath == fixture.articlePath })
  }

  private func makeStore(importService: LocalContentImportService) throws -> WorkbenchStore {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepositoryImportBackground-\(UUID().uuidString).json")
    return WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      safeMode: true,
      localContentImportService: importService
    )
  }

  private func makeFixture() throws -> RepositoryImportFixture {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepositoryImportFixture-\(UUID().uuidString)", isDirectory: true)
    let contentURL = rootURL.appendingPathComponent("content/posts", isDirectory: true)
    try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true)
    _ = try git(["init", "-b", "main"], rootURL: rootURL)
    _ = try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    _ = try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(
      to: rootURL.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["add", "README.md"], rootURL: rootURL)
    _ = try git(["commit", "-m", "Initial"], rootURL: rootURL)

    let articlePath = "content/posts/background-import.md"
    _ = try git(["switch", "-c", "remote-work"], rootURL: rootURL)
    try """
    ---
    title: "Remote baseline"
    slug: background-import
    ---

    Remote baseline body.
    """.write(
      to: rootURL.appendingPathComponent(articlePath),
      atomically: true,
      encoding: .utf8
    )
    _ = try git(["add", articlePath], rootURL: rootURL)
    _ = try git(["commit", "-m", "Remote article"], rootURL: rootURL)
    let remoteCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)
    let remoteBlobSHA = try git(
      ["rev-parse", "\(remoteCommit):\(articlePath)"],
      rootURL: rootURL
    )

    _ = try git(["switch", "main"], rootURL: rootURL)
    _ = try git(["remote", "add", "origin", "https://example.invalid/site.git"], rootURL: rootURL)
    _ = try git(["update-ref", "refs/remotes/origin/main", remoteCommit], rootURL: rootURL)
    _ = try git(["config", "branch.main.remote", "origin"], rootURL: rootURL)
    _ = try git(["config", "branch.main.merge", "refs/heads/main"], rootURL: rootURL)
    // Git removes the now-empty content directory when switching back to the
    // main branch, so recreate it before writing the local working-tree copy.
    try FileManager.default.createDirectory(at: contentURL, withIntermediateDirectories: true)
    try """
    ---
    title: "Local article"
    slug: background-import
    ---

    Local working tree body.
    """.write(
      to: rootURL.appendingPathComponent(articlePath),
      atomically: true,
      encoding: .utf8
    )

    return RepositoryImportFixture(
      rootURL: rootURL,
      articlePath: articlePath,
      remoteBlobSHA: remoteBlobSHA
    )
  }

  @discardableResult
  private func git(_ arguments: [String], rootURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", rootURL.path] + arguments
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let output = String(
      data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
    let error = String(
      data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositoryImportBackgroundTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: output + error]
      )
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private struct RepositoryImportFixture {
  let rootURL: URL
  let articlePath: String
  let remoteBlobSHA: String
}

private final class ImportThreadProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var total = 0
  private var main = 0

  func record() {
    lock.lock()
    total += 1
    if Thread.isMainThread {
      main += 1
    }
    lock.unlock()
  }

  var totalCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return total
  }

  var mainThreadCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return main
  }
}

private actor RemoteSnapshotProbe {
  private var invocations = 0

  func record() {
    invocations += 1
  }

  var count: Int { invocations }
}

private actor RemoteSnapshotGate {
  private(set) var hasEntered = false
  private var continuation: CheckedContinuation<Void, Never>?

  func waitUntilReleased() async {
    hasEntered = true
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}
#endif
