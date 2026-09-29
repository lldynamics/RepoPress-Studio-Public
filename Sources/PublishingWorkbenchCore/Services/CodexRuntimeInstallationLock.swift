import Darwin
import Foundation

/// Nonblocking interprocess ownership of this app's component transaction.
/// Never locks or modifies the user's global Codex installation.
final class CodexRuntimeInstallationLock {
  private var descriptor: Int32

  init(directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    descriptor = Darwin.open(
      directory.appendingPathComponent("installation.lock").path,
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      descriptor = -1
      throw CodexRuntimeSetupError.installationBusy
    }
  }

  func unlock() {
    guard descriptor >= 0 else { return }
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
    descriptor = -1
  }

  deinit { unlock() }
}
