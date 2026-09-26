import Foundation
import SQLite3
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeBackupInspectionTests: XCTestCase {
  func testCreatesReadableSnapshotWhenDatabaseSpansMoreThanOneBackupPage() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-multi-page-backup-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sourceURL = rootURL.appendingPathComponent("library.sqlite")
    let destinationURL = rootURL.appendingPathComponent("backup.sqlite")
    let database = try KnowledgeDatabase(fileURL: sourceURL)
    let documentID = UUID().uuidString
    let revisionID = UUID().uuidString
    let content = String(repeating: "page-sized knowledge content ", count: 220)
    var rows = [
      "INSERT INTO knowledge_documents (id, kind, title, authors_json, summary, tags_json, source_name, source_byte_count, allows_ai_use, allows_local_semantic_index, is_archived, imported_at, updated_at, current_revision_id) VALUES ('\(documentID)', 'markdown', 'Multi-page backup', '[]', '', '[]', 'fixture.md', 0, 1, 1, 0, 0, 0, '\(revisionID)');",
      "INSERT INTO knowledge_revisions (id, document_id, original_hash, normalized_hash, parser_version, imported_at, original_storage_ref, normalized_storage_ref) VALUES ('\(revisionID)', '\(documentID)', 'original', 'normalized', 1, 0, 'original.md', 'normalized.md');",
    ]
    rows.append(
      contentsOf: (0..<140).map { index in
        "INSERT INTO knowledge_chunks (id, document_id, revision_id, ordinal, content, token_estimate, content_hash) VALUES ('chunk-\(index)', '\(documentID)', '\(revisionID)', \(index), '\(content)', 1, 'hash-\(index)');"
      })
    try database.execute(rows.joined(separator: "\n"))

    XCTAssertGreaterThan(
      try database.withLock { try database.scalarIntUnlocked("PRAGMA page_count;") },
      128
    )
    let sourceInspection = try database.inspectOpenDatabase()
    XCTAssertEqual(sourceInspection.chunkCount, 140)
    let backupInspection = try database.createBackupSnapshot(at: destinationURL)

    XCTAssertEqual(backupInspection.chunkCount, 140)
    XCTAssertEqual(
      try KnowledgeDatabase.inspectBackup(at: destinationURL).storageReferences,
      Set(["original.md", "normalized.md"])
    )
  }

  func testInspectsVersionTenBackupWithoutNoteAttachmentTable() throws {
    let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowledge-v10-backup-\(UUID().uuidString).sqlite"
    )
    defer { try? FileManager.default.removeItem(at: databaseURL) }

    var database: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
        nil
      ), SQLITE_OK)
    guard let database else { return }
    defer { sqlite3_close(database) }

    let schema = """
      CREATE TABLE knowledge_folders (id TEXT PRIMARY KEY);
      CREATE TABLE knowledge_documents (id TEXT PRIMARY KEY, title TEXT NOT NULL, updated_at REAL NOT NULL);
      CREATE TABLE knowledge_revisions (
        id TEXT PRIMARY KEY,
        original_storage_ref TEXT,
        captured_text_storage_ref TEXT,
        normalized_storage_ref TEXT NOT NULL
      );
      CREATE TABLE knowledge_chunks (id TEXT PRIMARY KEY);
      PRAGMA user_version = 10;
      """
    XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(
        database,
        "INSERT INTO knowledge_revisions VALUES ('r1', 'blobs/legacy.md', NULL, 'normalized/legacy.md');",
        nil,
        nil,
        nil
      ),
      SQLITE_OK
    )

    let inspection = try KnowledgeDatabase.inspectBackup(at: databaseURL)

    XCTAssertEqual(inspection.userVersion, 10)
    XCTAssertEqual(
      inspection.storageReferences,
      Set(["blobs/legacy.md", "normalized/legacy.md"])
    )
  }
}
