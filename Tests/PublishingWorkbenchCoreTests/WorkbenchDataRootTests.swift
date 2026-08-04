import Foundation
import Testing

@testable import PublishingWorkbenchCore

struct WorkbenchDataRootTests {
  @Test
  func layoutUsesOneExplicitRootForAllDurableComponents() {
    let rootURL = URL(fileURLWithPath: "/tmp/repopress-data", isDirectory: true)
    let layout = WorkbenchDataRootLayout(rootURL: rootURL)

    #expect(layout.manifestURL.path == "/tmp/repopress-data/repopress-data-root.json")
    #expect(layout.workbenchFileURL.path == "/tmp/repopress-data/workbench.json")
    #expect(layout.knowledgeLibraryURL.path == "/tmp/repopress-data/KnowledgeLibrary")
    #expect(layout.knowledgeDatabaseURL.path == "/tmp/repopress-data/KnowledgeLibrary/library.sqlite")
    #expect(layout.rssReaderDatabaseURL.path == "/tmp/repopress-data/RSSReader/reader.sqlite")
    #expect(layout.managedAttachmentsURL.path == "/tmp/repopress-data/ManagedAttachments")
  }

  @Test
  func probeClassifiesMissingAndEmptyRootsWithoutWriting() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-probe-new")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let missingRootURL = parentURL.appendingPathComponent("not-created", isDirectory: true)
    let inspector = WorkbenchDataRootInspector()

    #expect(inspector.probe(at: missingRootURL) == .new)
    #expect(!FileManager.default.fileExists(atPath: missingRootURL.path))

