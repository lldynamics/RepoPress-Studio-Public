import Foundation

public struct WorkbenchDataRootBookmarkRecord: Codable, Equatable, Sendable {
  public var bookmarkData: Data
  public var displayPath: String
  /// A single child-directory name below the bookmarked Powerbox URL.
  /// Existing/restored roots are bookmarked directly and keep this `nil`.
  public var relativeRootPath: String?
  public var dataID: UUID?
  public var updatedAt: Date

  public init(
    bookmarkData: Data,
    displayPath: String,
    relativeRootPath: String? = nil,
    dataID: UUID? = nil,
    updatedAt: Date = Date()
  ) {
    self.bookmarkData = bookmarkData
    self.displayPath = displayPath
    self.relativeRootPath = relativeRootPath
    self.dataID = dataID
    self.updatedAt = updatedAt
  }
}

public struct WorkbenchDataRootDecodedBookmark: Equatable, Sendable {
  public var url: URL
  public var isStale: Bool

  public init(url: URL, isStale: Bool) {
    self.url = url.standardizedFileURL
    self.isStale = isStale
  }
}

public struct WorkbenchDataRootBookmarkCodec: Sendable {
  public typealias CreateBookmark = @Sendable (URL) throws -> Data
  public typealias ResolveBookmark = @Sendable (Data) throws -> WorkbenchDataRootDecodedBookmark

  private let createBookmark: CreateBookmark
  private let resolveBookmark: ResolveBookmark

  public init(
    create: @escaping CreateBookmark,
    resolve: @escaping ResolveBookmark
  ) {
    self.createBookmark = create
    self.resolveBookmark = resolve
  }

  public func create(for url: URL) throws -> Data {
    try createBookmark(url.standardizedFileURL)
  }

  public func resolve(_ data: Data) throws -> WorkbenchDataRootDecodedBookmark {
    try resolveBookmark(data)
  }

  public static let securityScoped = WorkbenchDataRootBookmarkCodec(
    create: { url in
      try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    },
    resolve: { data in
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      return WorkbenchDataRootDecodedBookmark(url: url, isStale: isStale)
    }
  )
}

public struct WorkbenchDataRootSecurityScope: Sendable {
  public typealias StartAccess = @Sendable (URL) -> Bool
  public typealias StopAccess = @Sendable (URL) -> Void

  private let startAccess: StartAccess
  private let stopAccess: StopAccess

  public init(
    start: @escaping StartAccess,
    stop: @escaping StopAccess
  ) {
    self.startAccess = start
    self.stopAccess = stop
  }

  public func makeLease(for rootURL: URL) -> WorkbenchDataRootAccessLease {
    let standardizedURL = rootURL.standardizedFileURL
    return WorkbenchDataRootAccessLease(
      rootURL: standardizedURL,
      didStartAccess: startAccess(standardizedURL),
      stopAccess: stopAccess
    )
  }

  public static let live = WorkbenchDataRootSecurityScope(
    start: { $0.startAccessingSecurityScopedResource() },
    stop: { $0.stopAccessingSecurityScopedResource() }
  )
}

/// Retains security-scoped access until the owning data-root session is released.
public final class WorkbenchDataRootAccessLease: Sendable {
  public let rootURL: URL
  public let didStartAccess: Bool

  private let stopAccess: WorkbenchDataRootSecurityScope.StopAccess

  fileprivate init(
    rootURL: URL,
    didStartAccess: Bool,
    stopAccess: @escaping WorkbenchDataRootSecurityScope.StopAccess
  ) {
    self.rootURL = rootURL
    self.didStartAccess = didStartAccess
    self.stopAccess = stopAccess
  }

  deinit {
    if didStartAccess {
      stopAccess(rootURL)
    }
  }
}

public final class WorkbenchDataRootSession: Sendable {
  public let layout: WorkbenchDataRootLayout
  public let bookmarkRecord: WorkbenchDataRootBookmarkRecord
  public let probeResult: WorkbenchDataRootProbeResult

  private let accessLease: WorkbenchDataRootAccessLease

  fileprivate init(
    layout: WorkbenchDataRootLayout,
    bookmarkRecord: WorkbenchDataRootBookmarkRecord,
    probeResult: WorkbenchDataRootProbeResult,
    accessLease: WorkbenchDataRootAccessLease
  ) {
    self.layout = layout
    self.bookmarkRecord = bookmarkRecord
    self.probeResult = probeResult
    self.accessLease = accessLease
  }

  public var didStartSecurityScopedAccess: Bool {
    accessLease.didStartAccess
  }
}

public struct WorkbenchDataRootBookmarkResolution: Equatable, Sendable {
  public var url: URL
  public var accessURL: URL
  public var record: WorkbenchDataRootBookmarkRecord
  public var didRefreshStaleBookmark: Bool

