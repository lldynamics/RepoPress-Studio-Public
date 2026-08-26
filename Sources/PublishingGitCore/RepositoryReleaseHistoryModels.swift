import Foundation

/// The availability of one of the Git-backed release-history sources.
///
/// `unknown` is intentionally distinct from `unavailable`: a command may
/// have been blocked or interrupted without proving that the repository lacks
/// the corresponding source.
public enum RepositoryReleaseHistoryAvailability: String, Codable, Hashable, Sendable {
  case available
  case unavailable
  case unknown
}

/// Notes use the same availability vocabulary as commit history.  The alias
/// keeps the two fields self-documenting at call sites without introducing
/// two enums that could drift apart.
public typealias RepositoryReleaseNotesAvailability = RepositoryReleaseHistoryAvailability

/// A bounded request for the Git-backed release history.
public struct RepositoryReleaseHistoryRequest: Codable, Hashable, Sendable {
  public static let minimumLimit = 1
  public static let maximumLimit = 200
  public static let defaultLimit = 20

  public var limit: Int
  public var cursor: String?

  public init(
    limit: Int = Self.defaultLimit,
    cursor: String? = nil
  ) {
    self.limit = Self.clampedLimit(limit)
    self.cursor = Self.normalizedCursor(cursor)
  }

  private enum CodingKeys: String, CodingKey {
    case limit
    case cursor
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit,
      cursor: try container.decodeIfPresent(String.self, forKey: .cursor)
    )
  }

  public static func clampedLimit(_ limit: Int) -> Int {
    min(maximumLimit, max(minimumLimit, limit))
  }

  /// Git object names are emitted in their complete form by the history
  /// command.  Accept only SHA-1 and SHA-256 object names so a cursor cannot
  /// become an option, revision expression, or pathspec.
  public static func normalizedCursor(_ cursor: String?) -> String? {
    guard let cursor else { return nil }
    let value = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isValidCursor(value) else { return nil }
    return value.lowercased()
  }

  public static func isValidCursor(_ value: String) -> Bool {
    let length = value.utf8.count
    guard length == 40 || length == 64 else { return false }
    return value.utf8.allSatisfy { byte in
      (byte >= 0x30 && byte <= 0x39) ||
        (byte >= 0x41 && byte <= 0x46) ||
        (byte >= 0x61 && byte <= 0x66)
    }
  }
}

/// A non-localized diagnostic emitted while loading or parsing release
/// history.  Workbench callers can choose the presentation and severity.
public struct RepositoryReleaseHistoryDiagnostic: Codable, Hashable, Sendable {
  public var message: String
  public var source: String?
  public var terminationStatus: Int32?

  public init(
    message: String,
    source: String? = nil,
    terminationStatus: Int32? = nil
  ) {
    self.message = message
    self.source = source
    self.terminationStatus = terminationStatus
  }
}

/// One Git tag returned by `for-each-ref`.
///
/// For an annotated tag, `objectSHA` identifies the tag object and
/// `targetSHA` identifies the peeled object.  For a lightweight tag the two
/// values are equal and `isAnnotated` is false.
public struct RepositoryReleaseTag: Identifiable, Codable, Hashable, Sendable {
  public var id: String { name }
  public var name: String
  public var objectSHA: String
  public var targetSHA: String
  public var objectType: String?
  public var targetType: String?
  public var subject: String
  public var isAnnotated: Bool

  public init(
    name: String,
    objectSHA: String,
    targetSHA: String? = nil,
    objectType: String? = nil,
    targetType: String? = nil,
    subject: String = "",
    isAnnotated: Bool? = nil
  ) {
    let resolvedTargetSHA = targetSHA ?? objectSHA
    self.name = name
    self.objectSHA = objectSHA
    self.targetSHA = resolvedTargetSHA
    self.objectType = objectType
    self.targetType = targetType
    self.subject = subject
    self.isAnnotated = isAnnotated ?? (targetSHA != nil && resolvedTargetSHA != objectSHA)
  }

  /// Compatibility shorthand for callers that only need the commit/object
  /// name represented by this tag.
  public var sha: String { targetSHA }
}

