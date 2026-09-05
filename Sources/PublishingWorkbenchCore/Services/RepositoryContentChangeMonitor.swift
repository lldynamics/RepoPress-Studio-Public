import Combine
import CoreServices
import Foundation

struct RepositoryContentChangeEventFlags: OptionSet, Sendable {
  let rawValue: UInt32

  static let mustScanSubDirs = Self(rawValue: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
  static let userDropped = Self(rawValue: UInt32(kFSEventStreamEventFlagUserDropped))
  static let kernelDropped = Self(rawValue: UInt32(kFSEventStreamEventFlagKernelDropped))
  static let eventIdsWrapped = Self(rawValue: UInt32(kFSEventStreamEventFlagEventIdsWrapped))
  static let rootChanged = Self(rawValue: UInt32(kFSEventStreamEventFlagRootChanged))
  static let itemIsDir = Self(rawValue: UInt32(kFSEventStreamEventFlagItemIsDir))
  static let itemRemoved = Self(rawValue: UInt32(kFSEventStreamEventFlagItemRemoved))
  static let itemRenamed = Self(rawValue: UInt32(kFSEventStreamEventFlagItemRenamed))
  static let itemCreated = Self(rawValue: UInt32(kFSEventStreamEventFlagItemCreated))
  static let itemModified = Self(rawValue: UInt32(kFSEventStreamEventFlagItemModified))
  static let itemInodeMetaMod = Self(rawValue: UInt32(kFSEventStreamEventFlagItemInodeMetaMod))
}

enum RepositoryContentChangeEventDecision: Equatable, Sendable {
  case ignore
  case fullScan
  case paths([String])

  static func classify(
    flags: RepositoryContentChangeEventFlags,
    relativePath: String?,
    allowedPrefixes: [String]
  ) -> Self {
    let mustFullScan = flags.intersection([
      .mustScanSubDirs,
      .userDropped,
      .kernelDropped,
      .eventIdsWrapped,
      .rootChanged,
    ]).isEmpty == false
    if mustFullScan {
      return .fullScan
    }
    guard let relativePath else { return .ignore }
    let normalizedPath = relativePath.normalizedRelativePath()
    let isWithinAllowedPrefix = allowedPrefixes.isEmpty
      || allowedPrefixes.contains {
        let prefix = $0.normalizedRelativePath()
        return normalizedPath == prefix || normalizedPath.hasPrefix(prefix + "/")
      }
    guard isWithinAllowedPrefix else { return .ignore }
    let components = normalizedPath.split(separator: "/").map(String.init)
    let noiseDirectories: Set<String> = [".build", "dist", "public"]
    if let topLevelComponent = components.first,
      noiseDirectories.contains(topLevelComponent)
    {
      return .ignore
    }
    if components.first == ".git" {
      let metadataPath = components.dropFirst().joined(separator: "/")
      if metadataPath == "objects" || metadataPath.hasPrefix("objects/")
        || metadataPath == "logs" || metadataPath.hasPrefix("logs/")
      { return .ignore }
      return .fullScan
    }
    if flags.contains(.itemIsDir) {
      let isTopologyChange = flags.intersection([
        .itemCreated,
        .itemRemoved,
        .itemRenamed,
      ]).isEmpty == false
      return isTopologyChange ? .fullScan : .ignore
    }
    guard flags.intersection([
        .itemCreated,
        .itemRemoved,
        .itemRenamed,
        .itemModified,
        .itemInodeMetaMod,
      ]).isEmpty == false
    else {
      return .ignore
    }
    let extensionName = (normalizedPath as NSString).pathExtension.lowercased()
    if ["md", "markdown", "mdx"].contains(extensionName) {
      return flags.contains(.itemRemoved) || flags.contains(.itemRenamed)
        ? .fullScan : .paths([normalizedPath])
    }
    return .fullScan
  }
}

/// Delivers path-level file-system changes for a repository content subtree.
///
/// FSEvents is configured for file events and meaningful events are coalesced
/// into one scan/import decision. Scanning is authoritative; path values only
/// optimize importing unknown Markdown candidates.
public final class RepositoryContentChangeMonitor: @unchecked Sendable {
  public static let defaultDebounceInterval: TimeInterval = 0.35
  public typealias ChangeHandler = @Sendable ([String]?) -> Void

