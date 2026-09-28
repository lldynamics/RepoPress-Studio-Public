import Foundation
import os

/// Copies of one persistence instance share its last observed disk revision.
/// A separate app process/instance has its own baseline and must reload when
/// another writer commits. The OS lock alone would only serialize lost updates.
final class WorkbenchPersistenceBaseline: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: [String: String]())

  func version(for path: String) -> String? {
    state.withLock { $0[path] }
  }

  func observe(_ version: String, for path: String) {
    state.withLock { $0[path] = version }
  }
}
