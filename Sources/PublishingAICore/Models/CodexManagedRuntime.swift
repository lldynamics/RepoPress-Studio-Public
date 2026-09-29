import Darwin
import Foundation

/// The application owns only executable selection. Authentication and account
/// history continue to use Codex's existing home and credential storage.
public struct CodexManagedRuntime: Sendable {
  public struct Selection: Codable, Equatable, Sendable {
    public var activeRelease: String?
    public var previousRelease: String?
    public var useSystem = false
    public var automaticallyUpdates = false
    public var deferredVersion: String?

    public init() {}
  }

  public let directory: URL

  public init(directory: URL = Self.defaultDirectory()) {
    self.directory = directory.standardizedFileURL
  }

  public static func defaultDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL {
    let home = environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent("Library/Application Support/RepoPress Studio/AI/ChatGPT")
  }

  public var selectionURL: URL { directory.appendingPathComponent("selection.json") }
  public var releasesDirectory: URL { directory.appendingPathComponent("releases") }

  public func selection() throws -> Selection {
    guard FileManager.default.fileExists(atPath: selectionURL.path) else { return Selection() }
    let data = try Data(contentsOf: selectionURL)
    guard data.count <= 16_384 else { throw CocoaError(.fileReadCorruptFile) }
    return try JSONDecoder().decode(Selection.self, from: data)
  }

  /// Read-only presentation fallback. A corrupt selection still resolves to
  /// an unavailable managed executable, and never grants automatic updates.
  public var readableSelection: Selection? {
    do { return try selection() } catch { return nil }
  }

  public func save(_ selection: Selection) throws {
    for id in [selection.activeRelease, selection.previousRelease].compactMap({ $0 }) {
      guard Self.isValidReleaseID(id) else { throw CocoaError(.fileWriteInvalidFileName) }
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".selection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try JSONEncoder().encode(selection).write(to: temporary, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    guard Darwin.rename(temporary.path, selectionURL.path) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  public func executableURL(for releaseID: String) -> URL? {
    guard Self.isValidReleaseID(releaseID) else { return nil }
    let candidate = releasesDirectory.appendingPathComponent(releaseID)
      .appendingPathComponent("bin/codex")
    let root = releasesDirectory.resolvingSymlinksInPath().path + "/"
    guard candidate.resolvingSymlinksInPath().path.hasPrefix(root) else { return nil }
    return candidate
  }

  /// A damaged selection must not silently switch to a different system CLI.
  /// Return an unavailable managed path so the UI offers repair instead.
  public func preferredExecutableURL() -> URL? {
    do {
      let value = try selection()
      guard !value.useSystem, let id = value.activeRelease else { return nil }
      return executableURL(for: id) ?? unavailableExecutableURL
    } catch {
      return unavailableExecutableURL
    }
  }

  private var unavailableExecutableURL: URL {
    directory.appendingPathComponent("unavailable/bin/codex")
  }

  private static func isValidReleaseID(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 120 && value != "." && value != ".."
      && value.unicodeScalars.allSatisfy {
        CharacterSet(
          charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._"
        )
        .contains($0)
      }
  }
}