  private let debounceInterval: TimeInterval
  private let onChange: ChangeHandler
  private let queue: DispatchQueue
  private let stateLock = NSLock()
  private var isActive = false
  private var generation: UInt64 = 0
  private var configuredRepositoryRootPath: String?
  private var configuredWatchedPath: String?
  private var configuredAllowedRelativePrefixes: [String] = []
  private var stream: FSEventStreamRef?
  private var eventContext: UnsafeMutablePointer<FSEventStreamContext>?
  private var debounceWorkItem: DispatchWorkItem?
  private var pendingPaths = Set<String>()
  private var pendingFullScan = false

  public init(
    debounceInterval: TimeInterval = RepositoryContentChangeMonitor.defaultDebounceInterval,
    onChange: @escaping ChangeHandler
  ) {
    self.debounceInterval = max(0, debounceInterval)
    self.onChange = onChange
    queue = DispatchQueue(
      label: "com.jinfang.PersonalSitePublisherMac.repository-content-change-monitor",
      qos: .utility
    )
  }

  /// Starts or rebuilds the stream for one content subtree. The callback
  /// paths are repository-relative Markdown paths, not absolute file paths.
  public func reconfigure(
    repositoryRootPath: String?,
    watchedPath: String?,
    allowedRelativePrefixes: [String] = []
  ) {
    let normalizedRepositoryRoot = Self.normalizedPath(repositoryRootPath)
    let normalizedWatchedPath = Self.normalizedPath(watchedPath)
    let normalizedPrefixes = allowedRelativePrefixes
      .map { $0.normalizedRelativePath() }
      .filter { !$0.isEmpty }
      .sorted()
    guard normalizedRepositoryRoot != nil, normalizedWatchedPath != nil else {
      stop()
      return
    }

    stateLock.lock()
    if isActive,
      configuredRepositoryRootPath == normalizedRepositoryRoot,
      configuredWatchedPath == normalizedWatchedPath,
      configuredAllowedRelativePrefixes == normalizedPrefixes
    {
      stateLock.unlock()
      return
    }
    generation &+= 1
    let currentGeneration = generation
    isActive = true
    configuredRepositoryRootPath = normalizedRepositoryRoot
    configuredWatchedPath = normalizedWatchedPath
    configuredAllowedRelativePrefixes = normalizedPrefixes
    stateLock.unlock()

    queue.async { [weak self] in
      guard let self else { return }
      self.stopStream()
      self.cancelDebounce()
      guard self.isCurrent(generation: currentGeneration),
        let normalizedRepositoryRoot,
        let normalizedWatchedPath
      else {
        return
      }
      self.startStream(
        repositoryRootPath: normalizedRepositoryRoot,
        watchedPath: normalizedWatchedPath,
        generation: currentGeneration
      )
    }
  }

  public func stop() {
    stateLock.lock()
    generation &+= 1
    isActive = false
    configuredRepositoryRootPath = nil
    configuredWatchedPath = nil
    configuredAllowedRelativePrefixes = []
    stateLock.unlock()

    queue.async { [weak self] in
      guard let self else { return }
      self.stopStream()
      self.cancelDebounce()
      self.pendingPaths.removeAll()
      self.pendingFullScan = false
    }
  }

