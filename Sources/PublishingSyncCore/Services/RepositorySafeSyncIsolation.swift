import Darwin
import Foundation

struct RepositorySafeSyncRecoveryManifest: Codable {
  struct Entry: Codable {
    let path: String
    let blobOID: String
    let mode: String
    let backupRelativePath: String
  }

  let version: Int
  let repositoryRoot: String
  let previousHeadSHA: String
  let targetHeadSHA: String
  let entries: [Entry]
}

/// Keeps the original inode after a collision is removed from the worktree.
/// In particular, an editor with an open descriptor can still write to it.
struct RepositorySafeSyncIsolation {
  private struct Manifest: Encodable {
    let version = 1
    let repositoryRoot: String
    let recoveryCopyDirectory: String
    let originalPaths: [String]
  }

  let url: URL

  init(root: URL, gitDirectory: URL, recoveryCopy: URL, paths: [String]) throws {
    let directory = gitDirectory.appendingPathComponent(
      "RepoPress-SafeSync-Hold-\(UUID().uuidString)", isDirectory: true)
    let sourceDevice = try Self.device(of: root)
    guard sourceDevice == (try Self.device(of: gitDirectory)) else {
      throw RepositorySafeSyncError.recoveryRequired(
        recoveryDirectory: recoveryCopy.path,
        message: "Git 元数据目录不在工作树所在卷；未移动任何本地文件。")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    url = directory
    let manifest = Manifest(
      repositoryRoot: root.path, recoveryCopyDirectory: recoveryCopy.path,
      originalPaths: paths)
    try JSONEncoder().encode(manifest).write(
      to: directory.appendingPathComponent("manifest.json"), options: .atomic)
  }

  func isolatedURL(for path: String) -> URL {
    url.appendingPathComponent("files", isDirectory: true).appendingPathComponent(path)
  }

  func moveOriginal(_ path: String, from root: URL) throws {
    let destination = isolatedURL(for: path)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.withParent(root: root, path: path) { sourceFD, name in
      try Self.withParent(root: url.appendingPathComponent("files"), path: path) {
        destinationFD, destinationName in
        let before = try Self.regularFile(in: sourceFD, named: name, path: path)
        guard before.st_dev == (try Self.device(of: destinationFD)) else {
          throw RepositorySafeSyncError.recoveryRequired(
            recoveryDirectory: url.path, message: "隔离目录与碰撞文件不在同一卷：\(path)")
        }
        let result = name.withCString { sourceName in
          destinationName.withCString { targetName in
            Darwin.renameatx_np(
              sourceFD, sourceName, destinationFD, targetName, UInt32(RENAME_EXCL))
          }
        }
        guard result == 0 else { throw Self.fileError(path) }
        let after = try Self.regularFile(in: destinationFD, named: destinationName, path: path)
        guard after.st_dev == before.st_dev, after.st_ino == before.st_ino else {
          throw RepositorySafeSyncError.recoveryRequired(
            recoveryDirectory: url.path, message: "隔离文件身份无法确认：\(path)")
        }
      }
    }
  }

  /// Restores a copy while retaining the original inode in the hold directory.
  /// A concurrent replacement at the destination makes the exclusive rename fail.
  func restoreCopyIfMissing(_ path: String, to root: URL) throws -> Bool {
    let held = isolatedURL(for: path)
    guard FileManager.default.fileExists(atPath: held.path) else { return true }
    return try Self.withParent(root: root, path: path) { destinationFD, name in
      var existing = stat()
      if name.withCString({ Darwin.fstatat(destinationFD, $0, &existing, AT_SYMLINK_NOFOLLOW) })
        == 0
      {
        return false
      }
      guard errno == ENOENT else { throw Self.fileError(path) }
      return try Self.withParent(root: url.appendingPathComponent("files"), path: path) {
        heldFD, heldName in
        let expected = try Self.regularFile(in: heldFD, named: heldName, path: path)
        let source = heldName.withCString {
          Darwin.openat(heldFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard source >= 0 else { throw Self.fileError(path) }
        defer { Darwin.close(source) }
        var opened = stat()
        guard Darwin.fstat(source, &opened) == 0,
          opened.st_dev == expected.st_dev, opened.st_ino == expected.st_ino
        else { throw Self.fileError(path) }
        let temporaryName = ".repopress-safe-sync-restore-\(UUID().uuidString)"
        let temporary = temporaryName.withCString {
          Darwin.openat(
            destinationFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(expected.st_mode & 0o777))
        }
        guard temporary >= 0 else { throw Self.fileError(path) }
        defer { Darwin.close(temporary) }
        defer { temporaryName.withCString { _ = Darwin.unlinkat(destinationFD, $0, 0) } }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
          let readCount = try bytes.withUnsafeMutableBytes { pointer in
            guard let address = pointer.baseAddress else { throw Self.fileError(path) }
            return Darwin.read(source, address, pointer.count)
          }
          guard readCount >= 0 else { throw Self.fileError(path) }
          if readCount == 0 { break }
          var written = 0
          while written < readCount {
            let count = try bytes.withUnsafeBytes { pointer in
              guard let address = pointer.baseAddress else { throw Self.fileError(path) }
              return Darwin.write(temporary, address.advanced(by: written), readCount - written)
            }
            guard count > 0 else { throw Self.fileError(path) }
            written += count
          }
        }
        guard Darwin.fchmod(temporary, expected.st_mode & 0o777) == 0 else {
          throw Self.fileError(path)
        }
        let result = temporaryName.withCString { temporaryPath in
          name.withCString { destinationPath in
            Darwin.renameatx_np(
              destinationFD, temporaryPath, destinationFD, destinationPath, UInt32(RENAME_EXCL))
          }
        }
        if result != 0, errno == EEXIST { return false }
        guard result == 0 else { throw Self.fileError(path) }
        return true
      }
    }
  }

  private static func withParent<T>(
    root: URL, path: String, operation: (Int32, String) throws -> T
  ) throws -> T {
    let components = path.split(separator: "/").map(String.init)
    guard let name = components.last, !components.contains(where: { $0 == ".." || $0 == "." })
    else { throw RepositorySafeSyncError.unsafeLocalChanges([path]) }
    var directory = root.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    }
    guard directory >= 0 else { throw fileError(path) }
    defer { Darwin.close(directory) }
    for component in components.dropLast() {
      let next = component.withCString {
        Darwin.openat(directory, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
      }
      guard next >= 0 else { throw fileError(path) }
      Darwin.close(directory)
      directory = next
    }
    return try operation(directory, name)
  }

  private static func regularFile(in directory: Int32, named name: String, path: String) throws
    -> stat
  {
    var state = stat()
    guard name.withCString({ Darwin.fstatat(directory, $0, &state, AT_SYMLINK_NOFOLLOW) }) == 0,
      state.st_mode & S_IFMT == S_IFREG
    else { throw RepositorySafeSyncError.unsafeLocalChanges([path]) }
    return state
  }

  private static func device(of url: URL) throws -> dev_t {
    var state = stat()
    guard url.path.withCString({ Darwin.lstat($0, &state) }) == 0,
      state.st_mode & S_IFMT == S_IFDIR
    else { throw fileError(url.path) }
    return state.st_dev
  }

  private static func device(of descriptor: Int32) throws -> dev_t {
    var state = stat()
    guard Darwin.fstat(descriptor, &state) == 0 else { throw fileError("隔离目录") }
    return state.st_dev
  }

  private static func fileError(_ path: String) -> Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
  }
}
