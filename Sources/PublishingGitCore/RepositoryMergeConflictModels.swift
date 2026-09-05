import Foundation
import PublishingCoreSupport

/// The three Git index stages used to describe a text merge conflict.
public enum RepositoryMergeConflictStage: Int, Codable, Hashable, Sendable, CaseIterable {
  case base = 1
  case ours = 2
  case theirs = 3

  public var displayName: String {
    switch self {
    case .base:
      return "共同基线"
    case .ours:
      return "本地版本"
    case .theirs:
      return "远程版本"
    }
  }
}

/// One unmerged index record from `git ls-files -u -z`.
public struct RepositoryMergeConflictIndexEntry: Codable, Hashable, Sendable {
  public var mode: String
  public var objectSHA: String
  public var stage: RepositoryMergeConflictStage
  public var repositoryPath: String

  public init(
    mode: String,
    objectSHA: String,
    stage: RepositoryMergeConflictStage,
    repositoryPath: String
  ) {
    self.mode = mode
    self.objectSHA = objectSHA
    self.stage = stage
    self.repositoryPath = repositoryPath
  }
}

public enum RepositoryMergeConflictContentKind: String, Codable, Hashable, Sendable {
  case text
  case missing
  case binary
  case undecodable
  case tooLarge
  case unavailable

  public var displayName: String {
    switch self {
    case .text:
      return "文本"
    case .missing:
      return "不存在"
    case .binary:
      return "二进制"
    case .undecodable:
      return "无法解码"
    case .tooLarge:
      return "内容过大"
    case .unavailable:
      return "读取失败"
    }
  }
}

/// A bounded representation of one conflict side. Non-text content is kept as
/// a diagnostic only, so a binary blob can never reach the text writer.
public struct RepositoryMergeConflictContent: Codable, Hashable, Sendable {
  public var kind: RepositoryMergeConflictContentKind
  public var text: String?
  public var byteCount: Int
  public var diagnostic: String?

  public init(
    kind: RepositoryMergeConflictContentKind,
    text: String? = nil,
    byteCount: Int = 0,
    diagnostic: String? = nil
  ) {
    self.kind = kind
    self.text = text
    self.byteCount = max(0, byteCount)
    self.diagnostic = diagnostic
  }

  public var isText: Bool {
    kind == .text && text != nil
  }

  public var isEditable: Bool {
    isText
  }

  public var displayText: String {
    if let text, isText {
      return text
    }
    return diagnostic ?? "无法读取此版本的文本内容。"
  }

  public static func text(_ value: String, byteCount: Int? = nil) -> Self {
    Self(
      kind: .text,
      text: value,
      byteCount: byteCount ?? value.utf8.count
    )
  }

  public static func missing(_ diagnostic: String = "该版本不存在此文件。") -> Self {
    Self(kind: .missing, diagnostic: diagnostic)
  }

  public static func diagnostic(
    _ kind: RepositoryMergeConflictContentKind,
    byteCount: Int = 0,
    message: String
  ) -> Self {
    Self(kind: kind, byteCount: byteCount, diagnostic: message)
  }
}

public struct RepositoryMergeConflict: Identifiable, Codable, Hashable, Sendable {
  public var repositoryPath: String
  public var base: RepositoryMergeConflictContent
  public var ours: RepositoryMergeConflictContent
  public var theirs: RepositoryMergeConflictContent
  public var final: RepositoryMergeConflictContent
  public var stageEntries: [RepositoryMergeConflictIndexEntry]
  /// Hash of the exact working-tree blob captured during the conflict scan.
  /// It is nil only when the file is absent or Git could not hash it.
  public var workingTreeContentSHA: String?

  public var id: String { repositoryPath }

  public init(
    repositoryPath: String,
    base: RepositoryMergeConflictContent,
    ours: RepositoryMergeConflictContent,
    theirs: RepositoryMergeConflictContent,
    final: RepositoryMergeConflictContent,
    stageEntries: [RepositoryMergeConflictIndexEntry] = [],
    workingTreeContentSHA: String? = nil
  ) {
    self.repositoryPath = repositoryPath
    self.base = base
    self.ours = ours
    self.theirs = theirs
    self.final = final
    self.stageEntries = stageEntries
    self.workingTreeContentSHA = workingTreeContentSHA
  }

