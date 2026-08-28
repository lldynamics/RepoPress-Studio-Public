import Foundation
#if canImport(Darwin)
  import Darwin
#endif

public struct LocalSitePreviewFileChange: Equatable, Sendable {
  /// True only when the execution manifest set (for example package.json or
  /// Gemfile) differs from the authorized/baseline snapshot.
  public let executionConfigurationChanged: Bool

  public init(executionConfigurationChanged: Bool) {
    self.executionConfigurationChanged = executionConfigurationChanged
  }
}

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
    "target",
  ]

  private let rootPath: String
  private let siteKind: SiteKind?
  private let expectedExecutionManifestDigest: String?
  private let maximumDirectoryCount: Int
  private let excludedDirectoryNames: Set<String>
  private let onChange: @Sendable (LocalSitePreviewFileChange) -> Void
  private let queue: DispatchQueue
  private let stateLock = NSLock()
  private var isActive = false
  private var activationGeneration: UInt64 = 0
  private var rebuildScheduled = false
  private var changeDeliveryScheduled = false
  private var sources: [Int32: DispatchSourceFileSystemObject] = [:]
  private var directorySourceDescriptors: Set<Int32> = []
  private var executionConfigurationSnapshot: ExecutionConfigurationSnapshot

  public convenience init(
    rootPath: String,
    siteKind: SiteKind? = nil,
    maximumDirectoryCount: Int = 512,
    expectedExecutionManifestDigest: String? = nil,
    onChange: @escaping @Sendable () -> Void
  ) {
    self.init(
      rootPath: rootPath,
      siteKind: siteKind,
      maximumDirectoryCount: maximumDirectoryCount,
      expectedExecutionManifestDigest: expectedExecutionManifestDigest
    ) { _ in onChange() }
  }

  public init(
    rootPath: String,
    siteKind: SiteKind? = nil,
    maximumDirectoryCount: Int = 512,
    expectedExecutionManifestDigest: String? = nil,
    onChange: @escaping @Sendable (LocalSitePreviewFileChange) -> Void
  ) {
    self.rootPath =
      URL(fileURLWithPath: rootPath, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
    self.maximumDirectoryCount = max(1, maximumDirectoryCount)
    self.siteKind = siteKind
    self.expectedExecutionManifestDigest = expectedExecutionManifestDigest
    self.excludedDirectoryNames = Self.baseExcludedDirectoryNames
      .union(siteKind.map { Self.generatedDirectoryNames(for: $0) } ?? [])
    self.onChange = onChange
    executionConfigurationSnapshot = .notApplicable
    queue = DispatchQueue(
      label: "com.jinfang.PersonalSitePublisherMac.local-preview-file-watcher",
      qos: .utility
    )
  }

  public var watchedDirectoryCount: Int {
    queue.sync { directorySourceDescriptors.count }
  }

  public func start() {
    stateLock.lock()
    guard !isActive else {
      stateLock.unlock()
      return
    }
    isActive = true
    activationGeneration &+= 1
    let generation = activationGeneration
    stateLock.unlock()
    queue.async { [weak self] in
      guard let self else { return }
      guard self.isActive(generation: generation) else { return }
      self.executionConfigurationSnapshot = self.expectedExecutionConfigurationSnapshot
      // Register directory sources before capturing the current manifest. A
      // change after registration is therefore either caught by the initial
      // comparison or by a queued file-system event.
      self.rebuildSources(generation: generation)
      guard self.isActive(generation: generation) else { return }
      let updatedSnapshot = self.captureExecutionConfigurationSnapshot()
      let configurationChanged =
        self.expectedExecutionManifestDigest != nil
        && (updatedSnapshot.requiresInvalidation
          || updatedSnapshot != self.executionConfigurationSnapshot)
      self.executionConfigurationSnapshot = updatedSnapshot
      if configurationChanged {
        self.onChange(LocalSitePreviewFileChange(executionConfigurationChanged: true))
      }
    }
  }

  public func stop() {
    stateLock.lock()
    isActive = false
    activationGeneration &+= 1
    stateLock.unlock()
    queue.async { [weak self] in
      guard let self else { return }
      self.cancelSources()
      self.rebuildScheduled = false
      self.changeDeliveryScheduled = false
    }
  }

  private func isActive(generation: UInt64) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return isActive && activationGeneration == generation
  }

  private func rebuildSources(generation: UInt64) {
    guard isActive(generation: generation) else { return }
    cancelSources()
    for directoryPath in directoryPaths() {
      installSource(at: directoryPath, isDirectory: true, generation: generation)
    }
    guard let siteKind else { return }
    let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
    for relativePath in LocalSitePreviewExecutionFingerprint.manifestRelativePaths(for: siteKind) {
      installSource(
        at: rootURL.appendingPathComponent(relativePath, isDirectory: false).path,
        isDirectory: false,
        generation: generation
      )
    }
  }

  private func installSource(
    at path: String,
    isDirectory: Bool,
    generation: UInt64
  ) {
    guard let descriptor = openFileSystemObject(at: path) else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
      queue: queue
    )
    source.setEventHandler { [weak self, weak source] in
      guard let self, let source else { return }
      self.handle(event: source.data, generation: generation)
    }
    source.setCancelHandler {
      close(descriptor)
    }
    sources[descriptor] = source
    if isDirectory {
      directorySourceDescriptors.insert(descriptor)
    }
    source.resume()
  }

  private func handle(event: DispatchSource.FileSystemEvent, generation: UInt64) {
    guard isActive(generation: generation) else { return }
    scheduleChangeDelivery(generation: generation)
    let topologyChanged = event.intersection([.link, .rename, .delete, .revoke]) != []
    guard topologyChanged else { return }
    guard !rebuildScheduled else { return }
    rebuildScheduled = true
    queue.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
      guard let self else { return }
      guard self.isActive(generation: generation) else { return }
      self.rebuildScheduled = false
      self.rebuildSources(generation: generation)
    }
  }

  /// File descriptors report directory-level events, not stable child paths.
  /// Hash the tiny manifest set once per coalesced batch to classify a change
  /// without re-validating the complete execution plan on the MainActor.
  private func scheduleChangeDelivery(generation: UInt64) {
    guard !changeDeliveryScheduled else { return }
    changeDeliveryScheduled = true
    queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
      guard let self else { return }
      guard self.isActive(generation: generation) else { return }
      self.changeDeliveryScheduled = false
      let updatedSnapshot = self.captureExecutionConfigurationSnapshot()
      let configurationChanged =
        updatedSnapshot.requiresInvalidation
        || updatedSnapshot != self.executionConfigurationSnapshot
      self.executionConfigurationSnapshot = updatedSnapshot
      self.onChange(
        LocalSitePreviewFileChange(
          executionConfigurationChanged: configurationChanged
        )
      )
    }
  }

  private func captureExecutionConfigurationSnapshot() -> ExecutionConfigurationSnapshot {
    guard let siteKind else { return .notApplicable }
    do {
      return .digest(
        try LocalSitePreviewExecutionFingerprint.manifestDigest(
          rootPath: rootPath,
          siteKind: siteKind
        )
      )
    } catch {
      // A manifest that becomes unreadable must conservatively invalidate the
      // authorized execution plan instead of being treated as ordinary content.
      return .unreadable
    }
  }

  private var expectedExecutionConfigurationSnapshot: ExecutionConfigurationSnapshot {
    expectedExecutionManifestDigest.map(ExecutionConfigurationSnapshot.digest)
      ?? .notApplicable
  }

  private func cancelSources() {
    let currentSources = sources.values
    sources.removeAll()
    directorySourceDescriptors.removeAll()
    for source in currentSources {
      source.cancel()
    }
  }

  private func directoryPaths() -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return []
    }

    var paths = [rootPath]
    guard
      let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: rootPath, isDirectory: true),
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsPackageDescendants]
      )
    else {
      return paths
    }

    while let item = enumerator.nextObject() as? URL {
      let itemPath = item.standardizedFileURL.path
      guard itemPath == rootPath || itemPath.hasPrefix(rootPath + "/") else {
        enumerator.skipDescendants()
        continue
      }
      guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        values.isDirectory == true
      else {
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

  private func openFileSystemObject(at path: String) -> Int32? {
    #if canImport(Darwin)
      let descriptor = open(path, O_EVTONLY | O_NOFOLLOW)
      return descriptor >= 0 ? descriptor : nil
    #else
      let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
      return descriptor >= 0 ? descriptor : nil
    #endif
  }

  private static func generatedDirectoryNames(for siteKind: SiteKind) -> Set<String> {
    switch siteKind {
    case .astro:
      return []
    case .vitePress:
      return ["dist"]
    case .nextJS:
      return [".next", "out"]
    case .quartz:
      return [".quartz-cache", "public"]
    case .zola, .hugo, .hexo:
      return ["public"]
    case .jekyll, .foam:
      return []
    }
  }
}

private enum ExecutionConfigurationSnapshot: Equatable {
  case notApplicable
  case digest(String)
  case unreadable

  var requiresInvalidation: Bool {
    self == .unreadable
  }
}
