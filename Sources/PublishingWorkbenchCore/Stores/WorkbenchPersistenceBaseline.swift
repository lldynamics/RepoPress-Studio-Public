import Foundation

/// Copies of one persistence instance share its last observed disk revision.
/// A separate app process/instance has its own baseline and must reload when
/// another writer commits. The OS lock alone would only serialize lost updates.
final class WorkbenchPersistenceBaseline: @unchecked Sendable {
  private let lock = NSLock()
  private var versions: [String: String] = [:]

  func version(for path: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return versions[path]
  }

  func observe(_ version: String, for path: String) {
    lock.lock()
    defer { lock.unlock() }
    versions[path] = version
  }
}
