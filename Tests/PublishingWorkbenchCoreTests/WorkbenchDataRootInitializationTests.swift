import Foundation
import Testing

@testable import PublishingWorkbenchCore

struct WorkbenchDataRootInitializationTests {
  @Test
  func initializesCompleteValidatedRootInsideSelectedEmptyFolder() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-initialization")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let rootURL = parentURL.appendingPathComponent("selected-empty-folder", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    let dataID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    let manifest = try WorkbenchDataRootManifestStore().initializeNewRoot(
      at: rootURL,
      appVersion: "0.31.0",
      dataID: dataID,
      createdAt: createdAt
    )
    let layout = WorkbenchDataRootLayout(rootURL: rootURL)

    #expect(manifest.dataID == dataID)
    #expect(manifest.createdAt == createdAt)
    #expect(manifest.components == WorkbenchDataRootComponent.allCases.sorted { $0.rawValue < $1.rawValue })
    #expect(WorkbenchDataRootInspector().probe(at: rootURL) == .existing(manifest))
    let snapshot = try #require(try WorkbenchPersistence(fileURL: layout.workbenchFileURL).load())
    #expect(snapshot.profiles.count == 1)
    #expect(snapshot.drafts.count == 1)

    let knowledgeInspection = try {
      let database = try KnowledgeDatabase(fileURL: layout.knowledgeDatabaseURL)
      return try database.inspectOpenDatabase()
    }()
    #expect(knowledgeInspection.documentCount == 0)
    #expect(knowledgeInspection.revisionCount == 0)
    let rssStatistics = try RSSReaderDatabase(fileURL: layout.rssReaderDatabaseURL).statistics()
    #expect(rssStatistics.feedCount == 0)
    #expect(rssStatistics.articleCount == 0)
    #expect(try layout.managedAttachmentsURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    let stagingNames = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
      .filter { $0.contains("repopress-initialization") }
    #expect(stagingNames.isEmpty)
    let siblingStagingNames = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
      .filter { $0.contains(".initialization-") }
    #expect(siblingStagingNames.isEmpty)

    #expect(
      throws: WorkbenchDataRootInitializationError.rootIsNotNew(.existing(manifest))
    ) {
      try WorkbenchDataRootManifestStore().initializeNewRoot(
        at: rootURL,
        appVersion: "0.31.0"
      )
    }
  }

  @Test
  func initializesMissingRootAndRejectsNonEmptyUnownedFolder() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-initialization-boundary")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let missingRootURL = parentURL.appendingPathComponent("missing", isDirectory: true)

    let manifest = try WorkbenchDataRootInitializer().initializeNewRoot(
      at: missingRootURL,
      appVersion: "test"
    )
    #expect(FileManager.default.fileExists(atPath: missingRootURL.path))
    #expect(WorkbenchDataRootInspector().probe(at: missingRootURL) == .existing(manifest))

    let unownedRootURL = parentURL.appendingPathComponent("unowned", isDirectory: true)
    try FileManager.default.createDirectory(at: unownedRootURL, withIntermediateDirectories: false)
    let keepURL = unownedRootURL.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: keepURL)
    #expect(
      throws: WorkbenchDataRootInitializationError.rootIsNotNew(
        .incompatible(.missingManifestForNonEmptyRoot)
      )
    ) {
      try WorkbenchDataRootInitializer().initializeNewRoot(
        at: unownedRootURL,
        appVersion: "test"
      )
    }
    #expect(try Data(contentsOf: keepURL) == Data("keep".utf8))
  }

  @Test
  func initializesExternalVolumeFolderContainingOnlyFileSystemMetadata() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-external-metadata")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let rootURL = parentURL.appendingPathComponent("RepoPress Data", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    let appleDoubleURL = rootURL.appendingPathComponent("._previous-stage")
    let finderMetadataURL = rootURL.appendingPathComponent(".DS_Store")
    try Data("apple-double".utf8).write(to: appleDoubleURL)
    try Data("finder".utf8).write(to: finderMetadataURL)

    let manifest = try WorkbenchDataRootInitializer().initializeNewRoot(
      at: rootURL,
      appVersion: "test"
    )

    #expect(WorkbenchDataRootInspector().probe(at: rootURL) == .existing(manifest))
    #expect(try Data(contentsOf: appleDoubleURL) == Data("apple-double".utf8))
    #expect(try Data(contentsOf: finderMetadataURL) == Data("finder".utf8))
  }

  private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}
