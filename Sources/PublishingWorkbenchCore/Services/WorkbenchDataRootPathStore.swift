import Foundation

/// The durable path selected for the workbench data root.
///
/// The path is intentionally stored as a string rather than as a security
/// token. Direct-distribution builds are not constrained by App Sandbox, so a
/// normalized absolute path is both sufficient and easier to recover after a
/// restart or an external-volume remount.
public struct WorkbenchDataRootPathRecord: Codable, Equatable, Sendable {
  public var path: String
  public var dataID: UUID?
  public var updatedAt: Date

  public init(
    path: String,
    dataID: UUID? = nil,
    updatedAt: Date = Date()
  ) {
    self.path = path
    self.dataID = dataID
    self.updatedAt = updatedAt
  }

  /// Compatibility spelling for callers that present the path to a user.
  /// New persistence always uses the `path` coding key.
  public var displayPath: String {
    get { path }
    set { path = newValue }
  }

  public init(
    displayPath: String,
    dataID: UUID? = nil,
    updatedAt: Date = Date()
  ) {
    self.init(path: displayPath, dataID: dataID, updatedAt: updatedAt)
  }
}

public enum WorkbenchDataRootPathError: Error, Equatable, Sendable {
  case invalidStoredRecord
  case invalidRootPath
  case dataIdentityMismatch(expected: UUID, found: UUID)
}

public struct WorkbenchDataRootPathResolution: Equatable, Sendable {
  public let layout: WorkbenchDataRootLayout
  public let record: WorkbenchDataRootPathRecord
  public let probeResult: WorkbenchDataRootProbeResult

  public init(
    layout: WorkbenchDataRootLayout,
    record: WorkbenchDataRootPathRecord,
    probeResult: WorkbenchDataRootProbeResult
  ) {
    self.layout = layout
    self.record = record
    self.probeResult = probeResult
  }

  public var url: URL {
    layout.rootURL
  }
}

/// A resolved data-root session. Unlike the old sandbox implementation, a
/// session owns no lease and therefore needs no explicit access lifecycle.
public final class WorkbenchDataRootSession: Sendable {
  public let layout: WorkbenchDataRootLayout
  public let pathRecord: WorkbenchDataRootPathRecord
  public let probeResult: WorkbenchDataRootProbeResult

  fileprivate init(
    layout: WorkbenchDataRootLayout,
    pathRecord: WorkbenchDataRootPathRecord,
    probeResult: WorkbenchDataRootProbeResult
  ) {
    self.layout = layout
    self.pathRecord = pathRecord
    self.probeResult = probeResult
  }

  public var rootURL: URL {
    layout.rootURL
  }

  /// Short spelling useful to code that does not need to distinguish the
  /// record's source from the resolved session.
  public var record: WorkbenchDataRootPathRecord {
    pathRecord
  }
}

/// Persists and opens the selected data root using a normal absolute path.
///
/// The optional legacy key is read only for the path fields that older
/// versions wrote alongside their sandbox token. Unknown fields are ignored;
/// in particular, this type never decodes or resolves the old token.
public final class WorkbenchDataRootPathStore: @unchecked Sendable {
  public typealias ProbeRoot = @Sendable (URL) -> WorkbenchDataRootProbeResult

  public static let defaultStorageKey = "RepoPress.WorkbenchDataRootPath.v1"
  public static let legacyStorageKey = "RepoPress.WorkbenchDataRootBookmark.v1"

  private let defaults: UserDefaults
  private let storageKey: String
  private let legacyStorageKey: String
  private let probeRoot: ProbeRoot

  public init(
    defaults: UserDefaults = .standard,
    storageKey: String = WorkbenchDataRootPathStore.defaultStorageKey,
    legacyStorageKey: String = WorkbenchDataRootPathStore.legacyStorageKey,
    probe: ProbeRoot? = nil
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
    self.legacyStorageKey = legacyStorageKey
    self.probeRoot = probe ?? { rootURL in
      WorkbenchDataRootInspector().probe(at: rootURL)
    }
  }

  @discardableResult
  public func rememberRoot(
    _ rootURL: URL,
    dataID: UUID? = nil,
    updatedAt: Date = Date()
  ) throws -> WorkbenchDataRootPathRecord {
    let standardizedURL = try Self.standardizedRootURL(rootURL)
    let record = WorkbenchDataRootPathRecord(
      path: standardizedURL.path,
      dataID: dataID,
      updatedAt: updatedAt
    )
    try persist(record)
    return record
  }

  /// Returns the normalized record, migrating only path metadata from the
  /// old preference payload when no new record exists.
  public func storedRecord() throws -> WorkbenchDataRootPathRecord? {
    if defaults.object(forKey: storageKey) != nil {
      guard let data = defaults.data(forKey: storageKey) else {
        throw WorkbenchDataRootPathError.invalidStoredRecord
      }
      do {
        let record = try JSONDecoder().decode(
          WorkbenchDataRootPathRecord.self,
          from: data
        )
        let normalizedRecord = try normalized(record)
        if normalizedRecord != record {
          try persist(normalizedRecord)
        }
        return normalizedRecord
      } catch let error as WorkbenchDataRootPathError {
        throw error
      } catch {
        throw WorkbenchDataRootPathError.invalidStoredRecord
      }
    }

    guard defaults.object(forKey: legacyStorageKey) != nil else {
      return nil
    }
    guard let legacyData = defaults.data(forKey: legacyStorageKey) else {
      throw WorkbenchDataRootPathError.invalidStoredRecord
    }
    let migrated = try migrateLegacyRecord(from: legacyData)
    try persist(migrated)
    return migrated
  }