  public init(
    url: URL,
    accessURL: URL? = nil,
    record: WorkbenchDataRootBookmarkRecord,
    didRefreshStaleBookmark: Bool
  ) {
    self.url = url.standardizedFileURL
    self.accessURL = (accessURL ?? url).standardizedFileURL
    self.record = record
    self.didRefreshStaleBookmark = didRefreshStaleBookmark
  }
}

public enum WorkbenchDataRootBookmarkError: Error, Equatable, Sendable {
  case invalidStoredRecord
  case invalidRelativeRootPath
  case bookmarkCreationFailed(String)
  case bookmarkResolutionFailed(String)
  case securityScopedAccessDenied
  case dataIdentityMismatch(expected: UUID, found: UUID)
}

/// Persists and resolves the user-selected data root.
///
/// `openStoredRoot` returns a session that owns the security-scope lease. Keep
/// that session alive for as long as services use paths below the selected root.
/// The store is configured once during launch. Its dependencies are immutable,
/// UserDefaults serializes its own access, and the injected codec/security-scope
/// callbacks are Sendable, so the blocking resolve/probe operation can run off
/// the main actor without changing the store's public API.
public final class WorkbenchDataRootBookmarkStore: @unchecked Sendable {
  public static let defaultStorageKey = "RepoPress.WorkbenchDataRootBookmark.v1"

  private let defaults: UserDefaults
  private let storageKey: String
  private let codec: WorkbenchDataRootBookmarkCodec
  private let securityScope: WorkbenchDataRootSecurityScope

  public init(
    defaults: UserDefaults = .standard,
    storageKey: String = WorkbenchDataRootBookmarkStore.defaultStorageKey,
    codec: WorkbenchDataRootBookmarkCodec = .securityScoped,
    securityScope: WorkbenchDataRootSecurityScope = .live
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
    self.codec = codec
    self.securityScope = securityScope
  }

  @discardableResult
  public func rememberSelectedRoot(
    _ rootURL: URL,
    accessURL: URL? = nil,
    dataID: UUID? = nil,
    updatedAt: Date = Date()
  ) throws -> WorkbenchDataRootBookmarkRecord {
    let standardizedURL = rootURL.standardizedFileURL
    let standardizedAccessURL = (accessURL ?? standardizedURL).standardizedFileURL
    let relativeRootPath = try Self.relativeRootPath(
      from: standardizedAccessURL,
      to: standardizedURL
    )
    let bookmarkData: Data
    do {
      bookmarkData = try codec.create(for: standardizedAccessURL)
    } catch {
      throw WorkbenchDataRootBookmarkError.bookmarkCreationFailed(error.localizedDescription)
    }

    let record = WorkbenchDataRootBookmarkRecord(
      bookmarkData: bookmarkData,
      displayPath: standardizedURL.path,
      relativeRootPath: relativeRootPath,
      dataID: dataID,
      updatedAt: updatedAt
    )
    try persist(record)
    return record
  }

  public func storedRecord() throws -> WorkbenchDataRootBookmarkRecord? {
    guard let data = defaults.data(forKey: storageKey) else { return nil }
    do {
      return try JSONDecoder().decode(WorkbenchDataRootBookmarkRecord.self, from: data)
    } catch {
      throw WorkbenchDataRootBookmarkError.invalidStoredRecord
    }
  }

  @discardableResult
  public func bindStoredRoot(
    to dataID: UUID,
    updatedAt: Date = Date()
  ) throws -> WorkbenchDataRootBookmarkRecord? {
    guard var record = try storedRecord() else { return nil }
    record.dataID = dataID
    record.updatedAt = updatedAt
    try persist(record)
    return record
  }

  public func resolveStoredRoot(
    refreshedAt: Date = Date(),
    inspector: WorkbenchDataRootInspector = WorkbenchDataRootInspector()
  ) throws -> WorkbenchDataRootBookmarkResolution? {
    guard var pending = try decodeStoredRoot() else { return nil }
    guard pending.isStale else { return pending.resolution }

    let refreshLease = securityScope.makeLease(for: pending.resolution.accessURL)
    guard refreshLease.didStartAccess else {
      throw WorkbenchDataRootBookmarkError.securityScopedAccessDenied
    }
    let probeResult = inspector.probe(at: pending.resolution.url)
    let canRefresh = try dataIdentityAllowsRefresh(
      record: pending.resolution.record,
      probeResult: probeResult
    )
    guard canRefresh else { return pending.resolution }
    pending.resolution.record = try refreshedRecord(
      pending.resolution.record,
      accessURL: pending.resolution.accessURL,
      rootURL: pending.resolution.url,
      refreshedAt: refreshedAt
    )
    pending.resolution.didRefreshStaleBookmark = true
    return pending.resolution
  }

