import Foundation
import PublishingCoreSupport

/// The kind of change reported for a file in a local Git working tree.
public enum RepositoryChangeKind: String, Codable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case untracked
  case other
}

/// The exact path or path pair reported by Git for one changed file.
///
/// Git reports rename and copy records as two separate path fields.  Keeping
/// those fields separate is important because either path may itself contain
/// the legacy ` -> ` display separator.
public enum RepositoryChangedPath: Hashable, Sendable {
  case single(String)
  case sourceAndDestination(source: String, destination: String)

  public var sourcePath: String? {
    switch self {
    case .single:
      return nil
    case let .sourceAndDestination(source, _):
      return source
    }
  }

  public var destinationPath: String {
    switch self {
    case let .single(path):
      return path
    case let .sourceAndDestination(_, destination):
      return destination
    }
  }
}

/// A file change reported by Git for a local or remote comparison.
public struct RepositoryChangedFile: Identifiable, Codable, Hashable, Sendable {
  public var status: String
  public var kind: RepositoryChangeKind
  public var lineDiff: String?
  public var changedPath: RepositoryChangedPath

  /// The legacy path payload.  For a pair this retains Git's historical
  /// `source -> destination` presentation; it must not be used for file I/O.
  public var path: String {
    get {
      switch changedPath {
      case let .single(path):
        return path
      case let .sourceAndDestination(source, destination):
        return source + " -> " + destination
      }
    }
    set {
      changedPath = Self.legacyChangedPath(status: status, path: newValue)
    }
  }

  /// The exact source path for a rename or copy, when Git supplied one.
  public var sourcePath: String? {
    changedPath.sourcePath
  }

  /// The exact path to use for the resulting file.
  public var destinationPath: String {
    changedPath.destinationPath
  }

  /// Existing identity for ordinary payloads, with an unambiguous suffix for
  /// structured pairs whose endpoints contain the legacy display separator.
  public var id: String {
    let legacyIdentity = status + path
    guard case let .sourceAndDestination(source, destination) = changedPath,
          source.contains(" -> ") || destination.contains(" -> ") else {
      return legacyIdentity
    }

    return legacyIdentity
      + "\u{001F}pair:"
      + String(source.utf8.count)
      + ":"
      + source
      + "\u{001F}"
      + String(destination.utf8.count)
      + ":"
      + destination
  }

  public init(
    status: String,
    path: String,
    kind: RepositoryChangeKind,
    lineDiff: String? = nil
  ) {
    self.status = status
    self.kind = kind
    self.lineDiff = lineDiff
    self.changedPath = Self.legacyChangedPath(status: status, path: path)
  }

  /// Creates a changed file from the exact structured path reported by Git.
  public init(
    status: String,
    changedPath: RepositoryChangedPath,
    kind: RepositoryChangeKind,
    lineDiff: String? = nil
  ) {
    self.status = status
    self.kind = kind
    self.lineDiff = lineDiff
    self.changedPath = changedPath
  }

  /// Convenience overload retaining the familiar `path:` label for callers
  /// that already have a structured path value.
  public init(
    status: String,
    path: RepositoryChangedPath,
    kind: RepositoryChangeKind,
    lineDiff: String? = nil
  ) {
    self.init(status: status, changedPath: path, kind: kind, lineDiff: lineDiff)
  }

  /// Convenience initializer for a source/destination pair.
  public init(
    status: String,
    sourcePath: String,
    destinationPath: String,
    kind: RepositoryChangeKind,
    lineDiff: String? = nil
  ) {
    self.init(
      status: status,
      changedPath: .sourceAndDestination(source: sourcePath, destination: destinationPath),
      kind: kind,
      lineDiff: lineDiff
    )
  }

  /// Returns the destination path for a rename, normalized for display.
  public var displayPath: String {
    destinationPath.trimmedForPublishing
  }