  private func startStream(
    repositoryRootPath: String,
    watchedPath: String,
    generation: UInt64
  ) {
    let context = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
    context.initialize(
      to: FSEventStreamContext(
        version: 0,
        info: Unmanaged.passUnretained(self).toOpaque(),
        retain: { info in
          guard let info else { return nil }
          let retained = Unmanaged<RepositoryContentChangeMonitor>
            .fromOpaque(info)
            .retain()
            .toOpaque()
          return UnsafeRawPointer(retained)
        },
        release: { info in
          guard let info else { return }
          Unmanaged<RepositoryContentChangeMonitor>
            .fromOpaque(info)
            .release()
        },
        copyDescription: nil
      )
    )
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents
        | kFSEventStreamCreateFlagNoDefer
    )
    guard let stream = FSEventStreamCreate(
      nil,
      Self.eventCallback,
      context,
      [watchedPath] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.15,
      flags
    ) else {
      context.deinitialize(count: 1)
      context.deallocate()
      return
    }
    guard isCurrent(generation: generation) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      context.deinitialize(count: 1)
      context.deallocate()
      return
    }
    self.eventContext = context
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
    _ = repositoryRootPath
  }

  private func stopStream() {
    if let stream {
      FSEventStreamSetDispatchQueue(stream, nil)
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
    if let eventContext {
      eventContext.deinitialize(count: 1)
      eventContext.deallocate()
      self.eventContext = nil
    }
  }

  private static let eventCallback: FSEventStreamCallback = {
    _, clientCallBackInfo, numberOfEvents, eventPaths, eventFlags, _ in
    guard let clientCallBackInfo, numberOfEvents > 0 else { return }
    let monitor = Unmanaged<RepositoryContentChangeMonitor>
      .fromOpaque(clientCallBackInfo)
      .takeUnretainedValue()
    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    let flags = eventFlags
    for index in 0..<numberOfEvents {
      monitor.handle(
        eventPath: String(cString: paths[index]),
        flags: flags[index]
      )
    }
  }

  private func handle(eventPath: String, flags: FSEventStreamEventFlags) {
    guard isActiveNow() else { return }
    guard let repositoryRootPath = configuredRepositoryRootPathNow else { return }
    let normalizedPath = Self.normalizedPath(eventPath) ?? eventPath
    let relativePath: String?
    if normalizedPath == repositoryRootPath {
      relativePath = ""
    } else if normalizedPath.hasPrefix(repositoryRootPath + "/") {
      relativePath = String(normalizedPath.dropFirst(repositoryRootPath.count + 1))
    } else {
      relativePath = nil
    }
    let decision = RepositoryContentChangeEventDecision.classify(
      flags: RepositoryContentChangeEventFlags(rawValue: flags),
      relativePath: relativePath,
      allowedPrefixes: configuredAllowedRelativePrefixesNow
    )
    switch decision {
    case .ignore:
      return
    case .fullScan:
      scheduleNotification(paths: nil, requiresFullScan: true)
    case .paths(let paths):
      scheduleNotification(paths: paths, requiresFullScan: false)
    }
  }

  private func scheduleNotification(paths: [String]?, requiresFullScan: Bool) {
    guard isActiveNow() else { return }
    if requiresFullScan {
      pendingFullScan = true
      pendingPaths.removeAll()
    } else if !pendingFullScan {
      pendingPaths.formUnion(paths ?? [])
    }
    debounceWorkItem?.cancel()
    let eventGeneration = currentGeneration
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.isCurrent(generation: eventGeneration) else { return }
      let shouldRunFullScan = self.pendingFullScan
      let changedPaths = shouldRunFullScan ? nil : Array(self.pendingPaths).sorted()
      self.pendingPaths.removeAll()
      self.pendingFullScan = false
      self.debounceWorkItem = nil
      guard shouldRunFullScan || !(changedPaths ?? []).isEmpty else { return }
      self.onChange(changedPaths)
    }
    debounceWorkItem = workItem
    queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
  }

  private var currentGeneration: UInt64 {
    stateLock.lock()
    defer { stateLock.unlock() }
    return generation
  }

  private var configuredRepositoryRootPathNow: String? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return configuredRepositoryRootPath
  }

  private var configuredAllowedRelativePrefixesNow: [String] {
    stateLock.lock()
    defer { stateLock.unlock() }
    return configuredAllowedRelativePrefixes
  }

  private func isActiveNow() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return isActive
  }

  private func isCurrent(generation eventGeneration: UInt64) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return isActive && generation == eventGeneration
  }

  private func cancelDebounce() {
    debounceWorkItem?.cancel()
    debounceWorkItem = nil
    pendingPaths.removeAll()
    pendingFullScan = false
  }

  private static func normalizedPath(_ path: String?) -> String? {
    guard let path, !path.trimmedForPublishing.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }
}

