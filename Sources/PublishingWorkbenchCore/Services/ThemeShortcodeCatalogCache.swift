import Darwin
import Foundation
import os

struct ThemeShortcodeCatalogCacheStatistics: Equatable, Sendable {
  var hitCount: Int
  var missCount: Int
  var insertCount: Int
  var entryCount: Int

  init(hitCount: Int = 0, missCount: Int = 0, insertCount: Int = 0, entryCount: Int = 0) {
    self.hitCount = hitCount
    self.missCount = missCount
    self.insertCount = insertCount
    self.entryCount = entryCount
  }
}

/// Keeps catalogs produced from stable local template inputs. The fingerprint
/// deliberately records file identities and metadata instead of directory
/// timestamps, because an in-place template edit need not change a parent
/// directory's modification time.
final class ThemeShortcodeCatalogCache: Sendable {
  static let defaultMaximumEntryCount = 24

  private struct Entry: Sendable {
    let catalog: ThemeShortcodeCatalog
    var lastAccess: UInt64
  }

  private struct State: Sendable {
    var entries: [ThemeShortcodeCatalogCacheKey: Entry] = [:]
    var accessCounter: UInt64 = 0
    var hitCount = 0
    var missCount = 0
    var insertCount = 0
  }

  private let maximumEntryCount: Int
  private let state: OSAllocatedUnfairLock<State>

  init(maximumEntryCount: Int = ThemeShortcodeCatalogCache.defaultMaximumEntryCount) {
    self.maximumEntryCount = max(1, maximumEntryCount)
    self.state = OSAllocatedUnfairLock(initialState: State())
  }

  func lookup(_ key: ThemeShortcodeCatalogCacheKey) -> ThemeShortcodeCatalog? {
    state.withLock { state in
      guard var entry = state.entries[key] else {
        state.missCount += 1
        return nil
      }
      state.hitCount += 1
      state.accessCounter &+= 1
      entry.lastAccess = state.accessCounter
      state.entries[key] = entry
      return entry.catalog
    }
  }

  func insert(_ catalog: ThemeShortcodeCatalog, for key: ThemeShortcodeCatalogCacheKey) {
    state.withLock { state in
      state.accessCounter &+= 1
      state.entries[key] = Entry(catalog: catalog, lastAccess: state.accessCounter)
      state.insertCount += 1
      evictIfNeeded(&state)
    }
  }

  func removeAll() {
    state.withLock { state in
      state = State()
    }
  }

  var statistics: ThemeShortcodeCatalogCacheStatistics {
    state.withLock { state in
      ThemeShortcodeCatalogCacheStatistics(
        hitCount: state.hitCount,
        missCount: state.missCount,
        insertCount: state.insertCount,
        entryCount: state.entries.count
      )
    }
  }

  private func evictIfNeeded(_ state: inout State) {
    let overflow = state.entries.count - maximumEntryCount
    guard overflow > 0 else { return }
    let keysToRemove = state.entries
      .sorted { $0.value.lastAccess < $1.value.lastAccess }
      .prefix(overflow)
      .map(\.key)
    for key in keysToRemove {
      state.entries.removeValue(forKey: key)
    }
  }
}

struct ThemeShortcodeCatalogCacheKey: Hashable, Sendable {
  fileprivate static let maximumFingerprintEntries = 4_096

  let repositoryPath: String
  let siteKind: SiteKind
  private let fingerprint: ThemeShortcodeCatalogInputFingerprint

  static func make(rootURL: URL, siteKind: SiteKind) -> Self? {
    let root = rootURL.standardizedFileURL
    guard
      let fingerprint = ThemeShortcodeCatalogInputFingerprint.make(
        rootURL: root, siteKind: siteKind)
    else {
      return nil
    }
    return Self(repositoryPath: root.path, siteKind: siteKind, fingerprint: fingerprint)
  }
}

