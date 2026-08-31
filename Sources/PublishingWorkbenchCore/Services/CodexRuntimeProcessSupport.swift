import Darwin
import Foundation

/// The small inherited-environment contract shared by the account server and
/// version probe.  Child CLIs do not need application credentials, loader
/// switches, or arbitrary runtime injection variables.
enum CodexRuntimeProcessEnvironment {
  private static let allowedKeys: Set<String> = [
    "HOME", "CODEX_HOME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "PATH",
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
    "http_proxy", "https_proxy", "all_proxy", "no_proxy",
    "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
  ]

  static func sanitized(from environment: [String: String] = ProcessInfo.processInfo.environment)
    -> [String: String]
  {
    environment.filter { allowedKeys.contains($0.key) }
  }
}

struct CodexExecutableIdentity: Equatable {
  private let device: dev_t
  private let inode: ino_t
  private let mode: mode_t
  private let modificationSeconds: Int
  private let modificationNanoseconds: Int

  static func capture(executableURL: URL) -> (url: URL, identity: Self)? {
    let resolvedURL = executableURL.standardizedFileURL.resolvingSymlinksInPath()
    var metadata = stat()
    guard
      resolvedURL.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
      (metadata.st_mode & S_IFMT) == S_IFREG,
      resolvedURL.path.withCString({ Darwin.access($0, X_OK) }) == 0
    else { return nil }
    return (
      resolvedURL,
      Self(
        device: metadata.st_dev,
        inode: metadata.st_ino,
        mode: metadata.st_mode,
        modificationSeconds: Int(metadata.st_mtimespec.tv_sec),
        modificationNanoseconds: Int(metadata.st_mtimespec.tv_nsec)
      )
    )
  }
}

/// Owns argv/env C strings until `posix_spawn` has consumed them.
final class CodexRuntimeCStringArray {
  let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
  private let strings: [UnsafeMutablePointer<CChar>]

  init(_ values: [String]) throws {
    var allocated: [UnsafeMutablePointer<CChar>] = []
    allocated.reserveCapacity(values.count)
    for value in values {
      guard let string = strdup(value) else {
        for item in allocated { free(item) }
        throw CodexRuntimeProcessError.spawnFailed
      }
      allocated.append(string)
    }
    pointer = .allocate(capacity: allocated.count + 1)
    pointer.initialize(repeating: nil, count: allocated.count + 1)
    for (index, string) in allocated.enumerated() { pointer[index] = string }
    strings = allocated
  }

  deinit {
    for string in strings { free(string) }
    pointer.deinitialize(count: strings.count + 1)
    pointer.deallocate()
  }
}

enum CodexRuntimeProcessError: Error {
  case spawnFailed
}