/// Binds repository content watching to the active workbench profile while
/// keeping profile changes out of the root view's high-frequency observation
/// path. Only low-frequency profile/active-profile/quick-hide publishers are
/// observed here.
@MainActor
public final class RepositoryContentChangeMonitorCoordinator: ObservableObject {
  private final class WeakCoordinatorBox {
    weak var value: RepositoryContentChangeMonitorCoordinator?

    init(_ value: RepositoryContentChangeMonitorCoordinator) {
      self.value = value
    }
  }

  private static var sharedByStore: [ObjectIdentifier: WeakCoordinatorBox] = [:]

  private final class EventSink: @unchecked Sendable {
    weak var owner: RepositoryContentChangeMonitorCoordinator?

    func notify(paths: [String]?) {
      Task { @MainActor [weak owner] in
        owner?.handleFileChange(paths: paths)
      }
    }
  }

  private struct WatchPath: Equatable {
    let repositoryRootPath: String
    let watchedPath: String
    let allowedRelativePrefixes: [String]
  }

  private unowned let store: WorkbenchStore
  private let eventSink: EventSink
  private let monitors: [RepositoryContentChangeMonitor]
  private var cancellables = Set<AnyCancellable>()
  private var isStarted = false
  private var activeClientIDs = Set<UUID>()
  private var needsFullDiscovery = true
  private var importTask: Task<Void, Never>?
  /// Monotonically identifies the task that currently owns `importTask`.
  /// Cancellation is cooperative, so an older task can still resume after a
  /// replacement task has started. Such a task must not clear the replacement
  /// handle or consume its pending paths.
  private var importRequestID: UInt64 = 0
  private var importPendingPaths = Set<String>()
  private var importPendingFullScan = false
  private var configurationTask: Task<Void, Never>?

  public init(store: WorkbenchStore) {
    self.store = store
    let eventSink = EventSink()
    self.eventSink = eventSink
    self.monitors = [
      RepositoryContentChangeMonitor { paths in eventSink.notify(paths: paths) }
    ]
    eventSink.owner = self
    observeProfileChanges()
  }

  deinit {
    monitors.forEach { $0.stop() }
  }

  public static func shared(store: WorkbenchStore) -> RepositoryContentChangeMonitorCoordinator {
    let key = ObjectIdentifier(store)
    sharedByStore = sharedByStore.filter { $0.value.value != nil }
    if let existing = sharedByStore[key]?.value {
      return existing
    }
    let coordinator = RepositoryContentChangeMonitorCoordinator(store: store)
    sharedByStore[key] = WeakCoordinatorBox(coordinator)
    return coordinator
  }

  public func start(clientID: UUID) {
    activeClientIDs.insert(clientID)
    guard !isStarted else {
      configureMonitorsIfNeeded()
      return
    }
    isStarted = true
    needsFullDiscovery = true
    configureMonitorsIfNeeded()
  }

  public func stop(clientID: UUID) {
    activeClientIDs.remove(clientID)
    guard activeClientIDs.isEmpty else { return }
    isStarted = false
    configurationTask?.cancel()
    configurationTask = nil
    cancelPendingImport()
    needsFullDiscovery = true
    monitors.forEach { $0.stop() }
  }

  /// Performs the initial/explicit automatic discovery using the full index
  /// path. File events use `requestImport(repositoryPaths:)` below instead.
  public func requestImport() {
    guard isStarted, !store.isSafeMode, store.canUseProtectedWorkbench,
      needsFullDiscovery else { return }
    needsFullDiscovery = false
    requestImport(repositoryPaths: nil)
  }

