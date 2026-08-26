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
  func pathStorePersistsNormalizedAbsolutePathAcrossStoreRecreation() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-path-store")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let rootURL = parentURL.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    let unnormalizedURL = parentURL.appendingPathComponent(
      "nested/../nested/./",
      isDirectory: true
    )
    let suiteName = "WorkbenchDataRootPathTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storageKey = "selected-root"
    let dataID = UUID()
    let updatedAt = Date(timeIntervalSince1970: 10)

    let store = WorkbenchDataRootPathStore(
      defaults: defaults,
      storageKey: storageKey
    )
    let record = try store.rememberRoot(
      unnormalizedURL,
      dataID: dataID,
      updatedAt: updatedAt
    )
    #expect(record.path == rootURL.standardizedFileURL.path)
    #expect(record.dataID == dataID)
    #expect(record.updatedAt == updatedAt)

    let restartedStore = WorkbenchDataRootPathStore(
      defaults: defaults,
      storageKey: storageKey
    )
    let reopenedRecord = try #require(try restartedStore.storedRecord())
    #expect(reopenedRecord == record)
    let session = try #require(try restartedStore.openStoredRoot())
    #expect(session.layout.rootURL == rootURL.standardizedFileURL)
    #expect(session.pathRecord == record)
    #expect(session.probeResult == .new)
  }

  @Test
  func pathStoreRejectsRelativeAndNonFileRoots() throws {
    let suiteName = "WorkbenchDataRootInvalidPathTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkbenchDataRootPathStore(defaults: defaults, storageKey: "selected-root")

    #expect(throws: WorkbenchDataRootPathError.invalidRootPath) {
      try store.rememberRoot(URL(string: "relative")!)
    }
    #expect(throws: WorkbenchDataRootPathError.invalidRootPath) {
      try store.rememberRoot(URL(string: "https://example.com")!)
    }

    defaults.set(
      try JSONEncoder().encode(
        WorkbenchDataRootPathRecord(path: "relative", updatedAt: Date())
      ),
      forKey: "selected-root"
    )
    #expect(throws: WorkbenchDataRootPathError.invalidStoredRecord) {
      try store.storedRecord()
    }
  }

  @Test
  func pathStoreFailsClosedWhenExistingManifestIdentityDiffers() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-path-mismatch")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let rootURL = parentURL.appendingPathComponent("root", isDirectory: true)
    let actualManifest = try makeExistingRoot(at: rootURL, dataID: UUID())
    let expectedDataID = UUID()
    let suiteName = "WorkbenchDataRootPathMismatchTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkbenchDataRootPathStore(defaults: defaults, storageKey: "selected-root")
    let originalRecord = try store.rememberRoot(rootURL, dataID: expectedDataID)

    #expect(
      throws: WorkbenchDataRootPathError.dataIdentityMismatch(
        expected: expectedDataID,
        found: actualManifest.dataID
      )
    ) {
      try store.openStoredRoot()
    }
    #expect(try store.storedRecord() == originalRecord)
  }

  @Test
  func pathStoreDistinguishesMissingAndCorruptRecords() throws {
    let suiteName = "WorkbenchDataRootPathMissingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storageKey = "selected-root"
    let store = WorkbenchDataRootPathStore(defaults: defaults, storageKey: storageKey)

    #expect(try store.storedRecord() == nil)
    #expect(try store.openStoredRoot() == nil)

    defaults.set(Data("not-json".utf8), forKey: storageKey)
    #expect(throws: WorkbenchDataRootPathError.invalidStoredRecord) {
      try store.storedRecord()
    }
    #expect(throws: WorkbenchDataRootPathError.invalidStoredRecord) {
      try store.openStoredRoot()
    }
  }

  @Test
  func pathStoreMigratesOnlyLegacyPathMetadataWithoutResolvingOpaquePayload() throws {
    let rootURL = URL(fileURLWithPath: "/tmp/legacy-repopress-data", isDirectory: true)
    let dataID = UUID()
    let updatedAt = Date(timeIntervalSince1970: 20)
    let suiteName = "WorkbenchDataRootPathMigrationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storageKey = "selected-root"
    let legacyPayload = LegacyPathPreferencePayload(
      displayPath: rootURL.path,
      dataID: dataID,
      updatedAt: updatedAt
    )
    defaults.set(
      try JSONEncoder().encode(legacyPayload),
      forKey: WorkbenchDataRootPathStore.legacyStorageKey
    )

    let store = WorkbenchDataRootPathStore(defaults: defaults, storageKey: storageKey)
    let migrated = try #require(try store.storedRecord())
    #expect(migrated.path == rootURL.path)
    #expect(migrated.dataID == dataID)
    #expect(migrated.updatedAt == updatedAt)
    #expect(defaults.data(forKey: storageKey) != nil)
    // The legacy preference remains untouched so migration is recoverable.
    #expect(defaults.data(forKey: WorkbenchDataRootPathStore.legacyStorageKey) != nil)
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

private struct LegacyPathPreferencePayload: Encodable {
  let displayPath: String
  let dataID: UUID
  let updatedAt: Date
  let opaquePayload = "ignored"
}