  @discardableResult
  public func bindStoredRoot(
    to dataID: UUID,
    updatedAt: Date = Date()
  ) throws -> WorkbenchDataRootPathRecord? {
    guard var record = try storedRecord() else { return nil }
    record.dataID = dataID
    record.updatedAt = updatedAt
    try persist(record)
    return record
  }

  /// Resolves the stored path, probes the root, and verifies its manifest
  /// identity before returning a resolution. A missing path is represented by
  /// `.new`; a different existing manifest throws and is never opened.
  public func resolveStoredRoot() throws -> WorkbenchDataRootPathResolution? {
    guard let record = try storedRecord() else { return nil }
    let layout = WorkbenchDataRootLayout(
      rootURL: URL(fileURLWithPath: record.path, isDirectory: true)
    )
    let probeResult = probeRoot(layout.rootURL)
    try Self.validateDataIdentity(record: record, probeResult: probeResult)
    return WorkbenchDataRootPathResolution(
      layout: layout,
      record: record,
      probeResult: probeResult
    )
  }

  public func openStoredRoot() throws -> WorkbenchDataRootSession? {
    guard let resolution = try resolveStoredRoot() else { return nil }
    return WorkbenchDataRootSession(
      layout: resolution.layout,
      pathRecord: resolution.record,
      probeResult: resolution.probeResult
    )
  }

  public func clear() {
    defaults.removeObject(forKey: storageKey)
    defaults.removeObject(forKey: legacyStorageKey)
  }

  private func normalized(
    _ record: WorkbenchDataRootPathRecord
  ) throws -> WorkbenchDataRootPathRecord {
    guard !record.path.isEmpty,
      !record.path.contains("\0"),
      record.path.hasPrefix("/")
    else {
      throw WorkbenchDataRootPathError.invalidStoredRecord
    }
    let standardizedURL = try Self.standardizedRootURL(
      URL(fileURLWithPath: record.path, isDirectory: true)
    )
    guard standardizedURL.path == record.path else {
      var normalizedRecord = record
      normalizedRecord.path = standardizedURL.path
      return normalizedRecord
    }
    return record
  }

  private func migrateLegacyRecord(from data: Data) throws -> WorkbenchDataRootPathRecord {
    let fields: LegacyPathFields
    do {
      fields = try Self.decodeLegacyPathFields(from: data)
    } catch {
      throw WorkbenchDataRootPathError.invalidStoredRecord
    }
    do {
      guard !fields.displayPath.isEmpty,
        !fields.displayPath.contains("\0"),
        fields.displayPath.hasPrefix("/")
      else {
        throw WorkbenchDataRootPathError.invalidStoredRecord
      }
      let standardizedURL = try Self.standardizedRootURL(
        URL(fileURLWithPath: fields.displayPath, isDirectory: true)
      )
      return WorkbenchDataRootPathRecord(
        path: standardizedURL.path,
        dataID: fields.dataID,
        updatedAt: fields.updatedAt
      )
    } catch {
      throw WorkbenchDataRootPathError.invalidStoredRecord
    }
  }

  private func persist(_ record: WorkbenchDataRootPathRecord) throws {
    let data = try JSONEncoder().encode(record)
    defaults.set(data, forKey: storageKey)
  }

  private static func standardizedRootURL(_ rootURL: URL) throws -> URL {
    guard rootURL.isFileURL else {
      throw WorkbenchDataRootPathError.invalidRootPath
    }
    let path = rootURL.path
    guard !path.isEmpty, !path.contains("\0"), path.hasPrefix("/") else {
      throw WorkbenchDataRootPathError.invalidRootPath
    }
    let standardizedURL = rootURL.standardizedFileURL
    guard standardizedURL.isFileURL, standardizedURL.path.hasPrefix("/") else {
      throw WorkbenchDataRootPathError.invalidRootPath
    }
    return standardizedURL
  }

  private static func validateDataIdentity(
    record: WorkbenchDataRootPathRecord,
    probeResult: WorkbenchDataRootProbeResult
  ) throws {
    guard let expectedDataID = record.dataID,
      case .existing(let manifest) = probeResult
    else {
      return
    }
    guard expectedDataID == manifest.dataID else {
      throw WorkbenchDataRootPathError.dataIdentityMismatch(
        expected: expectedDataID,
        found: manifest.dataID
      )
    }
  }

  private struct LegacyPathFields: Decodable {
    let displayPath: String
    let dataID: UUID?
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
      case displayPath
      case dataID
      case updatedAt
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      displayPath = try container.decode(String.self, forKey: .displayPath)
      dataID = try container.decodeIfPresent(UUID.self, forKey: .dataID)
      updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
  }

  private static func decodeLegacyPathFields(from data: Data) throws -> LegacyPathFields {
    if let fields = try? JSONDecoder().decode(LegacyPathFields.self, from: data) {
      return fields
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(LegacyPathFields.self, from: data)
  }
}