    let emptyRootURL = parentURL.appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyRootURL, withIntermediateDirectories: false)
    #expect(inspector.probe(at: emptyRootURL) == .new)
    #expect(try FileManager.default.contentsOfDirectory(atPath: emptyRootURL.path).isEmpty)

    let finderMetadataURL = emptyRootURL.appendingPathComponent(".DS_Store")
    let appleDoubleURL = emptyRootURL.appendingPathComponent("._external-volume-metadata")
    try Data().write(to: finderMetadataURL)
    try Data().write(to: appleDoubleURL)
    #expect(inspector.probe(at: emptyRootURL) == .new)

    try Data("legacy".utf8).write(
      to: emptyRootURL.appendingPathComponent("workbench.json")
    )
    #expect(
      inspector.probe(at: emptyRootURL)
        == .incompatible(.missingManifestForNonEmptyRoot)
    )
  }

  @Test
  func probeValidatesManifestComponentsAndPreservesCandidateOrder() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-probe-existing")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let firstRootURL = parentURL.appendingPathComponent("first", isDirectory: true)
    let secondRootURL = parentURL.appendingPathComponent("second", isDirectory: true)
    let firstManifest = try makeExistingRoot(at: firstRootURL, dataID: UUID())
    let secondManifest = try makeExistingRoot(at: secondRootURL, dataID: UUID())
    let inspector = WorkbenchDataRootInspector()

    #expect(inspector.probe(at: firstRootURL) == .existing(firstManifest))
    #expect(inspector.probe(at: secondRootURL) == .existing(secondManifest))

    let candidates = inspector.probeCandidates(at: [secondRootURL, firstRootURL])
    #expect(candidates.map(\.rootURL) == [secondRootURL, firstRootURL])
    #expect(candidates.map(\.result) == [.existing(secondManifest), .existing(firstManifest)])

    let futureRootURL = parentURL.appendingPathComponent("future", isDirectory: true)
    try FileManager.default.createDirectory(at: futureRootURL, withIntermediateDirectories: false)
    let futureLayout = WorkbenchDataRootLayout(rootURL: futureRootURL)
    let futureManifest = WorkbenchDataRootManifest(
      formatVersion: WorkbenchDataRootManifest.currentFormatVersion + 1,
      lastOpenedAppVersion: "99.0"
    )
    try WorkbenchDataRootManifestStore().write(futureManifest, to: futureLayout)
    #expect(
      inspector.probe(at: futureRootURL)
        == .incompatible(
          .unsupportedFormatVersion(
            found: WorkbenchDataRootManifest.currentFormatVersion + 1,
            supported: WorkbenchDataRootManifest.currentFormatVersion
          )
        )
    )
  }

  @Test
  func probeRejectsADeclaredComponentThatWasDeleted() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-missing-component")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let rootURL = parentURL.appendingPathComponent("root", isDirectory: true)
    let manifest = try makeExistingRoot(at: rootURL, dataID: UUID())
    let layout = WorkbenchDataRootLayout(rootURL: rootURL)

    try FileManager.default.removeItem(at: layout.workbenchFileURL)

    #expect(
      WorkbenchDataRootInspector().probe(at: rootURL)
        == .incompatible(.declaredComponentMissing(.workbench))
    )
    #expect(manifest.components == [.workbench])
  }

  @Test
  func staleBookmarkIsRefreshedAndSessionRetainsSecurityScopeLease() throws {
    let rootURL = try makeTemporaryDirectory(prefix: "data-root-bookmark")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let suiteName = "WorkbenchDataRootTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storageKey = "selected-root"
    let oldBookmark = Data("old-bookmark".utf8)
    let refreshedBookmark = Data("refreshed-bookmark".utf8)
    let originalRecord = WorkbenchDataRootBookmarkRecord(
      bookmarkData: oldBookmark, displayPath: "/old/path", updatedAt: Date(timeIntervalSince1970: 10)
    )
    defaults.set(try JSONEncoder().encode(originalRecord), forKey: storageKey)

    let codec = WorkbenchDataRootBookmarkCodec(
      create: { _ in refreshedBookmark },
      resolve: { data in
        WorkbenchDataRootDecodedBookmark(url: rootURL, isStale: data == oldBookmark)
      }
    )
    let recorder = SecurityScopeRecorder()
    let securityScope = WorkbenchDataRootSecurityScope(
      start: { url in
        recorder.recordStartedPath(url.path)
        return true
      },
      stop: { url in recorder.recordStoppedPath(url.path) }
    )
    let store = WorkbenchDataRootBookmarkStore(
      defaults: defaults,
      storageKey: storageKey,
      codec: codec,
      securityScope: securityScope
    )

    let resolvedRoot = try store.resolveStoredRoot(
      refreshedAt: Date(timeIntervalSince1970: 20)
    )
    let resolution = try #require(resolvedRoot)
    #expect(resolution.didRefreshStaleBookmark)
    #expect(resolution.accessURL == rootURL)
    #expect(resolution.record.bookmarkData == refreshedBookmark)
    #expect(resolution.record.displayPath == rootURL.path)
    #expect(try store.storedRecord()?.bookmarkData == refreshedBookmark)

    var session = try store.openStoredRoot()
    #expect(session != nil)
    #expect(session?.layout.rootURL == rootURL)
    #expect(session?.probeResult == .new)
    #expect(session?.didStartSecurityScopedAccess == true)
    #expect(recorder.startedPaths == [rootURL.path, rootURL.path])
    #expect(recorder.stoppedPaths == [rootURL.path])

    session = nil
    #expect(recorder.stoppedPaths == [rootURL.path, rootURL.path])
  }

  @Test
  func childDataRootRetainsTheUserSelectedParentSecurityScope() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-parent-bookmark")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let rootURL = parentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    let manifest = try makeExistingRoot(at: rootURL, dataID: UUID())
    let suiteName = "WorkbenchDataRootParentBookmarkTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let recorder = SecurityScopeRecorder()
    let store = WorkbenchDataRootBookmarkStore(
      defaults: defaults,
      storageKey: "selected-root",
      codec: WorkbenchDataRootBookmarkCodec(
        create: { url in
          recorder.setBookmarkedPath(url.path)
          return Data("parent-bookmark".utf8)
        },
        resolve: { _ in
          WorkbenchDataRootDecodedBookmark(url: parentURL, isStale: false)
        }
      ),
      securityScope: WorkbenchDataRootSecurityScope(
        start: { url in
          recorder.recordStartedPath(url.path)
          return true
        },
        stop: { url in recorder.recordStoppedPath(url.path) }
      )
    )

    let record = try store.rememberSelectedRoot(
      rootURL,
      accessURL: parentURL,
      dataID: manifest.dataID
    )
    #expect(recorder.bookmarkedPath == parentURL.path)
    #expect(record.displayPath == rootURL.path)
    #expect(record.relativeRootPath == "RepoPress Data")

    let resolvedRoot = try store.resolveStoredRoot()
    let resolution = try #require(resolvedRoot)
    #expect(resolution.accessURL == parentURL)
    #expect(resolution.url == rootURL)

    var session = try store.openStoredRoot()
    #expect(session?.layout.rootURL == rootURL)
    #expect(session?.probeResult == .existing(manifest))
    #expect(recorder.startedPaths == [parentURL.path])
    session = nil
    #expect(recorder.stoppedPaths == [parentURL.path])
  }

  @Test
  func staleParentBookmarkRefreshesWhileSecurityScopeIsActive() throws {
    let remountedParentURL = try makeTemporaryDirectory(prefix: "data-root-remounted-parent")
    defer { try? FileManager.default.removeItem(at: remountedParentURL) }
    let rootURL = remountedParentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    let manifest = try makeExistingRoot(at: rootURL, dataID: UUID())
    let suiteName = "WorkbenchDataRootStaleParentTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storageKey = "selected-root"
    let oldBookmark = Data("old-parent-bookmark".utf8)
    let refreshedBookmark = Data("refreshed-parent-bookmark".utf8)
    let originalRecord = WorkbenchDataRootBookmarkRecord(
      bookmarkData: oldBookmark,
      displayPath: "/Volumes/Old Disk/RepoPress Data",
      relativeRootPath: "RepoPress Data",
      dataID: manifest.dataID
    )
    defaults.set(try JSONEncoder().encode(originalRecord), forKey: storageKey)
    let recorder = SecurityScopeRecorder()
    let store = WorkbenchDataRootBookmarkStore(
      defaults: defaults,
      storageKey: storageKey,
      codec: WorkbenchDataRootBookmarkCodec(
        create: { _ in
          guard recorder.hasActiveAccess else {
            throw CocoaError(.fileReadNoPermission)
          }
          recorder.incrementBookmarkCreateCount()
          return refreshedBookmark
        },
        resolve: { _ in
          WorkbenchDataRootDecodedBookmark(url: remountedParentURL, isStale: true)
        }
      ),
      securityScope: WorkbenchDataRootSecurityScope(
        start: { _ in
          recorder.incrementActiveAccessCount()
          return true
        },
        stop: { _ in recorder.decrementActiveAccessCount() }
      )
    )

    var session = try store.openStoredRoot()

    #expect(session?.layout.rootURL == rootURL)
    #expect(session?.probeResult == .existing(manifest))
    #expect(session?.bookmarkRecord.bookmarkData == refreshedBookmark)
    #expect(session?.bookmarkRecord.displayPath == rootURL.path)
    #expect(recorder.bookmarkCreateCount == 1)
    #expect(recorder.activeAccessCount == 1)
    session = nil
    #expect(recorder.activeAccessCount == 0)
  }

  @Test
  func staleIdentityMismatchDoesNotPersistRefreshedBookmark() throws {
    let remountedParentURL = try makeTemporaryDirectory(prefix: "data-root-wrong-remount")
    defer { try? FileManager.default.removeItem(at: remountedParentURL) }
    let rootURL = remountedParentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    let actualManifest = try makeExistingRoot(at: rootURL, dataID: UUID())
    let expectedDataID = UUID()
    let suiteName = "WorkbenchDataRootStaleMismatchTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storageKey = "selected-root"
    let oldBookmark = Data("old-parent-bookmark".utf8)
    let originalRecord = WorkbenchDataRootBookmarkRecord(
      bookmarkData: oldBookmark,
      displayPath: "/Volumes/Old Disk/RepoPress Data",
      relativeRootPath: "RepoPress Data",
      dataID: expectedDataID
    )
    defaults.set(try JSONEncoder().encode(originalRecord), forKey: storageKey)
    let recorder = SecurityScopeRecorder()
    let store = WorkbenchDataRootBookmarkStore(
      defaults: defaults,
      storageKey: storageKey,
      codec: WorkbenchDataRootBookmarkCodec(
        create: { _ in
          recorder.incrementBookmarkCreateCount()
          return Data("unexpected-refresh".utf8)
        },
        resolve: { _ in
          WorkbenchDataRootDecodedBookmark(url: remountedParentURL, isStale: true)
        }
      ),
      securityScope: WorkbenchDataRootSecurityScope(
        start: { _ in
          recorder.incrementActiveAccessCount()
          return true
        },
        stop: { _ in recorder.decrementActiveAccessCount() }
      )
    )

    #expect(
      throws: WorkbenchDataRootBookmarkError.dataIdentityMismatch(
        expected: expectedDataID,
        found: actualManifest.dataID
      )
    ) {
      try store.openStoredRoot()
    }
    #expect(try store.storedRecord() == originalRecord)
    #expect(recorder.bookmarkCreateCount == 0)
    #expect(recorder.activeAccessCount == 0)
  }

  @Test
  func staleBookmarkToMissingBoundRootIsNotRefreshed() throws {
    let remountedParentURL = try makeTemporaryDirectory(prefix: "data-root-missing-remount")
    defer { try? FileManager.default.removeItem(at: remountedParentURL) }
    let expectedRootURL = remountedParentURL.appendingPathComponent(
      "RepoPress Data",
      isDirectory: true
    )
    let suiteName = "WorkbenchDataRootStaleMissingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storageKey = "selected-root"
    let oldBookmark = Data("old-parent-bookmark".utf8)
    let originalRecord = WorkbenchDataRootBookmarkRecord(
      bookmarkData: oldBookmark,
      displayPath: "/Volumes/Old Disk/RepoPress Data",
      relativeRootPath: "RepoPress Data",
      dataID: UUID()
    )
    defaults.set(try JSONEncoder().encode(originalRecord), forKey: storageKey)
    let recorder = SecurityScopeRecorder()
    let store = WorkbenchDataRootBookmarkStore(
      defaults: defaults,
      storageKey: storageKey,
      codec: WorkbenchDataRootBookmarkCodec(
        create: { _ in
          recorder.incrementBookmarkCreateCount()
          return Data("unexpected-refresh".utf8)
        },
        resolve: { _ in
          WorkbenchDataRootDecodedBookmark(url: remountedParentURL, isStale: true)
        }
      ),
      securityScope: WorkbenchDataRootSecurityScope(
        start: { _ in
          recorder.incrementActiveAccessCount()
          return true
        },
        stop: { _ in recorder.decrementActiveAccessCount() }
      )
    )

    let resolution = try #require(try store.resolveStoredRoot())
    #expect(resolution.url == expectedRootURL)
    #expect(resolution.didRefreshStaleBookmark == false)
    #expect(try store.storedRecord() == originalRecord)
    #expect(recorder.bookmarkCreateCount == 0)
    #expect(recorder.activeAccessCount == 0)

    var session = try store.openStoredRoot()
    #expect(session?.layout.rootURL == expectedRootURL)
    #expect(session?.probeResult == .new)
    #expect(session?.bookmarkRecord == originalRecord)
    #expect(recorder.bookmarkCreateCount == 0)
    #expect(recorder.activeAccessCount == 1)
    session = nil
    #expect(recorder.activeAccessCount == 0)
  }

  @Test
  func openingRootFailsWhenTheSecurityScopeCannotStart() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-denied-scope")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let rootURL = parentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    let manifest = try makeExistingRoot(at: rootURL, dataID: UUID())
    let suiteName = "WorkbenchDataRootDeniedScopeTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkbenchDataRootBookmarkStore(
      defaults: defaults,
      storageKey: "selected-root",
      codec: WorkbenchDataRootBookmarkCodec(
        create: { _ in Data("bookmark".utf8) },
        resolve: { _ in
          WorkbenchDataRootDecodedBookmark(url: parentURL, isStale: false)
        }
      ),
      securityScope: WorkbenchDataRootSecurityScope(
        start: { _ in false },
        stop: { _ in }
      )
    )
    try store.rememberSelectedRoot(
      rootURL,
      accessURL: parentURL,
      dataID: manifest.dataID
    )

    #expect(throws: WorkbenchDataRootBookmarkError.securityScopedAccessDenied) {
      try store.openStoredRoot()
    }
  }

  @Test
  func bookmarkIdentityMismatchStopsNewlyAcquiredLease() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-bookmark-identity")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let rootURL = parentURL.appendingPathComponent("selected-root", isDirectory: true)
    let actualManifest = try makeExistingRoot(at: rootURL, dataID: UUID())
    let expectedDataID = UUID()
    let suiteName = "WorkbenchDataRootIdentityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let codec = WorkbenchDataRootBookmarkCodec(
      create: { _ in Data("bookmark".utf8) },
      resolve: { _ in WorkbenchDataRootDecodedBookmark(url: rootURL, isStale: false) }
    )
    let recorder = SecurityScopeRecorder()
    let store = WorkbenchDataRootBookmarkStore(
      defaults: defaults,
      storageKey: "selected-root",
      codec: codec,
      securityScope: WorkbenchDataRootSecurityScope(
        start: { _ in
          recorder.incrementStartCount()
          return true
        },
        stop: { _ in recorder.incrementStopCount() }
      )
    )
    try store.rememberSelectedRoot(rootURL, dataID: expectedDataID)

    #expect(
      throws: WorkbenchDataRootBookmarkError.dataIdentityMismatch(
        expected: expectedDataID,
        found: actualManifest.dataID
      )
    ) {
      try store.openStoredRoot()
    }
    #expect(recorder.startCount == 1)
    #expect(recorder.stopCount == 1)
  }

  private func makeExistingRoot(
    at rootURL: URL,
    dataID: UUID
  ) throws -> WorkbenchDataRootManifest {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    let layout = WorkbenchDataRootLayout(rootURL: rootURL)
    try Data("{}".utf8).write(to: layout.workbenchFileURL)
    let manifest = WorkbenchDataRootManifest(
      dataID: dataID,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastOpenedAppVersion: "test",
      components: [.workbench]
    )
    try WorkbenchDataRootManifestStore().write(manifest, to: layout)
    return manifest
  }

  private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}

