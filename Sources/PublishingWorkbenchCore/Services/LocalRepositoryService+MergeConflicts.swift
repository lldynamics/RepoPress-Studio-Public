import Foundation
import PublishingGitCore

extension LocalRepositoryService {
  /// Reads the current unmerged Git index and materializes a bounded,
  /// text-only three-way merge session. This is intentionally read-only.
  public func mergeConflictSession(profile: SiteProfile) -> RepositoryMergeConflictSession {
    guard let session = profile.withLocalRepositoryRootAccess({ rootURL in
      mergeConflictSession(rootURL: rootURL)
    }) else {
      return RepositoryMergeConflictSession(
        rootPath: "",
        diagnostic: RepositoryMergeConflictError.repositoryUnavailable.localizedDescription
      )
    }
    return session
  }

  func mergeConflictSession(rootURL: URL) -> RepositoryMergeConflictSession {
    let rootPath = rootURL.standardizedFileURL.path
    guard isDirectory(rootURL) else {
      return RepositoryMergeConflictSession(
        rootPath: rootPath,
        diagnostic: RepositoryMergeConflictError.repositoryUnavailable.localizedDescription
      )
    }

    let result = runGitCommand(["ls-files", "-u", "-z"], rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      return RepositoryMergeConflictSession(
        rootPath: rootPath,
        diagnostic: result.output.trimmedForPublishing.nilIfEmpty
          ?? "无法读取 Git 未解决冲突索引。"
      )
    }

    let parser = RepositoryMergeConflictIndexParser()
    let entries = parser.parse(result.standardOutput)
    let groupedEntries = Dictionary(grouping: entries, by: \.repositoryPath)
    let conflictPaths = groupedEntries.keys.sorted().prefix(
      RepositoryMergeConflictPolicy.maximumConflictCount
    )
    var conflicts: [RepositoryMergeConflict] = []
    conflicts.reserveCapacity(conflictPaths.count)

    for path in conflictPaths {
      guard let pathEntries = groupedEntries[path] else { continue }
      var entriesByStage: [RepositoryMergeConflictStage: RepositoryMergeConflictIndexEntry] = [:]
      for entry in pathEntries {
        entriesByStage[entry.stage] = entry
      }
      let base = contentForStage(entriesByStage[.base], rootURL: rootURL)
      let ours = contentForStage(entriesByStage[.ours], rootURL: rootURL)
      let theirs = contentForStage(entriesByStage[.theirs], rootURL: rootURL)
      let final = contentForWorkingTree(path: path, rootURL: rootURL)
      conflicts.append(
        RepositoryMergeConflict(
          repositoryPath: path,
          base: base,
          ours: ours,
          theirs: theirs,
          final: final,
          stageEntries: pathEntries.sorted { $0.stage.rawValue < $1.stage.rawValue }
        )
      )
    }

    var diagnostic: String?
    if result.wasOutputTruncated || groupedEntries.count > RepositoryMergeConflictPolicy.maximumConflictCount {
      diagnostic = "冲突文件数量超过可视化上限，仅显示前 \(RepositoryMergeConflictPolicy.maximumConflictCount) 个。"
    }

    return RepositoryMergeConflictSession(
      rootPath: rootPath,
      conflicts: conflicts,
      diagnostic: diagnostic
    )
  }

  /// Writes only an explicitly supplied final text and then stages that exact
  /// path. The path is validated before I/O and the index is rechecked to
  /// avoid applying a stale visual session to a changed repository.
  public func resolveMergeConflict(
    profile: SiteProfile,
    repositoryPath: String,
    finalContent: String
  ) throws {
    guard profile.resolvedLocalRepositoryRootURL != nil else {
      throw RepositoryMergeConflictError.repositoryUnavailable
    }
    _ = try profile.withLocalRepositoryRootAccess { rootURL in
      try resolveMergeConflict(
        rootURL: rootURL,
        repositoryPath: repositoryPath,
        finalContent: finalContent
      )
    }
  }

  func resolveMergeConflict(
    rootURL: URL,
    repositoryPath: String,
    finalContent: String
  ) throws {
    guard let normalizedPath = RepositoryMergeConflictPolicy.normalizedRepositoryPath(repositoryPath) else {
      throw RepositoryMergeConflictError.unsafeRepositoryPath
    }
    let finalData = Data(finalContent.utf8)
    guard finalData.count <= RepositoryMergeConflictPolicy.maximumFinalByteCount else {
      throw RepositoryMergeConflictError.finalContentTooLarge
    }
    guard !Self.looksBinary(finalContent) else {
      throw RepositoryMergeConflictError.unsupportedBinaryContent
    }

    let currentSession = mergeConflictSession(rootURL: rootURL)
    guard let currentConflict = currentSession.conflicts.first(where: {
      $0.repositoryPath == normalizedPath
    }) else {
      throw RepositoryMergeConflictError.conflictNotFound
    }
    guard currentConflict.canResolve else {
      throw RepositoryMergeConflictError.unsupportedBinaryContent
    }
    guard let fileURL = safeRepositoryFileURL(rootURL: rootURL, repositoryPath: normalizedPath) else {
      throw RepositoryMergeConflictError.unsafeRepositoryPath
    }
    var isDirectory: ObjCBool = false
    _ = fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
    guard !isDirectory.boolValue else {
      throw RepositoryMergeConflictError.unsafeRepositoryPath
    }
    guard fileManager.fileExists(atPath: fileURL.deletingLastPathComponent().path) else {
      throw RepositoryMergeConflictError.unsafeRepositoryPath
    }
    if (try? fileManager.destinationOfSymbolicLink(atPath: fileURL.path)) != nil {
      throw RepositoryMergeConflictError.unsafeRepositoryPath
    }

    do {
      try finalData.write(to: fileURL, options: [.atomic])
    } catch {
      throw RepositoryMergeConflictError.writeFailed(error.localizedDescription)
    }

    let stageResult = runGitCommand(["add", "--", normalizedPath], rootURL: rootURL)
    guard stageResult.terminationStatus == 0 else {
      throw RepositoryMergeConflictError.stageFailed(
        terminated: stageResult.terminationStatus,
        output: stageResult.output
      )
    }
  }

