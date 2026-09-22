import Foundation
import PublishingCoreSupport

package struct KnowledgePersistenceInspection: Hashable, Sendable {
  var userVersion: Int
  var documentCount: Int
  var folderCount: Int
  var revisionCount: Int
  var chunkCount: Int
  var storageReferences: Set<String>
  var sampleTitles: [String]
}

/// The small internal seam between the knowledge-library services and SQLite.
///
/// It deliberately owns only database lifecycle and backup-snapshot behavior;
/// regular library operations continue to use `KnowledgeDatabase` directly.
protocol KnowledgeBackupSnapshotSource: Sendable {
  func createBackupSnapshot(at destinationURL: URL) throws -> KnowledgePersistenceInspection
}

package protocol KnowledgePersistenceLifecycle: Sendable {
  var supportedSchemaVersion: Int { get }

  func createOrOpenAndValidate(at fileURL: URL) throws -> KnowledgePersistenceInspection
  func inspectBackup(at fileURL: URL) throws -> KnowledgePersistenceInspection
}

package struct SQLiteKnowledgePersistenceLifecycle: KnowledgePersistenceLifecycle {
  package init() {}

  package var supportedSchemaVersion: Int {
    KnowledgeDatabase.currentSchemaVersion
  }

  package func createOrOpenAndValidate(at fileURL: URL) throws -> KnowledgePersistenceInspection {
    let database = try KnowledgeDatabase(fileURL: fileURL)
    return try database.inspectOpenDatabase()
  }

  package func inspectBackup(at fileURL: URL) throws -> KnowledgePersistenceInspection {
    try KnowledgeDatabase.inspectBackup(at: fileURL)
  }
}
