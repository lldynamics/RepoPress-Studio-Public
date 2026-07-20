import Darwin
import Foundation

/// Thread-safe owner of the native-messaging socket and its exclusive lock.
///
/// The paths and file descriptor are immutable after initialization. All mutable lifecycle state
/// (`socketIdentity` and `isReleased`) is guarded by `stateLock`, and `release()` transfers the
/// cleanup work to exactly one caller before touching the descriptor or socket path.
public final class NativeMessagingSocketLease: @unchecked Sendable {
  private struct SocketIdentity: Equatable {
    var device: dev_t
    var inode: ino_t
  }

  public enum LeaseError: Error, LocalizedError, Equatable {
    case lockDirectoryUnsafe
    case lockFileUnsafe
    case alreadyOwned
    case lockFailed(Int32)
    case socketPathOccupied
    case socketOwnerMismatch
    case socketUnavailable
    case socketPermissionsFailed(Int32)

    public var errorDescription: String? {
      switch self {
      case .lockDirectoryUnsafe:
        "原生连接锁目录不安全，已拒绝启动。"
      case .lockFileUnsafe:
        "原生连接锁文件不安全，已拒绝启动。"
      case .alreadyOwned:
        "已有另一个应用实例正在提供浏览器原生连接。"
      case .lockFailed(let code):
        "无法取得浏览器原生连接锁（错误码 \(code)）。"
      case .socketPathOccupied:
        "原生连接路径被非套接字文件占用，已拒绝覆盖。"
      case .socketOwnerMismatch:
        "原生连接路径属于其他用户，已拒绝覆盖。"
      case .socketUnavailable:
        "原生连接套接字尚未建立。"
      case .socketPermissionsFailed(let code):
        "无法限制本地套接字权限（错误码 \(code)）。"
      }
    }
  }

  public let socketPath: String
  public let lockFileURL: URL

  private let lockFileDescriptor: Int32
  private let stateLock = NSLock()
  private var socketIdentity: SocketIdentity?
  private var isReleased = false

  private init(socketPath: String, lockFileURL: URL, lockFileDescriptor: Int32) {
    self.socketPath = socketPath
    self.lockFileURL = lockFileURL
    self.lockFileDescriptor = lockFileDescriptor
  }

  deinit {
    release()
  }

  public static func acquire(socketPath: String, lockFileURL: URL) throws -> Self {
    try preparePrivateLockDirectory(lockFileURL.deletingLastPathComponent())
    let descriptor = open(
      lockFileURL.path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw LeaseError.lockFailed(errno)
    }
    do {
      try validateLockFile(descriptor)
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        if errno == EWOULDBLOCK { throw LeaseError.alreadyOwned }
        throw LeaseError.lockFailed(errno)
      }
    } catch {
      close(descriptor)
      throw error
    }
    let lease = Self(
      socketPath: socketPath,
      lockFileURL: lockFileURL,
      lockFileDescriptor: descriptor
    )
    do {
      try lease.writeOwnerRecord()
      try lease.removeStaleSocketWhileLocked()
      return lease
    } catch {
      lease.release()
      throw error
    }
  }

  /// Records the exact filesystem object created by NWListener. Later cleanup only removes
  /// this device/inode pair, so an old callback cannot unlink a replacement listener.
  public func recordBoundSocketAndRestrictPermissions() throws {
    let before = try currentSocketStatus()
    guard before.owner == getuid() else { throw LeaseError.socketOwnerMismatch }
    guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
      throw LeaseError.socketPermissionsFailed(errno)
    }
    let after = try currentSocketStatus()
    guard before.identity == after.identity, after.owner == getuid() else {
      throw LeaseError.socketUnavailable
    }
    let didRecord = stateLock.withLock {
      guard !isReleased else { return false }
      socketIdentity = after.identity
      return true
    }
    guard didRecord else { throw LeaseError.socketUnavailable }
  }

  /// Removes the socket only while the exclusive lock is still held and only if the path still
  /// resolves to the same socket inode this lease recorded. The persistent lock file is retained
  /// to avoid an unlink/recreate lock race between application instances.
  public func release() {
    let releaseState: (shouldRelease: Bool, identity: SocketIdentity?) = stateLock.withLock {
      guard !isReleased else { return (false, nil) }
      isReleased = true
      let identity = socketIdentity
      socketIdentity = nil
      return (true, identity)
    }
    guard releaseState.shouldRelease else { return }
    if let identity = releaseState.identity {
      removeSocketIfOwned(identity)
    }
    _ = flock(lockFileDescriptor, LOCK_UN)
    close(lockFileDescriptor)
  }

  private static func preparePrivateLockDirectory(_ directoryURL: URL) throws {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: directoryURL.path) {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    var status = stat()
    guard lstat(directoryURL.path, &status) == 0,
          status.st_uid == getuid(),
          status.st_mode & S_IFMT == S_IFDIR,
          status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
      throw LeaseError.lockDirectoryUnsafe
    }
  }

  private static func validateLockFile(_ descriptor: Int32) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_uid == getuid(),
          status.st_mode & S_IFMT == S_IFREG,
          status.st_nlink == 1 else {
      throw LeaseError.lockFileUnsafe
    }
  }

  private func writeOwnerRecord() throws {
    let record = Data("pid=\(getpid())\n".utf8)
    guard ftruncate(lockFileDescriptor, 0) == 0,
          lseek(lockFileDescriptor, 0, SEEK_SET) == 0 else {
      throw LeaseError.lockFailed(errno)
    }
    let written = record.withUnsafeBytes { bytes in
      Darwin.write(lockFileDescriptor, bytes.baseAddress, bytes.count)
    }
    guard written == record.count, fsync(lockFileDescriptor) == 0 else {
      throw LeaseError.lockFailed(errno)
    }
  }

  private func removeStaleSocketWhileLocked() throws {
    var status = stat()
    guard lstat(socketPath, &status) == 0 else {
      if errno == ENOENT { return }
      throw LeaseError.socketUnavailable
    }
    guard status.st_uid == getuid() else { throw LeaseError.socketOwnerMismatch }
    guard status.st_mode & S_IFMT == S_IFSOCK else { throw LeaseError.socketPathOccupied }
    guard unlink(socketPath) == 0 else { throw LeaseError.socketUnavailable }
  }

  private func currentSocketStatus() throws -> (identity: SocketIdentity, owner: uid_t) {
    var status = stat()
    guard lstat(socketPath, &status) == 0,
          status.st_mode & S_IFMT == S_IFSOCK else {
      throw LeaseError.socketUnavailable
    }
    return (.init(device: status.st_dev, inode: status.st_ino), status.st_uid)
  }

  private func removeSocketIfOwned(_ identity: SocketIdentity) {
    guard let current = try? currentSocketStatus(),
          current.owner == getuid(),
          current.identity == identity else {
      return
    }
    _ = unlink(socketPath)
  }
}
