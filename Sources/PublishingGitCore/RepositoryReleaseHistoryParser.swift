import Foundation

/// Parses the machine-readable release-history output produced by
/// `RepositoryReleaseHistoryCommandPolicy`.
///
/// Git's `-z`/`%x00` output is parsed as records separated by two NUL bytes
/// and fields separated by one NUL byte.  No Git process, repository, or
/// filesystem is accessed here.
public struct RepositoryReleaseHistoryParser: Sendable {
  public static let maximumNoteBytes = 16 * 1024

  private let commitParser: GitRepositoryOutputParser

  public init() {
    commitParser = GitRepositoryOutputParser()
  }

  /// Parses three independent Git command results into one snapshot.  The
  /// notes result is optional so a caller can deliberately render a history
  /// view when the notes ref was not requested or is not present.
  public func parse(
    commitResult: GitCommandResult,
    tagResult: GitCommandResult,
    notesResult: GitCommandResult? = nil,
    request: RepositoryReleaseHistoryRequest = .init(),
    shallowResult: GitCommandResult? = nil,
    fallbackDate: Date = Date()
  ) -> RepositoryReleaseHistorySnapshot {
    let commits = parseCommitOutput(
      commitResult.standardOutput,
      fallbackDate: fallbackDate
    )
    let tags = parseTagOutput(tagResult.standardOutput)
    let notes = notesResult.map { parseNoteOutput($0.standardOutput) }

    var diagnostics = commits.diagnostics
    diagnostics.append(contentsOf: tags.diagnostics)
    if let notes {
      diagnostics.append(contentsOf: notes.diagnostics)
    }
    diagnostics.append(contentsOf: commandDiagnostics(commitResult, source: "history"))
    diagnostics.append(contentsOf: commandDiagnostics(tagResult, source: "tags"))
    if let notesResult {
      diagnostics.append(contentsOf: commandDiagnostics(notesResult, source: "notes"))
    }

    let hasExtraCommit = commits.commits.count > request.limit
    let visibleCommits = Array(commits.commits.prefix(request.limit))
    let nextCursor = hasExtraCommit ? visibleCommits.last?.sha : nil

    var partial = hasExtraCommit || !diagnostics.isEmpty
    if commitResult.didTimeOut || commitResult.wasOutputTruncated ||
        tagResult.didTimeOut || tagResult.wasOutputTruncated ||
        notesResult?.didTimeOut == true || notesResult?.wasOutputTruncated == true {
      partial = true
    }

    let shallow = parseShallow(shallowResult)
    return RepositoryReleaseHistorySnapshot(
      commits: visibleCommits,
      tags: tags.tags,
      notes: notes?.notes ?? [],
      historyAvailability: availability(of: commitResult),
      notesAvailability: notesResult.map(availability(of:)) ?? .unavailable,
      diagnostics: diagnostics,
      partial: partial,
      cursor: nextCursor,
      shallow: shallow
    )
  }

  /// Source-compatible spelling for callers that name each result by its
  /// Git resource rather than by the command that loaded it.
  public func parse(
    commits: GitCommandResult,
    tags: GitCommandResult,
    notes: GitCommandResult? = nil,
    request: RepositoryReleaseHistoryRequest = .init(),
    shallow: GitCommandResult? = nil,
    fallbackDate: Date = Date()
  ) -> RepositoryReleaseHistorySnapshot {
    parse(
      commitResult: commits,
      tagResult: tags,
      notesResult: notes,
      request: request,
      shallowResult: shallow,
      fallbackDate: fallbackDate
    )
  }

  /// Convenience overload for pure parser tests and Workbench adapters that
  /// keep command output separate from process diagnostics.
  public func parse(
    commitOutput: String,
    tagOutput: String,
    noteOutput: String? = nil,
    request: RepositoryReleaseHistoryRequest = .init(),
    shallow: Bool = false,
    fallbackDate: Date = Date()
  ) -> RepositoryReleaseHistorySnapshot {
    parse(
      commitResult: GitCommandResult(terminationStatus: 0, output: commitOutput),
      tagResult: GitCommandResult(terminationStatus: 0, output: tagOutput),
      notesResult: noteOutput.map {
        GitCommandResult(terminationStatus: 0, output: $0)
      },
      request: request,
      shallowResult: shallow
        ? GitCommandResult(terminationStatus: 0, output: "true")
        : GitCommandResult(terminationStatus: 0, output: "false"),
      fallbackDate: fallbackDate
    )
  }

