import Foundation

/// The smallest units of authority that an in-app Agent may be granted.
///
/// The master `allowsApplicationTools` switch remains a separate connection
/// setting.  This policy only describes the scopes that are eligible when the
/// master switch is on.  Command execution still has to pass the command
/// registry and confirmation gates.
public enum AIAgentPermissionScope: String, Codable, CaseIterable, Identifiable, Hashable, Sendable
{
  case localRead
  case draftCreation
  case contentModification
  case networkAccess
  case repositoryWrite
  case publishing

  public var id: String { rawValue }

  /// Stable user-facing title.  The macOS settings surface may localize these
  /// strings through its own resource bundle; keeping the values here makes
  /// the policy useful to non-UI consumers as well.
  public var localizedTitle: String {
    switch self {
    case .localRead:
      return "读取本地内容"
    case .draftCreation:
      return "新建文章草稿"
    case .contentModification:
      return "修改文章内容"
    case .networkAccess:
      return "访问网络"
    case .repositoryWrite:
      return "写入代码仓库"
    case .publishing:
      return "发布网站"
    }
  }

  public var localizedDescription: String {
    switch self {
    case .localRead:
      return "允许 Agent 读取当前工作区中与请求相关的本地文章和元数据。"
    case .draftCreation:
      return "允许 Agent 创建新的空白文章草稿；正文写入仍受单独确认保护。"
    case .contentModification:
      return "允许 Agent 提议或执行文章正文、摘要和元数据的修改。"
    case .networkAccess:
      return "允许 Agent 使用已声明的网络工具访问外部资料或服务。"
    case .repositoryWrite:
      return "允许 Agent 写入本地或远端代码仓库；实际写入仍遵守确认流程。"
    case .publishing:
      return "允许 Agent 执行发布相关工具；发布操作仍需要最终确认。"
    }
  }
}

/// Fine-grained Agent authority for one reusable AI connection.
///
/// Older snapshots did not persist this policy.  Decoding a missing policy is
/// intentionally conservative: only local reads and draft creation are
/// eligible.  This avoids silently granting network, content, repository, or
/// publishing authority after an upgrade.
public struct AIAgentPermissionPolicy: Codable, Hashable, Sendable {
  public static let legacySafeDefault = Self(
    enabledScopes: [.localRead, .draftCreation]
  )

  public static let disabled = Self(enabledScopes: [])

  public static let all = Self(enabledScopes: Set(AIAgentPermissionScope.allCases))

  public var enabledScopes: Set<AIAgentPermissionScope>

  public init(
    enabledScopes: Set<AIAgentPermissionScope> = [.localRead, .draftCreation]
  ) {
    self.enabledScopes = enabledScopes
  }

  /// The migration-safe policy used when a persisted value is absent.
  public static var `default`: Self { legacySafeDefault }

  public var isDefault: Bool {
    self == Self.legacySafeDefault
  }

  public var isDisabled: Bool {
    enabledScopes.isEmpty
  }

  public var isFullyEnabled: Bool {
    enabledScopes == Set(AIAgentPermissionScope.allCases)
  }

  public func allows(_ scope: AIAgentPermissionScope) -> Bool {
    enabledScopes.contains(scope)
  }

  /// Applies the connection-level master switch without mutating the stored
  /// preferences.  Turning the master switch back on therefore restores the
  /// per-scope choices instead of losing them.
  public func effectiveScopes(masterEnabled: Bool) -> Set<AIAgentPermissionScope> {
    masterEnabled ? enabledScopes : []
  }

  public func allows(
    _ scope: AIAgentPermissionScope,
    masterEnabled: Bool
  ) -> Bool {
    masterEnabled && allows(scope)
  }

  public mutating func setAllowed(
    _ allowed: Bool,
    for scope: AIAgentPermissionScope
  ) {
    if allowed {
      enabledScopes.insert(scope)
    } else {
      enabledScopes.remove(scope)
    }
  }

  /// Restores the migration-safe baseline, retaining the master switch that
  /// lives in `AIProviderAdvancedSettings`.
  public mutating func reset() {
    enabledScopes = Self.legacySafeDefault.enabledScopes
  }

  private enum CodingKeys: String, CodingKey {
    case enabledScopes
    // Accept the early name used by development snapshots without emitting it.
    case allowedScopes
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawScopes =
      try container.decodeIfPresent([String].self, forKey: .enabledScopes)
      ?? container.decodeIfPresent([String].self, forKey: .allowedScopes)

    guard let rawScopes else {
      self = .legacySafeDefault
      return
    }

    // Ignore unknown future scopes so a newer app can still be opened by an
    // older build without making the entire connection profile undecodable.
    enabledScopes = Set(rawScopes.compactMap(AIAgentPermissionScope.init(rawValue:)))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(
      enabledScopes.map(\.rawValue).sorted(),
      forKey: .enabledScopes
    )
  }
}