private final class SecurityScopeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedBookmarkedPath: String?
  private var storedStartedPaths: [String] = []
  private var storedStoppedPaths: [String] = []
  private var storedStartCount = 0
  private var storedStopCount = 0
  private var storedActiveAccessCount = 0
  private var storedBookmarkCreateCount = 0

  var bookmarkedPath: String? { withLock { storedBookmarkedPath } }
  var startedPaths: [String] { withLock { storedStartedPaths } }
  var stoppedPaths: [String] { withLock { storedStoppedPaths } }
  var startCount: Int { withLock { storedStartCount } }
  var stopCount: Int { withLock { storedStopCount } }
  var activeAccessCount: Int { withLock { storedActiveAccessCount } }
  var bookmarkCreateCount: Int { withLock { storedBookmarkCreateCount } }
  var hasActiveAccess: Bool { withLock { storedActiveAccessCount > 0 } }

  func setBookmarkedPath(_ path: String) {
    withLock { storedBookmarkedPath = path }
  }

  func recordStartedPath(_ path: String) {
    withLock { storedStartedPaths.append(path) }
  }

  func recordStoppedPath(_ path: String) {
    withLock { storedStoppedPaths.append(path) }
  }

  func incrementStartCount() {
    withLock { storedStartCount += 1 }
  }

  func incrementStopCount() {
    withLock { storedStopCount += 1 }
  }

  func incrementActiveAccessCount() {
    withLock { storedActiveAccessCount += 1 }
  }

  func decrementActiveAccessCount() {
    withLock { storedActiveAccessCount -= 1 }
  }

  func incrementBookmarkCreateCount() {
    withLock { storedBookmarkCreateCount += 1 }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