private struct ThemeShortcodeCatalogInputFingerprint: Hashable, Sendable {
  private struct Node: Hashable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let isMissing: Bool
  }

  private let nodes: [Node]

  static func make(rootURL: URL, siteKind: SiteKind) -> Self? {
    var builder = Builder(rootURL: rootURL, siteKind: siteKind)
    return builder.make()
  }

  private struct Builder {
    private enum DirectoryPathStatus {
      case directory(URL)
      case stopped
      case unavailable
    }

    let rootURL: URL
    let siteKind: SiteKind
    let fileManager = FileManager.default
    var nodes: [Node] = []
    var didExceedLimit = false

    mutating func make() -> ThemeShortcodeCatalogInputFingerprint? {
      guard isDirectory(rootURL) else { return nil }
      guard appendNode(at: rootURL, relativePath: ".") else { return nil }

      for name in configurationNames {
        guard appendNode(at: rootURL.appendingPathComponent(name), relativePath: name) else {
          return nil
        }
      }

      for directory in rootCandidateDirectories {
        guard appendTree(relativeDirectory: directory) else { return nil }
      }

      guard appendThemes() else { return nil }
      guard !didExceedLimit else { return nil }
      return ThemeShortcodeCatalogInputFingerprint(nodes: nodes.sorted { $0.path < $1.path })
    }

    private var configurationNames: [String] {
      switch siteKind {
      case .hugo:
        return [
          "hugo.toml", "hugo.yaml", "hugo.yml", "hugo.json",
          "config.toml", "config.yaml", "config.yml", "config.json",
        ]
      case .zola:
        // Both files influence Zola's legacy shortcode mode.
        return ["zola.toml", "config.toml"]
      default:
        return []
      }
    }

    private var rootCandidateDirectories: [String] {
      switch siteKind {
      case .hugo:
        return ["layouts/_shortcodes", "layouts/shortcodes"]
      case .zola:
        let usesLegacyShortcodes =
          !fileManager.fileExists(atPath: rootURL.appendingPathComponent("zola.toml").path)
          && fileManager.fileExists(atPath: rootURL.appendingPathComponent("config.toml").path)
        return usesLegacyShortcodes ? ["templates/shortcodes"] : ["templates"]
      default:
        return []
      }
    }

    private mutating func appendThemes() -> Bool {
      let themesURL: URL
      switch resolveDirectory(relativeDirectory: "themes") {
      case .directory(let url):
        themesURL = url
      case .stopped:
        return true
      case .unavailable:
        return false
      }
      guard
        let entries = try? fileManager.contentsOfDirectory(
          at: themesURL,
          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles]
        )
      else {
        return false
      }
      for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let name = entry.lastPathComponent
        let relativePath = "themes/\(name)"
        guard appendNode(at: entry, relativePath: relativePath) else { return false }
        guard isSafeThemeName(name), isDirectory(entry) else { continue }
        for suffix in themeCandidateDirectories {
          guard appendTree(relativeDirectory: "themes/\(name)/\(suffix)") else { return false }
        }
      }
      return true
    }

    private var themeCandidateDirectories: [String] {
      rootCandidateDirectories
    }

    private mutating func appendTree(relativeDirectory: String) -> Bool {
      let directoryURL: URL
      switch resolveDirectory(relativeDirectory: relativeDirectory) {
      case .directory(let url):
        directoryURL = url
      case .stopped:
        return true
      case .unavailable:
        return false
      }
      var didEncounterEnumerationError = false
      guard
        let enumerator = fileManager.enumerator(
          at: directoryURL,
          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants],
          errorHandler: { _, _ in
            didEncounterEnumerationError = true
            return false
          }
        )
      else {
        return false
      }
      while let url = enumerator.nextObject() as? URL {
        guard let relativePath = repositoryPath(of: url) else { return false }
        guard appendNode(at: url, relativePath: relativePath) else { return false }
        if isSymbolicLink(url) {
          enumerator.skipDescendants()
          continue
        }
        if isDirectory(url),
          depth(of: url, below: directoryURL) > ThemeShortcodeCatalogService.maximumDirectoryDepth
        {
          enumerator.skipDescendants()
        }
      }
      return !didEncounterEnumerationError
    }

    private mutating func resolveDirectory(relativeDirectory: String) -> DirectoryPathStatus {
      var currentURL = rootURL
      var components: [String] = []
      for component in relativeDirectory.split(separator: "/").map(String.init) {
        currentURL.appendPathComponent(component, isDirectory: true)
        components.append(component)
        guard appendNode(at: currentURL, relativePath: components.joined(separator: "/"))
        else {
          return .unavailable
        }
        switch directoryStatus(at: currentURL) {
        case .directory:
          continue
        case .stopped:
          return .stopped
        case .unavailable:
          return .unavailable
        }
      }
      return .directory(currentURL)
    }

    private mutating func appendNode(at url: URL, relativePath: String) -> Bool {
      guard nodes.count < ThemeShortcodeCatalogCacheKey.maximumFingerprintEntries else {
        didExceedLimit = true
        return false
      }
      var status = stat()
      if Darwin.lstat(url.path, &status) == 0 {
        nodes.append(
          Node(
            path: relativePath,
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode),
            size: Int64(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changedSeconds: Int64(status.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(status.st_ctimespec.tv_nsec),
            isMissing: false
          )
        )
        return true
      }
      guard errno == ENOENT else { return false }
      nodes.append(
        Node(
          path: relativePath,
          device: 0,
          inode: 0,
          mode: 0,
          size: 0,
          modifiedSeconds: 0,
          modifiedNanoseconds: 0,
          changedSeconds: 0,
          changedNanoseconds: 0,
          isMissing: true
        )
      )
      return true
    }

    private func isDirectory(_ url: URL) -> Bool {
      if case .directory = directoryStatus(at: url) {
        return true
      }
      return false
    }

    private func directoryStatus(at url: URL) -> DirectoryPathStatus {
      var status = stat()
      guard Darwin.lstat(url.path, &status) == 0 else {
        return errno == ENOENT ? .stopped : .unavailable
      }
      return (status.st_mode & S_IFMT) == S_IFDIR ? .directory(url) : .stopped
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
      var status = stat()
      guard Darwin.lstat(url.path, &status) == 0 else { return false }
      return (status.st_mode & S_IFMT) == S_IFLNK
    }

    private func repositoryPath(of url: URL) -> String? {
      let rootPath = rootURL.path
      let path = url.standardizedFileURL.path
      guard path.hasPrefix(rootPath + "/") else { return nil }
      return String(path.dropFirst(rootPath.count + 1))
    }

    private func depth(of url: URL, below root: URL) -> Int {
      let rootPath = root.standardizedFileURL.path
      let path = url.standardizedFileURL.path
      guard path.hasPrefix(rootPath + "/") else { return .max }
      return path.dropFirst(rootPath.count + 1).split(separator: "/").count
    }

    private func isSafeThemeName(_ value: String) -> Bool {
      !value.isEmpty && !value.contains(".")
        && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
  }
}
