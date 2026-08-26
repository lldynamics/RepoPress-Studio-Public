import Foundation

public struct WorkbenchDiagnosticsContext: Codable, Equatable, Sendable {
  public var generatedAt: Date
  public var appVersion: String
  public var buildVersion: String
  public var osVersion: String
  public var localeIdentifier: String
  public var isSafeMode: Bool
  public var isQuickHideActive: Bool
  public var hasPersistenceRecoveryMessage: Bool
  public var draftCount: Int
  public var pendingDraftRecoveryCount: Int
  public var profileCount: Int
  public var activeSiteKind: String
  public var repositoryProvider: String
  public var hasLocalRepository: Bool
  public var hasRepositoryToken: Bool
  public var hasDeploymentToken: Bool
  public var lastSaveStatus: String
  public var statusMessages: [String]

  public init(
    generatedAt: Date = Date(),
    appVersion: String,
    buildVersion: String,
    osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
    localeIdentifier: String = Locale.current.identifier,
    isSafeMode: Bool,
    isQuickHideActive: Bool,
    hasPersistenceRecoveryMessage: Bool,
    draftCount: Int,
    pendingDraftRecoveryCount: Int,
    profileCount: Int,
    activeSiteKind: String,
    repositoryProvider: String,
    hasLocalRepository: Bool,
    hasRepositoryToken: Bool,
    hasDeploymentToken: Bool,
    lastSaveStatus: String,
    statusMessages: [String]
  ) {
    self.generatedAt = generatedAt
    self.appVersion = appVersion
    self.buildVersion = buildVersion
    self.osVersion = osVersion
    self.localeIdentifier = localeIdentifier
    self.isSafeMode = isSafeMode
    self.isQuickHideActive = isQuickHideActive
    self.hasPersistenceRecoveryMessage = hasPersistenceRecoveryMessage
    self.draftCount = max(0, draftCount)
    self.pendingDraftRecoveryCount = max(0, pendingDraftRecoveryCount)
    self.profileCount = max(0, profileCount)
    self.activeSiteKind = activeSiteKind
    self.repositoryProvider = repositoryProvider
    self.hasLocalRepository = hasLocalRepository
    self.hasRepositoryToken = hasRepositoryToken
    self.hasDeploymentToken = hasDeploymentToken
    self.lastSaveStatus = lastSaveStatus
    self.statusMessages = statusMessages
  }
}

public struct WorkbenchDiagnosticsExportService: Sendable {
  public static let archiveFilePrefix = "RepoPress-Diagnostics"

  public init() {}

  /// Creates a ZIP package only after the user chooses the destination.
  /// Workspace JSON, draft bodies, attachments, credential files, Keychain
  /// values, and raw OS logs are deliberately not included.
  @discardableResult
  public func export(
    context: WorkbenchDiagnosticsContext,
    to directoryURL: URL
  ) throws -> URL {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let stagingDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(
      ".\(Self.archiveFilePrefix)-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: stagingDirectoryURL) }

    let sanitizedContext = Self.sanitized(context)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let contextData = try encoder.encode(sanitizedContext)
    try contextData.write(
      to: stagingDirectoryURL.appendingPathComponent("diagnostics.json"),
      options: [.atomic]
    )

    let statusLines = sanitizedContext.statusMessages.isEmpty
      ? ["无可导出的运行状态消息。"]
      : sanitizedContext.statusMessages
    let report = ([
      "RepoPress Studio 脱敏诊断包",
      "生成时间：\(sanitizedContext.generatedAt)",
      "",
      "此包不包含：草稿正文、附件、工作台快照、API Key、Token、钥匙串内容或原始系统日志。",
      "以下状态消息已经过 URL、用户名、Token、密码和 Secret 脱敏：",
      "",
    ] + statusLines).joined(separator: "\n")
    try report.write(
      to: stagingDirectoryURL.appendingPathComponent("diagnostics.txt"),
      atomically: true,
      encoding: .utf8
    )
    try "仅包含脱敏运行环境与状态摘要；请在分享前再次确认其中没有主动添加的私密文字。\n"
      .write(
        to: stagingDirectoryURL.appendingPathComponent("README.txt"),
        atomically: true,
        encoding: .utf8
      )

    let archiveURL = directoryURL.appendingPathComponent(
      "\(Self.archiveFilePrefix)-\(Self.timestampString()).zip"
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = [
      "-c",
      "-k",
      "--sequesterRsrc",
      "--keepParent",
      stagingDirectoryURL.path,
      archiveURL.path,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw WorkbenchDiagnosticsExportError.archiveCreationFailed(
        Int32(process.terminationStatus)
      )
    }
    return archiveURL
  }

  public static func sanitized(_ context: WorkbenchDiagnosticsContext) -> WorkbenchDiagnosticsContext {
    var sanitized = context
    sanitized.appVersion = redactedText(context.appVersion)
    sanitized.buildVersion = redactedText(context.buildVersion)
    sanitized.osVersion = redactedText(context.osVersion)
    sanitized.localeIdentifier = redactedText(context.localeIdentifier)
    sanitized.activeSiteKind = redactedText(context.activeSiteKind)
    sanitized.repositoryProvider = redactedText(context.repositoryProvider)
    sanitized.lastSaveStatus = redactedText(context.lastSaveStatus)
    sanitized.statusMessages = context.statusMessages
      .map(redactedText)
      .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
      .prefix(80)
      .map { String($0.prefix(2_000)) }
    return sanitized
  }

  public static func redactedText(_ text: String) -> String {
    var redacted = GitCommandRunner.redactedDiagnosticText(text)
    redacted = replace(
      in: redacted,
      pattern: #"(?i)\b(?:sk|rk|pk)-[A-Za-z0-9_\-]{16,}\b"#,
      replacement: "[REDACTED_API_KEY]"
    )
    redacted = replace(
      in: redacted,
      pattern: #"(?i)(\b(?:api[_-]?key|token|password|passwd|secret|client[_-]?secret|access[_-]?token|refresh[_-]?token)\b\s*[:=]\s*)[^\s,;&]+"#,
      replacement: "$1[REDACTED]"
    )
    return redacted
  }

  private static func replace(in text: String, pattern: String, replacement: String) -> String {
    text.replacingOccurrences(
      of: pattern,
      with: replacement,
      options: .regularExpression
    )
  }

  private static func timestampString() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
    return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
  }
}

public enum WorkbenchDiagnosticsExportError: LocalizedError, Equatable, Sendable {
  case archiveCreationFailed(Int32)

  public var errorDescription: String? {
    switch self {
    case .archiveCreationFailed(let status):
      return "无法创建脱敏诊断包（ditto 退出码：\(status)）。"
    }
  }
}