  public var canResolve: Bool {
    let unsupportedKinds: Set<RepositoryMergeConflictContentKind> = [
      .binary, .undecodable, .tooLarge, .unavailable,
    ]
    let visibleSides = [ours, theirs, final]
    return final.isText
      && (ours.isText || theirs.isText)
      && !visibleSides.contains(where: { unsupportedKinds.contains($0.kind) })
  }

  /// A deletion is safe only for Git's actual modify/delete index shapes:
  /// base plus exactly one surviving side. Add/add, modify/modify, and other
  /// unmerged forms must be resolved as text or outside this workflow.
  public var isModifyDeleteConflict: Bool {
    let stages = Set(stageEntries.map(\.stage))
    let isModifyDeleteShape = stages == [.base, .ours] || stages == [.base, .theirs]
    let supportedModes: Set<String> = ["100644", "100755"]
    return stageEntries.count == 2
      && isModifyDeleteShape
      && stageEntries.allSatisfy { supportedModes.contains($0.mode) }
  }

  /// Binary modify/delete conflicts intentionally remain deletable even
  /// though they can never be routed through the UTF-8 text writer.
  public var canResolveByDeleting: Bool {
    isModifyDeleteConflict
  }

  /// The opaque compare-and-swap snapshot which must accompany every
  /// resolution request. A present working-tree file without a Git blob hash
  /// is deliberately not resolvable: accepting it would weaken the CAS check.
  public var resolutionExpectation: RepositoryMergeConflictExpectation? {
    guard final.kind == .missing || workingTreeContentSHA != nil else {
      return nil
    }
    return RepositoryMergeConflictExpectation(
      repositoryPath: repositoryPath,
      stageEntries: stageEntries,
      finalContent: final,
      workingTreeContentSHA: workingTreeContentSHA
    )
  }
}

/// A canonical snapshot of a single unmerged path. The service rescans and
/// compares this value immediately before mutating the working tree or index.
public struct RepositoryMergeConflictExpectation: Hashable, Sendable {
  public var repositoryPath: String
  public var stageEntries: [RepositoryMergeConflictIndexEntry]
  public var finalContent: RepositoryMergeConflictContent
  /// Git's object hash for an existing working-tree file, or nil when the
  /// working-tree side is absent.
  public var workingTreeContentSHA: String?

  public init?(
    repositoryPath: String,
    stageEntries: [RepositoryMergeConflictIndexEntry],
    finalContent: RepositoryMergeConflictContent,
    workingTreeContentSHA: String?
  ) {
    guard
      let normalizedPath = RepositoryMergeConflictPolicy.normalizedRepositoryPath(repositoryPath)
    else {
      return nil
    }

    var canonicalEntries: [RepositoryMergeConflictIndexEntry] = []
    canonicalEntries.reserveCapacity(stageEntries.count)
    for entry in stageEntries {
      guard
        let entryPath = RepositoryMergeConflictPolicy.normalizedRepositoryPath(
          entry.repositoryPath),
        entryPath == normalizedPath
      else {
        return nil
      }
      canonicalEntries.append(
        RepositoryMergeConflictIndexEntry(
          mode: entry.mode,
          objectSHA: entry.objectSHA,
          stage: entry.stage,
          repositoryPath: normalizedPath
        )
      )
    }

    self.repositoryPath = normalizedPath
    self.stageEntries = canonicalEntries.sorted {
      if $0.stage != $1.stage { return $0.stage.rawValue < $1.stage.rawValue }
      if $0.mode != $1.mode { return $0.mode < $1.mode }
      return $0.objectSHA < $1.objectSHA
    }
    self.finalContent = finalContent
    self.workingTreeContentSHA = workingTreeContentSHA
  }
}

public enum RepositoryMergeConflictResolution: Hashable, Sendable {
  case finalText(String)
  case delete
}

public struct RepositoryMergeConflictResolutionRequest: Hashable, Sendable {
  public var expectation: RepositoryMergeConflictExpectation
  public var resolution: RepositoryMergeConflictResolution

  public init(
    expectation: RepositoryMergeConflictExpectation,
    resolution: RepositoryMergeConflictResolution
  ) {
    self.expectation = expectation
    self.resolution = resolution
  }
}

public struct RepositoryMergeConflictSession: Codable, Hashable, Sendable {
  public var rootPath: String
  public var conflicts: [RepositoryMergeConflict]
  /// Sequencer/index lifecycle captured in the same repository scan as the
  /// conflict list, so staging the last path cannot make the operation vanish.
  public var operationLifecycle: RepositoryOperationLifecycle?
  public var scannedAt: Date
  public var diagnostic: String?