/// A validated schema-1 JSON note attached to a commit.
///
/// The raw payload remains available so Workbench can evolve the lightweight
/// metadata fields without making GitCore depend on UI or release-ledger
/// models.  `metadata` contains scalar values as a convenient projection for
/// common labels and identifiers.
public struct RepositoryReleaseNote: Identifiable, Codable, Hashable, Sendable {
  public var id: String { commitSHA }
  public var commitSHA: String
  public var schemaVersion: Int
  public var rawJSON: String
  public var metadata: [String: String]

  public init(
    commitSHA: String,
    schemaVersion: Int = 1,
    rawJSON: String,
    metadata: [String: String] = [:]
  ) {
    self.commitSHA = commitSHA
    self.schemaVersion = schemaVersion
    self.rawJSON = rawJSON
    self.metadata = metadata
  }

  public var schema: Int { schemaVersion }
  public var payload: String { rawJSON }
}

/// The immutable, read-only release-history view returned by GitCore.
///
/// The availability fields are explicit because an empty history and an
/// unavailable Git source are different UI states.  `partial` covers
/// pagination, truncation, command failures, and recoverable malformed
/// records; all details remain available in `diagnostics`.
public struct RepositoryReleaseHistorySnapshot: Codable, Hashable, Sendable {
  public var commits: [RepositoryCommitInfo]
  public var tags: [RepositoryReleaseTag]
  public var notes: [RepositoryReleaseNote]
  public var historyAvailability: RepositoryReleaseHistoryAvailability
  public var notesAvailability: RepositoryReleaseNotesAvailability
  public var diagnostics: [RepositoryReleaseHistoryDiagnostic]
  public var partial: Bool
  public var cursor: String?
  public var shallow: Bool

  public init(
    commits: [RepositoryCommitInfo] = [],
    tags: [RepositoryReleaseTag] = [],
    notes: [RepositoryReleaseNote] = [],
    historyAvailability: RepositoryReleaseHistoryAvailability = .unknown,
    notesAvailability: RepositoryReleaseNotesAvailability = .unknown,
    diagnostics: [RepositoryReleaseHistoryDiagnostic] = [],
    partial: Bool = false,
    cursor: String? = nil,
    shallow: Bool = false
  ) {
    self.commits = commits
    self.tags = tags
    self.notes = notes
    self.historyAvailability = historyAvailability
    self.notesAvailability = notesAvailability
    self.diagnostics = diagnostics
    self.partial = partial
    self.cursor = RepositoryReleaseHistoryRequest.normalizedCursor(cursor)
    self.shallow = shallow
  }

  public var isHistoryAvailable: Bool {
    historyAvailability == .available
  }

  public var isNotesAvailable: Bool {
    notesAvailability == .available
  }

  public var nextCursor: String? { cursor }
}

/// The pure result of parsing commit-log records.
public struct RepositoryReleaseHistoryCommitParseResult: Hashable, Sendable {
  public var commits: [RepositoryCommitInfo]
  public var diagnostics: [RepositoryReleaseHistoryDiagnostic]

  public init(
    commits: [RepositoryCommitInfo] = [],
    diagnostics: [RepositoryReleaseHistoryDiagnostic] = []
  ) {
    self.commits = commits
    self.diagnostics = diagnostics
  }
}

/// The pure result of parsing tag records.
public struct RepositoryReleaseTagParseResult: Hashable, Sendable {
  public var tags: [RepositoryReleaseTag]
  public var diagnostics: [RepositoryReleaseHistoryDiagnostic]

  public init(
    tags: [RepositoryReleaseTag] = [],
    diagnostics: [RepositoryReleaseHistoryDiagnostic] = []
  ) {
    self.tags = tags
    self.diagnostics = diagnostics
  }
}

/// The pure result of parsing commit-note records.
public struct RepositoryReleaseNoteParseResult: Hashable, Sendable {
  public var notes: [RepositoryReleaseNote]
  public var diagnostics: [RepositoryReleaseHistoryDiagnostic]

  public init(
    notes: [RepositoryReleaseNote] = [],
    diagnostics: [RepositoryReleaseHistoryDiagnostic] = []
  ) {
    self.notes = notes
    self.diagnostics = diagnostics
  }
}
