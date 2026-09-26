import Darwin
import Foundation
import PublishingCoreSupport

/// Installed with a restored library, never with an exported backup. Keeping
/// this identity inside the directory makes restore and rollback atomic with
/// respect to the note database and its cloud-sync baseline.
package enum KnowledgeNoteCloudRestoreBoundary {
  static let fileName = ".note-cloud-restore-id"

  package static func markRestoredLibrary(at rootURL: URL) throws {
    let url = rootURL.appendingPathComponent(fileName)
    try Data(UUID().uuidString.lowercased().utf8).write(to: url, options: .atomic)
    let handle = try FileHandle(forWritingTo: url)
    try handle.synchronize()
    try handle.close()
  }

  static func restoreID(at rootURL: URL) throws -> UUID? {
    let data: Data
    do {
      data = try BoundedFileReader.data(
        relativePath: fileName, under: rootURL, maximumByteCount: 64)
    } catch BoundedFileReadError.cannotOpen(_, let code) where code == ENOENT {
      return nil
    }
    guard let value = String(data: data, encoding: .utf8),
      let id = UUID(uuidString: value), id.uuidString.lowercased() == value
    else {
      throw KnowledgeLibraryError.databaseIntegrity(
        "笔记恢复标识损坏；为避免覆盖云端笔记，已暂停同步。")
    }
    return id
  }
}
