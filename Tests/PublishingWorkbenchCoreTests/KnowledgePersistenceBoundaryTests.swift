import Foundation
import Testing

@testable import PublishingWorkbenchCore

struct KnowledgePersistenceBoundaryTests {
  @Test
  func dataRootInitializerUsesInjectedKnowledgePersistenceLifecycle() throws {
    let parentURL = try makeTemporaryDirectory(prefix: "knowledge-persistence-boundary")
    defer { try? FileManager.default.removeItem(at: parentURL) }
    let rootURL = parentURL.appendingPathComponent("root", isDirectory: true)
    let lifecycle = RecordingKnowledgePersistenceLifecycle()

    let manifest = try WorkbenchDataRootInitializer(
      knowledgePersistenceLifecycle: lifecycle
    ).initializeNewRoot(at: rootURL, appVersion: "test")

    #expect(WorkbenchDataRootInspector().probe(at: rootURL) == .existing(manifest))
    #expect(lifecycle.createdOrValidatedURLs.count == 3)
    #expect(
      lifecycle.createdOrValidatedURLs.last
        == WorkbenchDataRootLayout(
          rootURL: rootURL
        ).knowledgeDatabaseURL.standardizedFileURL
    )
  }

  private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}

private final class RecordingKnowledgePersistenceLifecycle: @unchecked Sendable,
  KnowledgePersistenceLifecycle
{
  private let lock = NSLock()
  private var openedURLs: [URL] = []

  var supportedSchemaVersion: Int { 8 }

  var createdOrValidatedURLs: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return openedURLs
  }

  func createOrOpenAndValidate(at fileURL: URL) throws -> KnowledgePersistenceInspection {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      try Data().write(to: fileURL)
    }
    lock.lock()
    openedURLs.append(fileURL.standardizedFileURL)
    lock.unlock()
    return KnowledgePersistenceInspection(
      userVersion: supportedSchemaVersion,
      documentCount: 0,
      folderCount: 0,
      revisionCount: 0,
      chunkCount: 0,
      storageReferences: [],
      sampleTitles: []
    )
  }

  func inspectBackup(at fileURL: URL) throws -> KnowledgePersistenceInspection {
    _ = fileURL
    return KnowledgePersistenceInspection(
      userVersion: supportedSchemaVersion,
      documentCount: 0,
      folderCount: 0,
      revisionCount: 0,
      chunkCount: 0,
      storageReferences: [],
      sampleTitles: []
    )
  }
}
