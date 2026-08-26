public extension GitRepositoryOutputParser {
  /// Parses `git status --porcelain=v1 --branch -z` output.
  ///
  /// Porcelain v1's NUL-delimited rename/copy record stores the destination
  /// in the status record and the source in the following field. Preserve
  /// those fields separately; the legacy display path is derived by the model.
  func parsePorcelainV1Status(_ output: String) -> GitWorkingTreeParseResult {
    let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
    var branchStatus: RepositoryBranchStatus?
    var changedFiles: [RepositoryChangedFile] = []
    var index = 0

    while index < fields.count {
      let field = String(fields[index])
      index += 1

      if field.hasPrefix("## ") {
        branchStatus = parseBranchStatusLine(field)
        continue
      }

      guard let statusRecord = parsePorcelainStatusRecord(field) else {
        continue
      }

      if isRenameOrCopyStatus(statusRecord.status) {
        guard index < fields.count else {
          continue
        }

        let sourcePath = String(fields[index])
        index += 1
        guard !sourcePath.isEmpty else {
          continue
        }

        changedFiles.append(
          RepositoryChangedFile(
            status: statusRecord.status,
            changedPath: .sourceAndDestination(
              source: sourcePath,
              destination: statusRecord.path
            ),
            kind: changeKind(for: statusRecord.status),
            lineDiff: nil
          )
        )
        continue
      }

      changedFiles.append(
        RepositoryChangedFile(
          status: statusRecord.status,
          changedPath: .single(statusRecord.path),
          kind: changeKind(for: statusRecord.status),
          lineDiff: nil
        )
      )
    }

    return GitWorkingTreeParseResult(
      branchStatus: branchStatus,
      changedFiles: changedFiles
    )
  }

  /// Parses `git diff --name-status` output, accepting both its regular text
  /// form and its NUL-delimited `-z` form.
  func parseNameStatus(_ output: String) -> [RepositoryChangedFile] {
    if output.contains("\0") {
      return parseNULNameStatus(output)
    }

    return output.split(separator: "\n", omittingEmptySubsequences: false).compactMap {
      parseTextNameStatusRecord(String($0))
    }
  }

  /// Classifies a Git status while preserving the historical priority order.
  /// `??` is checked first, followed by added, modified, deleted, and renamed.
  /// Copy statuses intentionally remain `.other`.
  func changeKind(for status: String) -> RepositoryChangeKind {
    if status == "??" { return .untracked }
    if status.contains("A") { return .added }
    if status.contains("M") { return .modified }
    if status.contains("D") { return .deleted }
    if status.contains("R") { return .renamed }
    return .other
  }
}

private extension GitRepositoryOutputParser {
  struct PorcelainStatusRecord {
    let status: String
    let path: String
  }

  func parsePorcelainStatusRecord(_ field: String) -> PorcelainStatusRecord? {
    guard field.count >= 3 else {
      return nil
    }

    let characters = Array(field)
    guard characters[2] == " " else {
      return nil
    }

    let status = String(characters[0...1])
    let path = String(characters.dropFirst(3))
    guard !path.isEmpty else {
      return nil
    }

    return PorcelainStatusRecord(status: status, path: path)
  }

  func parseNULNameStatus(_ output: String) -> [RepositoryChangedFile] {
    let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
    var files: [RepositoryChangedFile] = []
    var index = 0

    while index < fields.count {
      let status = String(fields[index])
      index += 1
      guard !status.isEmpty else {
        continue
      }

      guard index < fields.count else {
        break
      }

      let sourceOrPath = String(fields[index])
      index += 1
      guard !sourceOrPath.isEmpty else {
        if isRenameOrCopyStatus(status), index < fields.count {
          index += 1
        }
        continue
      }

      if isRenameOrCopyStatus(status) {
        guard index < fields.count else {
          break
        }

        let destinationPath = String(fields[index])
        index += 1
        guard !destinationPath.isEmpty else {
          continue
        }

        files.append(
          RepositoryChangedFile(
            status: status,
            changedPath: .sourceAndDestination(
              source: sourceOrPath,
              destination: destinationPath
            ),
            kind: changeKind(for: status),
            lineDiff: nil
          )
        )
        continue
      }

      files.append(
        RepositoryChangedFile(
          status: status,
          changedPath: .single(sourceOrPath),
          kind: changeKind(for: status),
          lineDiff: nil
        )
      )
    }

    return files
  }

  func parseTextNameStatusRecord(_ line: String) -> RepositoryChangedFile? {
    let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      .map(String.init)
    guard let status = parts.first, !status.isEmpty, parts.count >= 2 else {
      return nil
    }

    if isRenameOrCopyStatus(status) {
      guard parts.count >= 3, !parts[1].isEmpty, !parts[2].isEmpty else {
        return nil
      }
      return RepositoryChangedFile(
        status: status,
        changedPath: .sourceAndDestination(source: parts[1], destination: parts[2]),
        kind: changeKind(for: status),
        lineDiff: nil
      )
    }

    guard !parts[1].isEmpty else {
      return nil
    }

    return RepositoryChangedFile(
      status: status,
      changedPath: .single(parts[1]),
      kind: changeKind(for: status),
      lineDiff: nil
    )
  }

  func isRenameOrCopyStatus(_ status: String) -> Bool {
    status.contains("R") || status.contains("C")
  }
}
