import Foundation

/// A user-selected Markdown directory used as a draft source.
/// A new directory gets a new ID so matching relative paths cannot collide.
public struct ExternalDraftFolderMapping: Codable, Hashable, Sendable {
  public var id: UUID
  public var path: String
  public var observesChanges: Bool

  public init(id: UUID = UUID(), path: String, observesChanges: Bool = true) {
    self.id = id
    self.path = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    self.observesChanges = observesChanges
  }

  public var directoryURL: URL {
    URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
  }
}

/// Last source bytes accepted by a linked draft. The fingerprint protects
/// writes in both directions when another editor changes the file.
public struct ExternalDraftSource: Codable, Hashable, Sendable {
  public var mappingID: UUID
  public var relativePath: String
  public var importedTitle: String
  public var importedFingerprint: String
  /// The standardized directory retained after the owning Profile is removed.
  /// A detached source is deliberately local-only until that directory is
  /// selected again, when its existing draft can be rebound without a copy.
  /// Optional storage keeps snapshots written before profile deletion support
  /// backward compatible.
  public var detachedFolderPath: String?

  public init(
    mappingID: UUID,
    relativePath: String,
    importedTitle: String,
    importedFingerprint: String,
    detachedFolderPath: String? = nil
  ) {
    self.mappingID = mappingID
    self.relativePath = relativePath
    self.importedTitle = importedTitle
    self.importedFingerprint = importedFingerprint
    self.detachedFolderPath = detachedFolderPath.map {
      URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
    }
  }

  public var isDetached: Bool { detachedFolderPath != nil }

  public func isDetached(from mapping: ExternalDraftFolderMapping) -> Bool {
    mappingID == mapping.id && detachedFolderPath == mapping.directoryURL.path
  }

  /// A newly selected mapping receives a new identity, so reconnect matching
  /// intentionally compares the preserved normalized folder independently of
  /// the retired mapping ID. Undo uses `isDetached(from:)` instead.
  public func isDetached(in directory: ExternalDraftFolderMapping) -> Bool {
    detachedFolderPath == directory.directoryURL.path
  }

  public mutating func detach(from mapping: ExternalDraftFolderMapping) {
    guard mappingID == mapping.id else { return }
    detachedFolderPath = mapping.directoryURL.path
  }

  public mutating func reconnect(to mapping: ExternalDraftFolderMapping) {
    mappingID = mapping.id
    detachedFolderPath = nil
  }
}