  public func openStoredRoot(
    refreshedAt: Date = Date(),
    inspector: WorkbenchDataRootInspector = WorkbenchDataRootInspector()
  ) throws -> WorkbenchDataRootSession? {
    guard var pending = try decodeStoredRoot() else {
      return nil
    }

    let lease = securityScope.makeLease(for: pending.resolution.accessURL)
    guard lease.didStartAccess else {
      throw WorkbenchDataRootBookmarkError.securityScopedAccessDenied
    }
    let layout = WorkbenchDataRootLayout(rootURL: pending.resolution.url)
    let probeResult = inspector.probe(at: pending.resolution.url)
    let canRefresh = try dataIdentityAllowsRefresh(
      record: pending.resolution.record,
      probeResult: probeResult
    )

    if pending.isStale && canRefresh {
      pending.resolution.record = try refreshedRecord(
        pending.resolution.record,
        accessURL: pending.resolution.accessURL,
        rootURL: pending.resolution.url,
        refreshedAt: refreshedAt
      )
    }

    return WorkbenchDataRootSession(
      layout: layout,
      bookmarkRecord: pending.resolution.record,
      probeResult: probeResult,
      accessLease: lease
    )
  }

  private func decodeStoredRoot() throws -> (
    resolution: WorkbenchDataRootBookmarkResolution,
    isStale: Bool
  )? {
    guard let record = try storedRecord() else { return nil }

    let decoded: WorkbenchDataRootDecodedBookmark
    do {
      decoded = try codec.resolve(record.bookmarkData)
    } catch {
      throw WorkbenchDataRootBookmarkError.bookmarkResolutionFailed(error.localizedDescription)
    }
    let rootURL = try Self.rootURL(
      accessURL: decoded.url,
      relativeRootPath: record.relativeRootPath
    )
    return (
      WorkbenchDataRootBookmarkResolution(
        url: rootURL,
        accessURL: decoded.url,
        record: record,
        didRefreshStaleBookmark: false
      ),
      decoded.isStale
    )
  }

  private func refreshedRecord(
    _ originalRecord: WorkbenchDataRootBookmarkRecord,
    accessURL: URL,
    rootURL: URL,
    refreshedAt: Date
  ) throws -> WorkbenchDataRootBookmarkRecord {
    var record = originalRecord
    do {
      record.bookmarkData = try codec.create(for: accessURL)
    } catch {
      throw WorkbenchDataRootBookmarkError.bookmarkCreationFailed(error.localizedDescription)
    }
    record.displayPath = rootURL.path
    record.updatedAt = refreshedAt
    try persist(record)
    return record
  }

  /// A bound bookmark may only be refreshed after the expected data identity
  /// is visible. If an external volume is absent or has mounted at the same
  /// path without the data root, preserve the old bookmark so a later remount
  /// can still resolve it.
  private func dataIdentityAllowsRefresh(
    record: WorkbenchDataRootBookmarkRecord,
    probeResult: WorkbenchDataRootProbeResult
  ) throws -> Bool {
    guard let expectedDataID = record.dataID else { return true }
    guard case .existing(let manifest) = probeResult else { return false }
    if expectedDataID != manifest.dataID {
      throw WorkbenchDataRootBookmarkError.dataIdentityMismatch(
        expected: expectedDataID,
        found: manifest.dataID
      )
    }
    return true
  }

  public func clear() {
    defaults.removeObject(forKey: storageKey)
  }

  private func persist(_ record: WorkbenchDataRootBookmarkRecord) throws {
    let data = try JSONEncoder().encode(record)
    defaults.set(data, forKey: storageKey)
  }

  private static func relativeRootPath(from accessURL: URL, to rootURL: URL) throws -> String? {
    guard accessURL != rootURL else { return nil }
    guard rootURL.deletingLastPathComponent() == accessURL else {
      throw WorkbenchDataRootBookmarkError.invalidRelativeRootPath
    }
    let component = rootURL.lastPathComponent
    guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
      throw WorkbenchDataRootBookmarkError.invalidRelativeRootPath
    }
    return component
  }

  private static func rootURL(
    accessURL: URL,
    relativeRootPath: String?
  ) throws -> URL {
    guard let relativeRootPath else { return accessURL.standardizedFileURL }
    guard !relativeRootPath.isEmpty,
          relativeRootPath != ".",
          relativeRootPath != "..",
          !relativeRootPath.contains("/") else {
      throw WorkbenchDataRootBookmarkError.invalidRelativeRootPath
    }
    return accessURL.appendingPathComponent(
      relativeRootPath,
      isDirectory: true
    ).standardizedFileURL
  }
}