  /// Parses one NUL-delimited commit-log stream.  The canonical record is
  /// `sha\0author\0date\0%B\0\0`; the body may contain arbitrary newlines
  /// and Unicode text.
  public func parseCommitOutput(
    _ output: String,
    fallbackDate: Date = Date()
  ) -> RepositoryReleaseHistoryCommitParseResult {
    var commits: [RepositoryCommitInfo] = []
    var diagnostics: [RepositoryReleaseHistoryDiagnostic] = []

    for (index, fields) in records(in: output).enumerated() {
      guard fields.count >= 4 else {
        diagnostics.append(diagnostic(
          "历史记录 \(index + 1) 缺少必要字段。",
          source: "history"
        ))
        continue
      }

      let sha = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let author = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
      let dateText = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
      let message = trimCommitMessage(fields[3])
      guard isObjectName(sha) else {
        diagnostics.append(diagnostic(
          "历史记录 \(index + 1) 的 commit SHA 无效。",
          source: "history"
        ))
        continue
      }
      guard !author.isEmpty, !message.isEmpty else {
        diagnostics.append(diagnostic(
          "历史记录 \(index + 1) 缺少作者或提交消息。",
          source: "history"
        ))
        continue
      }

      commits.append(
        RepositoryCommitInfo(
          sha: sha,
          shortSHA: String(sha.prefix(8)),
          author: author,
          date: commitParser.parseGitDate(dateText, fallbackDate: fallbackDate),
          message: message
        )
      )
    }

    return RepositoryReleaseHistoryCommitParseResult(
      commits: commits,
      diagnostics: diagnostics
    )
  }

  /// Parses one NUL-delimited tag stream.  The canonical record is
  /// `name\0objectSHA\0objectType\0subject\0peeledSHA\0peeledType\0\0`.
  /// A shorter three-field form (`name`, `objectSHA`, `subject`) is accepted
  /// for lightweight fixtures and older Git adapters.
  public func parseTagOutput(_ output: String) -> RepositoryReleaseTagParseResult {
    var tags: [RepositoryReleaseTag] = []
    var diagnostics: [RepositoryReleaseHistoryDiagnostic] = []

    for (index, fields) in records(in: output).enumerated() {
      guard fields.count >= 3 else {
        diagnostics.append(diagnostic(
          "标签记录 \(index + 1) 缺少必要字段。",
          source: "tags"
        ))
        continue
      }

      let name = fields[0]
      let objectSHA = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, isObjectName(objectSHA) else {
        diagnostics.append(diagnostic(
          "标签记录 \(index + 1) 的名称或 SHA 无效。",
          source: "tags"
        ))
        continue
      }

      let objectType: String?
      let subject: String
      let peeledSHA: String?
      let peeledType: String?

      if fields.count >= 6 {
        objectType = fields[2].nilIfEmpty
        subject = fields[3]
        peeledSHA = fields[4].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        peeledType = fields[5].nilIfEmpty
      } else if fields.count == 5 {
        objectType = fields[2].nilIfEmpty
        subject = fields[3]
        peeledSHA = fields[4].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        peeledType = nil
      } else if fields.count == 4 {
        objectType = fields[2].nilIfEmpty
        subject = fields[3]
        peeledSHA = nil
        peeledType = nil
      } else {
        objectType = nil
        subject = fields[2]
        peeledSHA = nil
        peeledType = nil
      }

      if let peeledSHA, !isObjectName(peeledSHA) {
        diagnostics.append(diagnostic(
          "标签记录 \(index + 1) 的 peeled SHA 无效。",
          source: "tags"
        ))
        continue
      }

      let targetSHA = peeledSHA ?? objectSHA
      tags.append(
        RepositoryReleaseTag(
          name: name,
          objectSHA: objectSHA,
          targetSHA: targetSHA,
          objectType: objectType,
          targetType: peeledType,
          subject: subject,
          isAnnotated: peeledSHA != nil || objectType == "tag"
        )
      )
    }

    return RepositoryReleaseTagParseResult(tags: tags, diagnostics: diagnostics)
  }

