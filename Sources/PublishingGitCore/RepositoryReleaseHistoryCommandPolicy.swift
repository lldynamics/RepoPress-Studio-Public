import Foundation

/// Input for the read-only commands that load Git-backed release history.
public struct RepositoryReleaseHistoryCommandInput: Codable, Hashable, Sendable {
  public var request: RepositoryReleaseHistoryRequest

  public init(
    limit: Int = RepositoryReleaseHistoryRequest.defaultLimit,
    cursor: String? = nil
  ) {
    request = RepositoryReleaseHistoryRequest(limit: limit, cursor: cursor)
  }

  public init(request: RepositoryReleaseHistoryRequest) {
    self.request = request
  }

  public var limit: Int { request.limit }
  public var cursor: String? { request.cursor }
}

/// Exact argv arrays for the independent Git history, tag, and note reads.
/// The policy constructs arguments only; it never executes Git.
public struct RepositoryReleaseHistoryCommandPlan: Codable, Hashable, Sendable {
  public static let notesReference = "refs/notes/repopress/releases"

  public var request: RepositoryReleaseHistoryRequest
  public var commitArguments: [String]
  public var tagArguments: [String]
  public var notesArguments: [String]

  public init(
    request: RepositoryReleaseHistoryRequest,
    commitArguments: [String],
    tagArguments: [String],
    notesArguments: [String]
  ) {
    self.request = request
    self.commitArguments = commitArguments
    self.tagArguments = tagArguments
    self.notesArguments = notesArguments
  }

  public var noteArguments: [String] { notesArguments }

  public var argumentsInExecutionOrder: [[String]] {
    [commitArguments, tagArguments, notesArguments]
  }

  public var commands: [[String]] { argumentsInExecutionOrder }

  public var notesRef: String { Self.notesReference }

  /// Builds the per-commit `git notes show` argv used after the note list has
  /// been parsed.  The SHA guard keeps the API safe even when called directly
  /// by an adapter instead of through the request cursor validation.
  public func noteShowArguments(for commitSHA: String) -> [String]? {
    guard RepositoryReleaseHistoryRequest.isValidCursor(commitSHA) else {
      return nil
    }
    return [
      "notes",
      "--ref",
      Self.notesReference,
      "show",
      commitSHA.lowercased(),
    ]
  }

  public func notesShowArguments(for commitSHA: String) -> [String]? {
    noteShowArguments(for: commitSHA)
  }
}

/// Plans fixed, injection-resistant argv arrays for Git-backed release
/// history.  Cursor values are accepted only as complete SHA-1/SHA-256
/// object names; all other command tokens and the notes ref are constants.
public struct RepositoryReleaseHistoryCommandPolicy: Sendable {
  public static let notesReference = RepositoryReleaseHistoryCommandPlan.notesReference

  private static let commitFormat = "%H%x00%an%x00%aI%x00%B%x00%x00"
  // `for-each-ref` uses `%00` for a NUL byte; `%x00` is the pretty-format
  // spelling used by `git log` and is not portable to ref formatting.
  private static let tagFormat = "%(refname:short)%00%(objectname)%00%(objecttype)%00%(subject)%00%(*objectname)%00%(*objecttype)%00%00"

  public init() {}

  public func plan(
    for input: RepositoryReleaseHistoryCommandInput
  ) -> RepositoryReleaseHistoryCommandPlan {
    plan(request: input.request)
  }

  public func plan(
    limit: Int = RepositoryReleaseHistoryRequest.defaultLimit,
    cursor: String? = nil
  ) -> RepositoryReleaseHistoryCommandPlan {
    plan(request: RepositoryReleaseHistoryRequest(limit: limit, cursor: cursor))
  }

  public func plan(
    request: RepositoryReleaseHistoryRequest = .init()
  ) -> RepositoryReleaseHistoryCommandPlan {
    let normalized = RepositoryReleaseHistoryRequest(
      limit: request.limit,
      cursor: request.cursor
    )
    let start = normalized.cursor ?? "HEAD"
    var commitArguments = [
      "log",
      "-n",
      String(normalized.limit + 1),
      "--date=iso-strict",
      "--pretty=format:\(Self.commitFormat)",
    ]
    if normalized.cursor != nil {
      // The cursor is the last visible commit from the preceding page. Keep
      // it as the safe, full-SHA starting revision, but do not return it a
      // second time on the next page.
      commitArguments.append("--skip=1")
    }
    commitArguments.append(contentsOf: ["--end-of-options", start])
    let tagArguments = [
      "for-each-ref",
      "--format=\(Self.tagFormat)",
      "refs/tags",
    ]
    let notesArguments = [
      "notes",
      "--ref",
      Self.notesReference,
      "list",
    ]

    return RepositoryReleaseHistoryCommandPlan(
      request: normalized,
      commitArguments: commitArguments,
      tagArguments: tagArguments,
      notesArguments: notesArguments
    )
  }
}
