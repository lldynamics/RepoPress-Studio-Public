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

  public var id: String { repositoryPath }

  public init(
    repositoryPath: String,
    base: RepositoryMergeConflictContent,
    ours: RepositoryMergeConflictContent,
    theirs: RepositoryMergeConflictContent,
    final: RepositoryMergeConflictContent,
    stageEntries: [RepositoryMergeConflictIndexEntry] = []
  ) {
    self.repositoryPath = repositoryPath
    self.base = base
    self.ours = ours
    self.theirs = theirs
    self.final = final
    self.stageEntries = stageEntries
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
}

public struct RepositoryMergeConflictSession: Codable, Hashable, Sendable {
  public var rootPath: String
  public var conflicts: [RepositoryMergeConflict]
  public var scannedAt: Date
  public var diagnostic: String?

  public init(
    rootPath: String,
    conflicts: [RepositoryMergeConflict] = [],
    scannedAt: Date = Date(),
    diagnostic: String? = nil
  ) {
    self.rootPath = rootPath
    self.conflicts = conflicts
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
  case writeFailed(String)
  case stageFailed(terminated: Int32, output: String)
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
    case let .writeFailed(message):
      return "写入最终合并版本失败：\(message)"
    case let .stageFailed(terminated, output):
      let detail = output.trimmedForPublishing.nilIfEmpty ?? "请检查 Git 工作区状态。"
      return "暂存最终合并版本失败（退出码：\(terminated)）：\(detail)"
    case .repositoryChanged:
      return "仓库在合并操作期间发生变化，请重新扫描后再处理。"
    }
  }
}

public enum RepositoryMergeConflictPolicy {
  public static let maximumConflictCount = 64
  public static let maximumTextByteCount = 512 * 1_024
  public static let maximumFinalByteCount = 512 * 1_024

  /// Normalizes only safe, relative POSIX paths. Git paths containing `..`,
  /// NULs, or backslashes are rejected instead of being guessed at.
  public static func normalizedRepositoryPath(_ rawPath: String) -> String? {
    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty,
          !path.contains("\0"),
          !path.hasPrefix("/"),
          !path.contains("\\") else {
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
