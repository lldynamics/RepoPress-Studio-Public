import Foundation
import Testing

@testable import PublishingWorkbenchCore

struct WorkbenchDataRootMigrationTests {
  @Test
  func relocatingManagedRootPreservesIdentityCopiesRSSMediaAndKeepsSource() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-relocation")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let legacyRootURL = parentURL.appendingPathComponent("legacy", isDirectory: true)
    _ = try makePopulatedLegacyRoot(at: legacyRootURL)
    let sourceRootURL = parentURL.appendingPathComponent("current", isDirectory: true)
    let createdAt = Date(timeIntervalSince1970: 1_700_100_000)
    let initialResult = try WorkbenchDataRootMigrator().copyLegacyRoot(
      from: legacyRootURL,
      to: sourceRootURL,
      appVersion: "0.31.0",
      dataID: UUID(),
      createdAt: createdAt
    )
    let sourceLayout = WorkbenchDataRootLayout(rootURL: sourceRootURL)
    let mediaURL = sourceLayout.rssReaderURL
      .appendingPathComponent("RSSMedia", isDirectory: true)
      .appendingPathComponent("article/image.png", isDirectory: false)
    try FileManager.default.createDirectory(
      at: mediaURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data([4, 5, 6, 7]).write(to: mediaURL)

    let destinationRootURL = parentURL.appendingPathComponent("relocated", isDirectory: true)
    let result = try WorkbenchDataRootMigrator().copyExistingRoot(
      from: sourceRootURL,
      to: destinationRootURL,
      appVersion: "0.32.0"
    )
    let destinationLayout = WorkbenchDataRootLayout(rootURL: destinationRootURL)

    #expect(result.manifest.dataID == initialResult.manifest.dataID)
    #expect(result.manifest.createdAt == createdAt)
    #expect(result.manifest.lastOpenedAppVersion == "0.32.0")
    #expect(WorkbenchDataRootInspector().probe(at: sourceRootURL) == .existing(initialResult.manifest))
    #expect(WorkbenchDataRootInspector().probe(at: destinationRootURL) == .existing(result.manifest))
    #expect(try Data(contentsOf: mediaURL) == Data([4, 5, 6, 7]))
    #expect(
      try Data(
        contentsOf: destinationLayout.rssReaderURL
          .appendingPathComponent("RSSMedia/article/image.png")
      ) == Data([4, 5, 6, 7])
    )
    let sourceSnapshot = try requiredSnapshot(at: sourceLayout.workbenchFileURL)
    let destinationSnapshot = try requiredSnapshot(at: destinationLayout.workbenchFileURL)
    let sourceManagedPath = sourceLayout.managedAttachmentsURL
      .appendingPathComponent("article-id/managed.png").path
    let destinationManagedPath = destinationLayout.managedAttachmentsURL
      .appendingPathComponent("article-id/managed.png").path
    #expect(
      try requiredAttachment("managed-active.png", in: requiredDraft(from: sourceSnapshot))
        .sourceFilePath == sourceManagedPath
    )
    #expect(
      try requiredAttachment("managed-active.png", in: requiredDraft(from: destinationSnapshot))
        .sourceFilePath == destinationManagedPath
    )
    #expect(FileManager.default.fileExists(atPath: sourceManagedPath))
    #expect(FileManager.default.fileExists(atPath: destinationManagedPath))
  }

  @Test
  func migrationVerifiesCopyAndAtomicallyInstallsWithoutDeletingLegacyRoot() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-migration")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let sourceRootURL = parentURL.appendingPathComponent("legacy", isDirectory: true)
    let destinationRootURL = parentURL.appendingPathComponent("selected-root", isDirectory: true)
    let sourceLayout = try makePopulatedLegacyRoot(at: sourceRootURL)

    let dataID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let result = try WorkbenchDataRootMigrator().copyLegacyRoot(
      from: sourceRootURL,
      to: destinationRootURL,
      appVersion: "0.31.0",
      dataID: dataID,
      createdAt: createdAt
    )
    let destinationLayout = WorkbenchDataRootLayout(rootURL: destinationRootURL)
    try verifyInstalledCopy(
      result,
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout,
      dataID: dataID,
      createdAt: createdAt
    )
    let stagingItems = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
      .filter { $0.contains(".migration-") }
    #expect(stagingItems.isEmpty)
  }

  @Test
  func migrationRefusesExistingDestinationAndLeavesBothTreesUntouched() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-existing-destination")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let sourceRootURL = parentURL.appendingPathComponent("legacy", isDirectory: true)
    let destinationRootURL = parentURL.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRootURL, withIntermediateDirectories: false)
    try Data("source".utf8).write(
      to: sourceRootURL.appendingPathComponent("workbench.json")
    )
    try FileManager.default.createDirectory(at: destinationRootURL, withIntermediateDirectories: false)
    try Data("destination".utf8).write(
      to: destinationRootURL.appendingPathComponent("keep.txt")
    )

    #expect(throws: WorkbenchDataRootMigrationError.destinationAlreadyExists) {
      try WorkbenchDataRootMigrator().copyLegacyRoot(
        from: sourceRootURL,
        to: destinationRootURL,
        appVersion: "test"
      )
    }
    #expect(
      try Data(contentsOf: sourceRootURL.appendingPathComponent("workbench.json"))
        == Data("source".utf8)
    )
    #expect(
      try Data(contentsOf: destinationRootURL.appendingPathComponent("keep.txt"))
        == Data("destination".utf8)
    )
  }

  @Test
  func migrationRejectsSymbolicLinksInsideSupportedComponents() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-symlink")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let sourceRootURL = parentURL.appendingPathComponent("legacy", isDirectory: true)
    let destinationRootURL = parentURL.appendingPathComponent("destination", isDirectory: true)
    let sourceLayout = WorkbenchDataRootLayout(rootURL: sourceRootURL)
    try FileManager.default.createDirectory(
      at: sourceLayout.knowledgeLibraryURL,
      withIntermediateDirectories: true
    )
    let outsideURL = parentURL.appendingPathComponent("outside.txt")
    try Data("outside".utf8).write(to: outsideURL)
    try FileManager.default.createSymbolicLink(
      at: sourceLayout.knowledgeLibraryURL.appendingPathComponent("link"),
      withDestinationURL: outsideURL
    )

    #expect(
      throws: WorkbenchDataRootMigrationError.unsupportedFilesystemItem(
        "KnowledgeLibrary/link"
      )
    ) {
      try WorkbenchDataRootMigrator().copyLegacyRoot(
        from: sourceRootURL,
        to: destinationRootURL,
        appVersion: "test"
      )
    }
    #expect(FileManager.default.fileExists(atPath: sourceLayout.knowledgeLibraryURL.path))
    #expect(!FileManager.default.fileExists(atPath: destinationRootURL.path))
  }

  @Test
  func migrationDeclaresAllManagedComponentsWhenLegacyRootHasOnlyWorkbench() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-partial-legacy")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let sourceRootURL = parentURL.appendingPathComponent("legacy", isDirectory: true)
    let destinationRootURL = parentURL.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRootURL, withIntermediateDirectories: false)
    try createBasicWorkbenchPersistence(
      at: sourceRootURL.appendingPathComponent("workbench.json")
    )

    let result = try WorkbenchDataRootMigrator().copyLegacyRoot(
      from: sourceRootURL,
      to: destinationRootURL,
      appVersion: "test"
    )

    let expectedComponents = WorkbenchDataRootComponent.allCases.sorted { $0.rawValue < $1.rawValue }
    #expect(result.manifest.components == expectedComponents)
    #expect(WorkbenchDataRootInspector().probe(at: destinationRootURL) == .existing(result.manifest))
    let layout = WorkbenchDataRootLayout(rootURL: destinationRootURL)
    #expect(FileManager.default.fileExists(atPath: layout.knowledgeDatabaseURL.path))
    #expect(FileManager.default.fileExists(atPath: layout.rssReaderDatabaseURL.path))
    #expect(FileManager.default.fileExists(atPath: layout.managedAttachmentsURL.path))
  }

  @Test
  func migrationRejectsSymbolicLinkInsideWorkbenchCompanionDirectory() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "data-root-workbench-symlink")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let sourceRootURL = parentURL.appendingPathComponent("legacy", isDirectory: true)
    let destinationRootURL = parentURL.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRootURL, withIntermediateDirectories: false)
    let persistence = WorkbenchPersistence(
      fileURL: sourceRootURL.appendingPathComponent("workbench.json")
    )
    try createBasicWorkbenchPersistence(at: persistence.fileURL)
    try FileManager.default.createDirectory(
      at: persistence.imageOptimizationDirectoryURL,
      withIntermediateDirectories: true
    )
    let outsideURL = parentURL.appendingPathComponent("outside.jpg")
    try Data([1, 2, 3]).write(to: outsideURL)
    try FileManager.default.createSymbolicLink(
      at: persistence.imageOptimizationDirectoryURL.appendingPathComponent("link.jpg"),
      withDestinationURL: outsideURL
    )

    #expect(
      throws: WorkbenchDataRootMigrationError.unsupportedFilesystemItem(
        "OptimizedImages/link.jpg"
      )
    ) {
      try WorkbenchDataRootMigrator().copyLegacyRoot(
        from: sourceRootURL,
        to: destinationRootURL,
        appVersion: "test"
      )
    }
    #expect(!FileManager.default.fileExists(atPath: destinationRootURL.path))
  }

}