  private func contentForStage(
    _ entry: RepositoryMergeConflictIndexEntry?,
    rootURL: URL
  ) -> RepositoryMergeConflictContent {
    guard let entry,
          let specifier = RepositoryMergeConflictPolicy.stageSpecifier(
            entry.stage,
            repositoryPath: entry.repositoryPath
          ) else {
      return .missing()
    }

    let sizeResult = runGitCommand(["cat-file", "-s", specifier], rootURL: rootURL)
    guard sizeResult.terminationStatus == 0,
          let byteCount = Int(sizeResult.standardOutput.trimmedForPublishing) else {
      return .diagnostic(
        .unavailable,
        message: "无法读取 Git " + entry.stage.displayName + " 的对象大小。"
      )
    }
    guard byteCount <= RepositoryMergeConflictPolicy.maximumTextByteCount else {
      return .diagnostic(
        .tooLarge,
        byteCount: byteCount,
        message: "Git " + entry.stage.displayName + " 超过 "
          + String(RepositoryMergeConflictPolicy.maximumTextByteCount / 1_024)
          + " KB 文本上限。"
      )
    }

    let contentResult = runGitCommand(
      ["cat-file", "--batch"],
      rootURL: rootURL,
      inputLines: [specifier, specifier]
    )
    guard contentResult.terminationStatus == 0,
          let text = parseFirstBatchBlobText(contentResult.standardOutput, byteCount: byteCount) else {
      if contentResult.terminationStatus == 0 && byteCount > 0 && contentResult.standardOutput.isEmpty {
        return .diagnostic(
          .undecodable,
          byteCount: byteCount,
          message: "Git " + entry.stage.displayName + " 不是有效 UTF-8 文本。"
        )
      }
      return .diagnostic(
        .unavailable,
        byteCount: byteCount,
        message: "无法读取 Git " + entry.stage.displayName + " 的对象内容。"
      )
    }
    guard !Self.looksBinary(text) else {
      return .diagnostic(
        .binary,
        byteCount: byteCount,
        message: "Git " + entry.stage.displayName + " 是二进制内容，不能作为文本覆盖。"
      )
    }
    return .text(text, byteCount: byteCount)
  }

  /// `GitCommandRunner` intentionally trims diagnostics at the outer string
  /// boundary. Asking `cat-file --batch` for the same blob twice places a
  /// second header after the first payload, so the first payload's leading and
  /// trailing whitespace remains recoverable by its declared byte count.
  private func parseFirstBatchBlobText(_ output: String, byteCount: Int) -> String? {
    let bytes = Array(output.utf8)
    guard let headerEnd = bytes.firstIndex(of: 0x0A) else {
      return byteCount == 0 && output.isEmpty ? "" : nil
    }
    let header = String(decoding: bytes[..<headerEnd], as: UTF8.self)
    let fields = header.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count == 3, fields[1] == "blob", Int(fields[2]) == byteCount else {
      return nil
    }
    let contentStart = headerEnd + 1
    let contentEnd = contentStart + byteCount
    guard contentEnd <= bytes.count else {
      return nil
    }
    let data = Data(bytes[contentStart..<contentEnd])
    return String(data: data, encoding: .utf8)
  }

  private func contentForWorkingTree(
    path: String,
    rootURL: URL
  ) -> RepositoryMergeConflictContent {
    guard let fileURL = safeRepositoryFileURL(rootURL: rootURL, repositoryPath: path) else {
      return .diagnostic(.unavailable, message: "工作区路径不在仓库根目录内。")
    }
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return .missing()
    }

    guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
          let number = attributes[.size] as? NSNumber else {
      return .diagnostic(.unavailable, message: "无法读取工作区文件大小。")
    }
    let byteCount = number.intValue
    guard byteCount <= RepositoryMergeConflictPolicy.maximumTextByteCount else {
      return .diagnostic(
        .tooLarge,
        byteCount: byteCount,
        message: "工作区版本超过 "
          + String(RepositoryMergeConflictPolicy.maximumTextByteCount / 1_024)
          + " KB 文本上限。"
      )
    }
    guard let data = try? Data(contentsOf: fileURL),
          let text = String(data: data, encoding: .utf8) else {
      return .diagnostic(
        .undecodable,
        byteCount: byteCount,
        message: "工作区版本不是有效 UTF-8 文本。"
      )
    }
    guard !Self.looksBinary(text) else {
      return .diagnostic(
        .binary,
        byteCount: byteCount,
        message: "工作区版本是二进制内容，不能作为文本覆盖。"
      )
    }
    return .text(text, byteCount: byteCount)
  }

  private func safeRepositoryFileURL(rootURL: URL, repositoryPath: String) -> URL? {
    guard let normalizedPath = RepositoryMergeConflictPolicy.normalizedRepositoryPath(repositoryPath) else {
      return nil
    }
    let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
    let candidate = rootURL
      .appendingPathComponent(normalizedPath, isDirectory: false)
      .standardizedFileURL
    guard isDescendant(candidate, of: rootURL.standardizedFileURL) else { return nil }
    let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
    guard isDescendant(resolvedCandidate, of: canonicalRoot) else { return nil }
    return candidate
  }

  private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
    let rootPath = root.path
    let candidatePath = candidate.path
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }

  private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  private static func looksBinary(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      let value = scalar.value
      return value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D
    }
  }
}