  private func requestImport(repositoryPaths: [String]?) {
    guard isStarted, !store.isSafeMode, store.canUseProtectedWorkbench else { return }
    guard importTask == nil else {
      if let repositoryPaths {
        importPendingPaths.formUnion(repositoryPaths)
      } else {
        importPendingFullScan = true
        importPendingPaths.removeAll()
      }
      return
    }

    let profileID = store.activeProfileID
    importRequestID &+= 1
    let requestID = importRequestID
    importTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.store.repositoryStore.scanRepositoryAsync(store: self.store)
      guard self.importRequestID == requestID,
        !Task.isCancelled,
        self.store.activeProfileID == profileID
      else {
        if self.importRequestID == requestID {
          self.importTask = nil
        }
        return
      }
      if self.shouldRunAutomatically {
        if let repositoryPaths {
          _ = await self.store.importMissingDraftsFromLocalRepository(
            repositoryPaths: repositoryPaths
          )
        } else {
          _ = await self.store.importMissingDraftsFromLocalRepository()
        }
      }
      guard self.importRequestID == requestID,
        !Task.isCancelled,
        self.store.activeProfileID == profileID
      else {
        if self.importRequestID == requestID {
          self.importTask = nil
        }
        return
      }
      await self.store.refreshBatchPublishPlanAsync()
      guard self.importRequestID == requestID else { return }
      guard !Task.isCancelled else {
        self.importTask = nil
        return
      }
      self.importTask = nil
      guard self.store.activeProfileID == profileID else {
        self.importPendingPaths.removeAll()
        self.importPendingFullScan = false
        return
      }
      if self.importPendingFullScan {
        self.importPendingFullScan = false
        self.importPendingPaths.removeAll()
        self.requestImport(repositoryPaths: nil)
      } else if !self.importPendingPaths.isEmpty {
        let pendingPaths = Array(self.importPendingPaths).sorted()
        self.importPendingPaths.removeAll()
        self.requestImport(repositoryPaths: pendingPaths)
      }
    }
  }

  private var shouldRunAutomatically: Bool {
    !store.isSafeMode
      && store.canUseProtectedWorkbench
      && store.activeProfile.resolvedAutomaticallyImportsNewRepositoryArticles
  }

  private func handleFileChange(paths: [String]?) {
    guard isStarted else { return }
    requestImport(repositoryPaths: paths)
  }

  private func observeProfileChanges() {
    store.publishingStore.$profiles
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.scheduleConfiguration() }
      .store(in: &cancellables)
    store.publishingStore.$activeProfileID
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.scheduleConfiguration() }
      .store(in: &cancellables)
    store.privacyProtectionStore.$isQuickHideActive
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.scheduleConfiguration() }
      .store(in: &cancellables)
  }

  private func scheduleConfiguration() {
    guard isStarted, configurationTask == nil else { return }
    configurationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await Task.yield()
      guard !Task.isCancelled else { return }
      self.configurationTask = nil
      self.cancelPendingImport()
      self.needsFullDiscovery = true
      self.configureMonitorsIfNeeded()
      self.requestImport()
    }
  }

  private func configureMonitorsIfNeeded() {
    let paths: [WatchPath]
    if isStarted,
      !store.isSafeMode,
      store.canUseProtectedWorkbench
    {
      paths = repositoryContentWatchPaths(for: store.activeProfile)
    } else {
      paths = []
    }
    if paths.isEmpty {
      cancelPendingImport()
    }
    for (index, monitor) in monitors.enumerated() {
      guard paths.indices.contains(index) else {
        monitor.stop()
        continue
      }
      let path = paths[index]
      monitor.reconfigure(
        repositoryRootPath: path.repositoryRootPath,
        watchedPath: path.watchedPath,
        allowedRelativePrefixes: path.allowedRelativePrefixes
      )
    }
  }

  private func repositoryContentWatchPaths(for profile: SiteProfile) -> [WatchPath] {
    guard let rootURL = profile.localRepositoryRootURL else { return [] }
    let rootPath = rootURL.standardizedFileURL.path
    return [
      WatchPath(
        repositoryRootPath: rootPath,
        watchedPath: rootPath,
        // Repository-level watching is required for static/configuration and
        // Git metadata changes. Import still filters candidates to Markdown.
        allowedRelativePrefixes: []
      )
    ]
  }

  private func cancelPendingImport() {
    importRequestID &+= 1
    importPendingPaths.removeAll()
    importPendingFullScan = false
    importTask?.cancel()
    importTask = nil
  }
}