  /// Parses one NUL-delimited note stream.  The canonical record is
  /// `commitSHA\0json\0\0`; a three-field `noteSHA\0commitSHA\0json\0\0`
  /// form is also accepted.  Invalid JSON, an absent/integer schema other
  /// than 1, and payloads over 16 KiB only add diagnostics and do not abort
  /// parsing the remaining records.
  public func parseNoteOutput(
    _ output: String,
    commitSHA: String? = nil
  ) -> RepositoryReleaseNoteParseResult {
    var notes: [RepositoryReleaseNote] = []
    var diagnostics: [RepositoryReleaseHistoryDiagnostic] = []

    for (index, fields) in records(in: output).enumerated() {
      guard fields.count >= 2 else {
        diagnostics.append(diagnostic(
          "Commit note 记录 \(index + 1) 缺少必要字段。",
          source: "notes"
        ))
        continue
      }

      let json = fields.last ?? ""
      let associatedSHA: String?
      if let commitSHA, isObjectName(commitSHA) {
        associatedSHA = commitSHA
      } else if fields.count >= 3,
                isObjectName(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
        associatedSHA = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        associatedSHA = fields.first.map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }

      guard let associatedSHA, isObjectName(associatedSHA) else {
        diagnostics.append(diagnostic(
          "Commit note 记录 \(index + 1) 的 commit SHA 无效。",
          source: "notes"
        ))
        continue
      }

      guard Data(json.utf8).count <= Self.maximumNoteBytes else {
        diagnostics.append(diagnostic(
          "Commit note 记录 \(index + 1) 超过 16 KiB 限制。",
          source: "notes"
        ))
        continue
      }

      guard let object = jsonObject(from: json),
            let schema = schemaVersion(in: object),
            schema == 1 else {
        diagnostics.append(diagnostic(
          "Commit note 记录 \(index + 1) 不是有效的 schema=1 JSON。",
          source: "notes"
        ))
        continue
      }

      notes.append(
        RepositoryReleaseNote(
          commitSHA: associatedSHA,
          schemaVersion: schema,
          rawJSON: json,
          metadata: scalarMetadata(from: object)
        )
      )
    }

    return RepositoryReleaseNoteParseResult(notes: notes, diagnostics: diagnostics)
  }

  // MARK: - Compatibility aliases

  public func parseCommits(
    _ output: String,
    fallbackDate: Date = Date()
  ) -> [RepositoryCommitInfo] {
    parseCommitOutput(output, fallbackDate: fallbackDate).commits
  }

  public func parseTags(_ output: String) -> [RepositoryReleaseTag] {
    parseTagOutput(output).tags
  }

  public func parseNotes(
    _ output: String,
    commitSHA: String? = nil
  ) -> [RepositoryReleaseNote] {
    parseNoteOutput(output, commitSHA: commitSHA).notes
  }

  // MARK: - Private helpers

  private func records(in output: String) -> [[String]] {
    guard !output.isEmpty else { return [] }

    return output
      .components(separatedBy: "\0\0")
      .filter { !$0.isEmpty }
      .map { record in
        record.components(separatedBy: "\0")
      }
  }

  private func trimCommitMessage(_ message: String) -> String {
    message.trimmingCharacters(in: .newlines)
  }

  private func isObjectName(_ value: String) -> Bool {
    RepositoryReleaseHistoryRequest.isValidCursor(value)
  }

  private func jsonObject(from value: String) -> [String: Any]? {
    guard let data = value.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
      return nil
    }
    return dictionary
  }

  private func schemaVersion(in object: [String: Any]) -> Int? {
    object["schema"] as? Int
  }

  private func scalarMetadata(from object: [String: Any]) -> [String: String] {
    object.reduce(into: [String: String]()) { result, pair in
      switch pair.value {
      case let value as String:
        result[pair.key] = value
      case let value as Int:
        result[pair.key] = String(value)
      case let value as Double:
        result[pair.key] = String(value)
      case let value as Bool:
        result[pair.key] = value ? "true" : "false"
      default:
        break
      }
    }
  }

  private func availability(of result: GitCommandResult) -> RepositoryReleaseHistoryAvailability {
    if result.terminationStatus == 0, !result.didTimeOut {
      return .available
    }
    if result.terminationStatus == 1, !result.didTimeOut {
      return .unavailable
    }
    return .unknown
  }

  private func parseShallow(_ result: GitCommandResult?) -> Bool {
    guard let result, result.terminationStatus == 0 else { return false }
    let value = result.standardOutput
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return value == "true" || value == "1" || value == "yes"
  }

  private func commandDiagnostics(
    _ result: GitCommandResult,
    source: String
  ) -> [RepositoryReleaseHistoryDiagnostic] {
    var diagnostics: [RepositoryReleaseHistoryDiagnostic] = []
    if !result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      diagnostics.append(
        diagnostic(
          result.standardError.trimmingCharacters(in: .whitespacesAndNewlines),
          source: source,
          terminationStatus: result.terminationStatus == 0 ? nil : result.terminationStatus
        )
      )
    }
    if result.terminationStatus != 0 {
      diagnostics.append(
        diagnostic(
          "Git \(source) 命令退出状态 \(result.terminationStatus)。",
          source: source,
          terminationStatus: result.terminationStatus
        )
      )
    }
    if result.didTimeOut {
      diagnostics.append(diagnostic("Git \(source) 命令超时。", source: source))
    }
    if result.wasOutputTruncated {
      diagnostics.append(diagnostic("Git \(source) 输出已截断。", source: source))
    }
    return diagnostics
  }

  private func diagnostic(
    _ message: String,
    source: String,
    terminationStatus: Int32? = nil
  ) -> RepositoryReleaseHistoryDiagnostic {
    RepositoryReleaseHistoryDiagnostic(
      message: message,
      source: source,
      terminationStatus: terminationStatus
    )
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
