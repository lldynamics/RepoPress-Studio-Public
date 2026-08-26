import Foundation
import PublishingCoreSupport

/// Pure parser and command-shape helpers for Git's unmerged index.
public struct RepositoryMergeConflictIndexParser: Sendable {
  public init() {}

  /// Parses `git ls-files -u -z` records. A record is
  /// `<mode> <object> <stage>\\t<repository path>\\0`.
  public func parse(
    _ output: String,
    maximumEntries: Int = RepositoryMergeConflictPolicy.maximumConflictCount * 3
  ) -> [RepositoryMergeConflictIndexEntry] {
    guard maximumEntries > 0 else { return [] }
    var entries: [RepositoryMergeConflictIndexEntry] = []
    entries.reserveCapacity(min(maximumEntries, 24))

    for field in output.split(separator: "\0", omittingEmptySubsequences: true) {
      guard entries.count < maximumEntries else { break }
      let record = String(field)
      guard let tabIndex = record.firstIndex(of: "\t") else { continue }
      let header = record[..<tabIndex]
      let path = String(record[record.index(after: tabIndex)...])
      guard let normalizedPath = RepositoryMergeConflictPolicy.normalizedRepositoryPath(path),
            let entry = parseHeader(String(header), repositoryPath: normalizedPath) else {
        continue
      }
      entries.append(entry)
    }
    return entries
  }

  private func parseHeader(
    _ header: String,
    repositoryPath: String
  ) -> RepositoryMergeConflictIndexEntry? {
    let parts = header.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count == 3,
          parts[0].count == 6,
          parts[0].allSatisfy({ $0.isNumber }),
          (parts[1].count == 40 || parts[1].count == 64),
          parts[1].allSatisfy({ $0.isHexDigit }),
          let rawStage = Int(parts[2]),
          let stage = RepositoryMergeConflictStage(rawValue: rawStage) else {
      return nil
    }
    return RepositoryMergeConflictIndexEntry(
      mode: String(parts[0]),
      objectSHA: String(parts[1]),
      stage: stage,
      repositoryPath: repositoryPath
    )
  }
}

public extension RepositoryMergeConflictPolicy {
  static func stageSpecifier(
    _ stage: RepositoryMergeConflictStage,
    repositoryPath: String
  ) -> String? {
    guard let path = normalizedRepositoryPath(repositoryPath) else { return nil }
    return ":\(stage.rawValue):\(path)"
  }
}