  public static func == (lhs: RepositoryChangedFile, rhs: RepositoryChangedFile) -> Bool {
    lhs.status == rhs.status
      && lhs.kind == rhs.kind
      && lhs.lineDiff == rhs.lineDiff
      && lhs.path == rhs.path
      && lhs.changedPath == rhs.changedPath
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(status)
    hasher.combine(path)
    hasher.combine(changedPath)
    hasher.combine(kind)
    hasher.combine(lineDiff)
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case path
    case kind
    case lineDiff
    case sourcePath
    case destinationPath
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let status = try container.decode(String.self, forKey: .status)
    let legacyPath = try container.decode(String.self, forKey: .path)
    let kind = try container.decode(RepositoryChangeKind.self, forKey: .kind)
    let lineDiff = try container.decodeIfPresent(String.self, forKey: .lineDiff)

    let hasSourcePath = container.contains(.sourcePath)
    let hasDestinationPath = container.contains(.destinationPath)
    guard hasSourcePath == hasDestinationPath else {
      throw DecodingError.dataCorruptedError(
        forKey: hasSourcePath ? .sourcePath : .destinationPath,
        in: container,
        debugDescription: "sourcePath and destinationPath must be supplied together"
      )
    }

    let changedPath: RepositoryChangedPath
    if hasSourcePath && hasDestinationPath {
      let sourcePath = try container.decode(String.self, forKey: .sourcePath)
      let destinationPath = try container.decode(String.self, forKey: .destinationPath)
      let expectedLegacyPath = sourcePath + " -> " + destinationPath
      guard legacyPath == expectedLegacyPath else {
        throw DecodingError.dataCorruptedError(
          forKey: .path,
          in: container,
          debugDescription: "legacy path conflicts with sourcePath and destinationPath"
        )
      }
      changedPath = .sourceAndDestination(source: sourcePath, destination: destinationPath)
    } else {
      changedPath = Self.legacyChangedPath(status: status, path: legacyPath)
    }

    self.status = status
    self.kind = kind
    self.lineDiff = lineDiff
    self.changedPath = changedPath
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    try container.encode(path, forKey: .path)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(lineDiff, forKey: .lineDiff)

    if let sourcePath {
      try container.encode(sourcePath, forKey: .sourcePath)
      try container.encode(destinationPath, forKey: .destinationPath)
    }
  }

  private static func legacyChangedPath(status: String, path: String) -> RepositoryChangedPath {
    guard isRenameOrCopyStatus(status),
          let separator = path.range(of: " -> ", options: .backwards) else {
      return .single(path)
    }

    let sourcePath = String(path[..<separator.lowerBound])
    let destinationPath = String(path[separator.upperBound...])
    guard !sourcePath.isEmpty, !destinationPath.isEmpty else {
      return .single(path)
    }

    return .sourceAndDestination(source: sourcePath, destination: destinationPath)
  }

  private static func isRenameOrCopyStatus(_ status: String) -> Bool {
    status.contains("R") || status.contains("C")
  }
}

/// The content of a file read from a repository ref.
public struct RepositoryFileSnapshot: Codable, Hashable, Sendable {
  public var refName: String
  public var repositoryPath: String
  public var repositorySHA: String?
  public var content: String

  public init(
    refName: String,
    repositoryPath: String,
    content: String,
    repositorySHA: String? = nil
  ) {
    self.refName = refName
    self.repositoryPath = repositoryPath
    self.content = content
    self.repositorySHA = repositorySHA
  }
}

/// The outcome of fetching the current branch's upstream.
public enum RepositoryFetchStatus: String, Codable, Hashable, Sendable {
  case succeeded
  case skipped
  case failed
}

public struct RepositoryFetchResult: Codable, Hashable, Sendable {
  public var status: RepositoryFetchStatus
  public var remoteName: String?
  public var upstreamName: String?
  public var message: String

  public init(
    status: RepositoryFetchStatus,
    remoteName: String?,
    upstreamName: String?,
    message: String
  ) {
    self.status = status
    self.remoteName = remoteName
    self.upstreamName = upstreamName
    self.message = message
  }
}