  public init(
    rootPath: String,
    conflicts: [RepositoryMergeConflict] = [],
    operationLifecycle: RepositoryOperationLifecycle? = nil,
    scannedAt: Date = Date(),
    diagnostic: String? = nil
  ) {
    self.rootPath = rootPath
    self.conflicts = conflicts
    self.operationLifecycle = operationLifecycle
    self.scannedAt = scannedAt
    self.diagnostic = diagnostic
  }

  public var unresolvedCount: Int { conflicts.count }

  public var isEmpty: Bool { conflicts.isEmpty }
}

public enum RepositoryMergeConflictError: Error, LocalizedError, Hashable, Sendable {
  case repositoryUnavailable
  case invalidRepositoryPath
  case conflictNotFound
  case unsafeRepositoryPath
  case finalContentTooLarge
  case unsupportedBinaryContent
  case unresolvedConflictMarkers
  case deleteNotAllowed
  case operationInProgress
  case writeFailed(String)
  case stageFailed(terminated: Int32, output: String)
  case deleteFailed(terminated: Int32, output: String)
  case repositoryChanged

  public var errorDescription: String? {
    switch self {
    case .repositoryUnavailable:
      return "未找到可用的本地 Git 仓库。"
    case .invalidRepositoryPath:
      return "仓库路径无效。"
    case .conflictNotFound:
      return "该文件已经不在 Git 未解决冲突索引中，请重新扫描。"
    case .unsafeRepositoryPath:
      return "拒绝写入仓库根目录之外的路径。"
    case .finalContentTooLarge:
      return "最终合并内容超过安全大小限制。"
    case .unsupportedBinaryContent:
      return "二进制或无法解码的冲突不能通过文本合并覆盖。"
    case .unresolvedConflictMarkers:
      return "最终版本仍包含 Git 冲突标记，请先明确选择或手工编辑。"
    case .deleteNotAllowed:
      return "仅“修改/删除”冲突可明确选择删除此文件。"
    case .operationInProgress:
      return "另一个仓库操作正在进行，请完成后再处理冲突。"
    case .writeFailed(let message):
      return "写入最终合并版本失败：\(message)"
    case .stageFailed(let terminated, let output):
      let detail = output.trimmedForPublishing.nilIfEmpty ?? "请检查 Git 工作区状态。"
      return "暂存最终合并版本失败（退出码：\(terminated)）：\(detail)"
    case .deleteFailed(let terminated, let output):
      let detail = output.trimmedForPublishing.nilIfEmpty ?? "请检查 Git 工作区状态。"
      return "删除并暂存冲突文件失败（退出码：\(terminated)）：\(detail)"
    case .repositoryChanged:
      return "仓库在合并操作期间发生变化，请重新扫描后再处理。"
    }
  }
}

public enum RepositoryMergeConflictPolicy {
  public static let maximumConflictCount = 64
  public static let maximumTextByteCount = 512 * 1_024
  public static let maximumFinalByteCount = 512 * 1_024

  public static func containsConflictMarkers(_ text: String) -> Bool {
    text.components(separatedBy: "\n").contains { line in
      isLabeledConflictMarker(line, marker: "<")
        || isLabeledConflictMarker(line, marker: "|")
        || isLabeledConflictMarker(line, marker: ">")
    }
  }

  /// Git can be configured to use conflict markers wider than seven
  /// characters. Match those labelled boundary markers, while deliberately
  /// not treating an isolated `=======` line as a conflict: that is also valid
  /// Markdown Setext-heading syntax.
  private static func isLabeledConflictMarker(_ line: String, marker: Character) -> Bool {
    let markerCount = line.prefix(while: { $0 == marker }).count
    guard markerCount >= 7 else { return false }
    let remainder = line.dropFirst(markerCount)
    return remainder.isEmpty || remainder.first?.isWhitespace == true
  }

  /// Normalizes only safe, relative POSIX paths. Git paths containing `..`,
  /// NULs, or backslashes are rejected instead of being guessed at.
  public static func normalizedRepositoryPath(_ rawPath: String) -> String? {
    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty,
      !path.contains("\0"),
      !path.hasPrefix("/"),
      !path.contains("\\")
    else {
      return nil
    }

    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains(where: { $0 == ".." }) else { return nil }
    let normalized = path.normalizedRelativePath()
    guard !normalized.isEmpty, normalized == path else {
      return nil
    }
    return normalized
  }
}
