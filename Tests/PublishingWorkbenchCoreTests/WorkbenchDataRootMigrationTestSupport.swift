import Foundation
import Testing

@testable import PublishingWorkbenchCore

extension WorkbenchDataRootMigrationTests {
  func makePopulatedLegacyRoot(
    at rootURL: URL
  ) throws -> WorkbenchDataRootLayout {
    let layout = WorkbenchDataRootLayout(rootURL: rootURL)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    try createWorkbenchCompanionFixture(in: layout)
    try createKnowledgeFixture(in: layout)
    try createRSSFixture(in: layout)
    try createCompletedRecoveryPointFixtures(in: layout)
    try createWorkspaceBackupFixture(in: layout)
    try Data("legacy-only".utf8).write(
      to: rootURL.appendingPathComponent("unrecognized-file.txt")
    )
    return layout
  }

  func createKnowledgeFixture(in layout: WorkbenchDataRootLayout) throws {
    do {
      let service = KnowledgeLibraryService(rootURL: layout.knowledgeLibraryURL)
      _ = try service.database()
    }
    _ = try KnowledgeDatabase.inspectBackup(at: layout.knowledgeDatabaseURL)
    let capturedURL = layout.knowledgeLibraryURL.appendingPathComponent(
      "captured/fixture/page.txt"
    )
    try FileManager.default.createDirectory(
      at: capturedURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("captured-body".utf8).write(to: capturedURL)
  }

  func createRSSFixture(in layout: WorkbenchDataRootLayout) throws {
    let database = try RSSReaderDatabase(fileURL: layout.rssReaderDatabaseURL)
    let statistics = try database.statistics()
    guard statistics.feedCount == 0 else { throw FixtureError.nonEmptyRSSDatabase }
  }

  func createCompletedRecoveryPointFixtures(
    in layout: WorkbenchDataRootLayout
  ) throws {
    let knowledgeRecoveryRootURL = layout.rootURL.appendingPathComponent(
      "KnowledgeLibraryRecovery",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: knowledgeRecoveryRootURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
      at: layout.knowledgeLibraryURL,
      to: knowledgeRecoveryRootURL.appendingPathComponent(
        "BeforeRestore-fixture",
        isDirectory: true
      )
    )

    let workspaceRecoveryURL = layout.rootURL
      .appendingPathComponent("WorkspaceBackupRecovery", isDirectory: true)
      .appendingPathComponent("BeforeRestore-fixture", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workspaceRecoveryURL,
      withIntermediateDirectories: true
    )
    let persistence = WorkbenchPersistence(fileURL: layout.workbenchFileURL)
    try FileManager.default.copyItem(
      at: persistence.fileURL,
      to: workspaceRecoveryURL.appendingPathComponent("workbench.json")
    )
    try FileManager.default.copyItem(
      at: persistence.lastKnownGoodURL,
      to: workspaceRecoveryURL.appendingPathComponent("last-known-good.json")
    )
    try FileManager.default.copyItem(
      at: layout.managedAttachmentsURL,
      to: workspaceRecoveryURL.appendingPathComponent(
        "ManagedAttachments",
        isDirectory: true
      )
    )
  }

  func createWorkspaceBackupFixture(in layout: WorkbenchDataRootLayout) throws {
    let persistence = WorkbenchPersistence(fileURL: layout.workbenchFileURL)
    guard let snapshot = try persistence.load() else {
      throw FixtureError.missingWorkbenchSnapshot
    }
    let backupURL = automaticWorkspaceBackupURL(in: layout)
    let service = WorkspaceBackupService()
    _ = try service.createBackup(
      at: backupURL,
      snapshot: snapshot,
      knowledgeRootURL: layout.knowledgeLibraryURL,
      rssDatabaseURL: layout.rssReaderDatabaseURL,
      applicationVersion: "0.30.2"
    )
    _ = try service.stageRestore(
      from: backupURL,
      persistenceFileURL: layout.workbenchFileURL,
      currentApplicationVersion: "0.30.2"
    )
    guard FileManager.default.fileExists(
      atPath: WorkspaceBackupService.pendingRestoreURL(
        for: layout.workbenchFileURL
      ).path
    ) else {
      throw FixtureError.missingPendingWorkspaceRestore
    }
  }

  func verifyInstalledCopy(
    _ result: WorkbenchDataRootMigrationResult,
    sourceLayout: WorkbenchDataRootLayout,
    destinationLayout: WorkbenchDataRootLayout,
    dataID: UUID,
    createdAt: Date
  ) throws {
    #expect(result.sourceRootURL == sourceLayout.rootURL)
    #expect(result.destinationRootURL == destinationLayout.rootURL)
    #expect(result.manifest.dataID == dataID)
    #expect(result.manifest.createdAt == createdAt)
    #expect(result.manifest.lastOpenedAppVersion == "0.31.0")
    let expectedComponents = WorkbenchDataRootComponent.allCases.sorted { $0.rawValue < $1.rawValue }
    #expect(result.manifest.components == expectedComponents)
    #expect(result.copiedRegularFileCount >= 12)
    #expect(result.copiedByteCount > 0)
    #expect(
      WorkbenchDataRootInspector().probe(at: destinationLayout.rootURL)
        == .existing(result.manifest)
    )
    #expect(FileManager.default.fileExists(atPath: sourceLayout.workbenchFileURL.path))
    try verifyWorkbenchCompanionCopy(
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout
    )
    try verifyWorkspaceBackupCopy(
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout
    )
    try verifyCompletedRecoveryPointCopy(
      sourceLayout: sourceLayout,
      destinationLayout: destinationLayout
    )
    _ = try KnowledgeDatabase.inspectBackup(at: destinationLayout.knowledgeDatabaseURL)
    let rssStatistics = try RSSReaderDatabase(
      fileURL: destinationLayout.rssReaderDatabaseURL
    ).statistics()
    #expect(rssStatistics.feedCount == 0)
    let copiedAttachmentURL = destinationLayout.managedAttachmentsURL
      .appendingPathComponent("article-id/managed.png")
    #expect(try Data(contentsOf: copiedAttachmentURL) == Data([0, 1, 2, 3]))
    #expect(!FileManager.default.fileExists(
      atPath: destinationLayout.rootURL.appendingPathComponent("unrecognized-file.txt").path
    ))
  }

  func verifyCompletedRecoveryPointCopy(
    sourceLayout: WorkbenchDataRootLayout,
    destinationLayout: WorkbenchDataRootLayout
  ) throws {
    let knowledgeRelativePath = "KnowledgeLibraryRecovery"
    let sourceKnowledgeURL = sourceLayout.rootURL.appendingPathComponent(
      knowledgeRelativePath,
      isDirectory: true
    )
    let destinationKnowledgeURL = destinationLayout.rootURL.appendingPathComponent(
      knowledgeRelativePath,
      isDirectory: true
    )
    let sourceKnowledgeFiles = try regularFileMap(in: sourceKnowledgeURL)
    #expect(!sourceKnowledgeFiles.isEmpty)
    #expect(try regularFileMap(in: destinationKnowledgeURL) == sourceKnowledgeFiles)
    _ = try KnowledgeDatabase.inspectBackup(
      at: destinationKnowledgeURL.appendingPathComponent(
        "BeforeRestore-fixture/library.sqlite"
      )
    )

    let workspaceRelativePath = "WorkspaceBackupRecovery"
    let sourceWorkspaceURL = sourceLayout.rootURL.appendingPathComponent(
      workspaceRelativePath,
      isDirectory: true
    )
    let destinationWorkspaceURL = destinationLayout.rootURL.appendingPathComponent(
      workspaceRelativePath,
      isDirectory: true
    )
    let sourceWorkspaceFiles = try regularFileMap(in: sourceWorkspaceURL)
    #expect(!sourceWorkspaceFiles.isEmpty)
    #expect(try regularFileMap(in: destinationWorkspaceURL) == sourceWorkspaceFiles)
  }

  func verifyWorkspaceBackupCopy(
    sourceLayout: WorkbenchDataRootLayout,
    destinationLayout: WorkbenchDataRootLayout
  ) throws {
    let sourceDirectoryURL = automaticWorkspaceBackupDirectoryURL(in: sourceLayout)
    let destinationDirectoryURL = automaticWorkspaceBackupDirectoryURL(
      in: destinationLayout
    )
    let sourceFiles = try regularFileMap(in: sourceDirectoryURL)
    #expect(!sourceFiles.isEmpty)
    #expect(try regularFileMap(in: destinationDirectoryURL) == sourceFiles)

    let preview = try WorkspaceBackupService().inspectBackup(
      at: automaticWorkspaceBackupURL(in: destinationLayout),
      currentApplicationVersion: "0.31.0"
    )
    #expect(preview.draftCount == 1)

    let sourcePendingURL = WorkspaceBackupService.pendingRestoreURL(
      for: sourceLayout.workbenchFileURL
    )
    let destinationPendingURL = WorkspaceBackupService.pendingRestoreURL(
      for: destinationLayout.workbenchFileURL
    )
    #expect(FileManager.default.fileExists(atPath: sourcePendingURL.path))
    #expect(!FileManager.default.fileExists(atPath: destinationPendingURL.path))
  }

  func automaticWorkspaceBackupURL(in layout: WorkbenchDataRootLayout) -> URL {
    automaticWorkspaceBackupDirectoryURL(in: layout).appendingPathComponent(
      "自动工作区备份-fixture.psworkspacebackup",
      isDirectory: true
    )
  }

  func automaticWorkspaceBackupDirectoryURL(
    in layout: WorkbenchDataRootLayout
  ) -> URL {
    layout.rootURL.appendingPathComponent(
      WorkspaceBackupService.automaticBackupDirectoryName,
      isDirectory: true
    )
  }

  func createBasicWorkbenchPersistence(at fileURL: URL) throws {
    _ = try WorkbenchPersistence(fileURL: fileURL).save(
      makeWorkbenchSnapshot(title: "Basic legacy workbench")
    )
  }

  func regularFileMap(in rootURL: URL) throws -> [String: Data] {
    guard FileManager.default.fileExists(atPath: rootURL.path) else { return [:] }
    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: []
    ) else {
      throw FixtureError.unreadableDirectory
    }

    var files: [String: Data] = [:]
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      let prefix = rootURL.standardizedFileURL.path + "/"
      let path = url.standardizedFileURL.path
      guard path.hasPrefix(prefix) else { throw FixtureError.escapedDirectory }
      files[String(path.dropFirst(prefix.count))] = try Data(contentsOf: url)
    }
    return files
  }

  func quarantineFileMap(in rootURL: URL) throws -> [String: Data] {
    let urls = try FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: []
    )
    return try Dictionary(uniqueKeysWithValues: urls.compactMap { url in
      let name = url.lastPathComponent
      guard name.hasPrefix("workbench.draft-recovery.unreadable-"),
            name.hasSuffix(".json") else { return nil }
      return (name, try Data(contentsOf: url))
    })
  }

  func makeTemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  enum FixtureError: Error {
    case escapedDirectory
    case invalidWorkbenchJSON
    case invalidWorkbenchSnapshot
    case missingAttachment
    case missingDraft
    case missingDraftVersion
    case missingPendingWorkspaceRestore
    case missingQuarantine
    case missingRecycledDraft
    case missingWorkbenchSnapshot
    case nonEmptyRSSDatabase
    case unreadableDirectory
  }
}
