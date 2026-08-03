import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Watches only source directories below a canonical repository root.
/// Generated output and dependency trees are deliberately excluded because
/// they are noisy, can be very large, and are not safe reload triggers.
public final class LocalSitePreviewFileWatcher: @unchecked Sendable {
  private static let baseExcludedDirectoryNames: Set<String> = [
    ".build",
    ".cache",
    ".git",
    ".next",
    "_site",
    "dist",
    "node_modules",
    "target"
  ]

  private let rootPath: String
  private let maximumDirectoryCount: Int
  private let excludedDirectoryNames: Set<String>
  private let onChange: @Sendable () -> Void
  private let queue: DispatchQueue
  private let stateLock = NSLock()
  private var isActive = false
  private var rebuildScheduled = false
  private var sources: [Int32: DispatchSourceFileSystemObject] = [:]

  public init(
    rootPath: String,
    siteKind: SiteKind? = nil,
    maximumDirectoryCount: Int = 512,
    onChange: @escaping @Sendable () -> Void
  ) {
    self.rootPath = URL(fileURLWithPath: rootPath, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
    self.maximumDirectoryCount = max(1, maximumDirectoryCount)
    self.excludedDirectoryNames = Self.baseExcludedDirectoryNames
      .union(siteKind.map { Self.generatedDirectoryNames(for: $0) } ?? [])
    self.onChange = onChange
    queue = DispatchQueue(
      label: "com.jinfang.PersonalSitePublisherMac.local-preview-file-watcher",
      qos: .utility
    )
  }

  public var watchedDirectoryCount: Int {
    queue.sync { sources.count }
  }

  public func start() {
    stateLock.lock()
    guard !isActive else {
      stateLock.unlock()
      return
    }
    isActive = true
    stateLock.unlock()
    queue.async { [weak self] in
      self?.rebuildSources()
    }
  }

  public func stop() {
    stateLock.lock()
    isActive = false
    stateLock.unlock()
    queue.async { [weak self] in
      guard let self else { return }
      self.cancelSources()
      self.rebuildScheduled = false
    }
  }

  private func isActiveNow() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return isActive
  }

  private func rebuildSources() {
    guard isActiveNow() else { return }
    cancelSources()
    for directoryPath in directoryPaths() {
      guard let descriptor = openDirectory(at: directoryPath) else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
        queue: queue
      )
      source.setEventHandler { [weak self, weak source] in
        guard let self, let source else { return }
        self.handle(event: source.data)
      }
      source.setCancelHandler {
        close(descriptor)
      }
      sources[descriptor] = source
      source.resume()
    }
  }

  private func handle(event: DispatchSource.FileSystemEvent) {
    guard isActiveNow() else { return }
    onChange()
    let topologyChanged = event.intersection([.link, .rename, .delete, .revoke]) != []
    guard topologyChanged else { return }
    guard !rebuildScheduled else { return }
    rebuildScheduled = true
    queue.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
      guard let self else { return }
      self.rebuildScheduled = false
      self.rebuildSources()
    }
  }

  private func cancelSources() {
    let currentSources = sources.values
    sources.removeAll()
    currentSources.forEach { $0.cancel() }
  }

  private func directoryPaths() -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
      return []
    }

    var paths = [rootPath]
    guard let enumerator = FileManager.default.enumerator(
      at: URL(fileURLWithPath: rootPath, isDirectory: true),
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsPackageDescendants]
    ) else {
      return paths
    }

    while let item = enumerator.nextObject() as? URL {
      let itemPath = item.standardizedFileURL.path
      guard itemPath == rootPath || itemPath.hasPrefix(rootPath + "/") else {
        enumerator.skipDescendants()
        continue
      }
      guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true else {
        continue
      }
      if values.isSymbolicLink == true || excludedDirectoryNames.contains(item.lastPathComponent) {
        enumerator.skipDescendants()
        continue
      }
      paths.append(itemPath)
      if paths.count >= maximumDirectoryCount {
        break
      }
    }
    return paths
  }

  private func openDirectory(at path: String) -> Int32? {
#if canImport(Darwin)
    let descriptor = open(path, O_EVTONLY)
    return descriptor >= 0 ? descriptor : nil
#else
    let descriptor = open(path, O_RDONLY)
    return descriptor >= 0 ? descriptor : nil
#endif
  }

  private static func generatedDirectoryNames(for siteKind: SiteKind) -> Set<String> {
    switch siteKind {
    case .astro:
      return []
    case .zola, .hugo, .hexo:
      return ["public"]
    case .jekyll:
      return []
    }
  }
}
