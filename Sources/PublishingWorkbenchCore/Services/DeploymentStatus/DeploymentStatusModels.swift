import Foundation

public enum DeploymentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case githubPages
  case gitlabPages
  case netlify
  case vercel
  case cloudflarePages
  case custom

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .githubPages:
      return "GitHub Pages"
    case .gitlabPages:
      return "GitLab Pages"
    case .netlify:
      return "Netlify"
    case .vercel:
      return "Vercel"
    case .cloudflarePages:
      return "Cloudflare Pages"
    case .custom:
      return CoreL10n.text("自定义端点")
    }
  }

  public var systemImage: String {
    switch self {
    case .githubPages, .gitlabPages:
      return "point.3.connected.trianglepath.dotted"
    case .netlify, .vercel, .cloudflarePages:
      return "cloud"
    case .custom:
      return "network"
    }
  }

  public var integrationDepth: DeploymentProviderIntegrationDepth {
    switch self {
    case .githubPages:
      return DeploymentProviderIntegrationDepth(
        title: "GitHub Pages / Actions API",
        detail: CoreL10n.text("读取 Pages 状态、Actions runs，并可继续校验站点 URL 或自定义状态端点。")
      )
    case .gitlabPages:
      return DeploymentProviderIntegrationDepth(
        title: "GitLab Pipeline API",
        detail: CoreL10n.text("读取项目 Pipeline，并可继续校验 GitLab Pages URL 或自定义状态端点。")
      )
    case .netlify:
      return DeploymentProviderIntegrationDepth(
        title: "Netlify Deploy API",
        detail: CoreL10n.text("配置 Site ID 和 Token 后调用 Netlify Deploy API；否则降级为站点 URL/状态端点检查。")
      )
    case .vercel:
      return DeploymentProviderIntegrationDepth(
        title: "Vercel Deployments API",
        detail: CoreL10n.text(
          "配置 Project ID 和 Token 后调用 Vercel Deployments API，并按分支/commit 关联当前发布。")
      )
    case .cloudflarePages:
      return DeploymentProviderIntegrationDepth(
        title: "Cloudflare Pages API",
        detail: CoreL10n.text(
          "配置 Account ID、Pages Project 和 Token 后调用 Cloudflare Pages Deployments API。")
      )
    case .custom:
      return DeploymentProviderIntegrationDepth(
        title: CoreL10n.text("自定义状态端点"),
        detail: CoreL10n.text("读取自定义 JSON/HTTP 状态端点，或使用站点 URL 做可达性与发布后页面校验。")
      )
    }
  }
}

public struct DeploymentProviderIntegrationDepth: Codable, Hashable, Sendable {
  public var title: String
  public var detail: String

  public init(title: String, detail: String) {
    self.title = title
    self.detail = detail
  }
}

public enum DeploymentStatusLevel: String, Codable, CaseIterable, Identifiable, Sendable {
  case success
  case running
  case failed
  case unknown

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .success:
      return CoreL10n.text("正常")
    case .running:
      return CoreL10n.text("部署中")
    case .failed:
      return CoreL10n.text("失败")
    case .unknown:
      return CoreL10n.text("未知")
    }
  }

  public var systemImage: String {
    switch self {
    case .success:
      return "checkmark.seal"
    case .running:
      return "hourglass"
    case .failed:
      return "xmark.octagon"
    case .unknown:
      return "questionmark.circle"
    }
  }
}

public enum DeploymentLogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
  case info
  case warning
  case error

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .info:
      return CoreL10n.text("信息")
    case .warning:
      return CoreL10n.text("警告")
    case .error:
      return CoreL10n.text("错误")
    }
  }

  public var systemImage: String {
    switch self {
    case .info:
      return "info.circle"
    case .warning:
      return "exclamationmark.triangle"
    case .error:
      return "xmark.octagon"
    }
  }
}

/// A bounded, structured excerpt from a provider build log.
///
/// Provider responses are treated as untrusted input. The deployment service
/// bounds and redacts every entry before it reaches a snapshot or the UI.
public struct DeploymentLogEntry: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var level: DeploymentLogLevel
  public var source: String
  public var message: String
  public var filePath: String?
  public var line: Int?
  public var column: Int?
  public var stepName: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case level
    case source
    case message
    case filePath
    case line
    case column
    case stepName
  }

  public init(
    id: UUID = UUID(),
    level: DeploymentLogLevel,
    source: String,
    message: String,
    filePath: String? = nil,
    line: Int? = nil,
    column: Int? = nil,
    stepName: String? = nil
  ) {
    self.id = id
    self.level = level
    self.source = DeploymentLogExcerptPolicy.boundedSource(source)
    self.message = DeploymentLogExcerptPolicy.redactedAndBoundedMessage(message)
    self.filePath = filePath.map(DeploymentLogExcerptPolicy.boundedPath)
    self.line = line.map { max(0, $0) }
    self.column = column.map { max(0, $0) }
    self.stepName = stepName.map(DeploymentLogExcerptPolicy.boundedSource)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      level: try container.decode(DeploymentLogLevel.self, forKey: .level),
      source: try container.decode(String.self, forKey: .source),
      message: try container.decode(String.self, forKey: .message),
      filePath: try container.decodeIfPresent(String.self, forKey: .filePath),
      line: try container.decodeIfPresent(Int.self, forKey: .line),
      column: try container.decodeIfPresent(Int.self, forKey: .column),
      stepName: try container.decodeIfPresent(String.self, forKey: .stepName)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(level, forKey: .level)
    try container.encode(source, forKey: .source)
    try container.encode(message, forKey: .message)
    try container.encodeIfPresent(filePath, forKey: .filePath)
    try container.encodeIfPresent(line, forKey: .line)
    try container.encodeIfPresent(column, forKey: .column)
    try container.encodeIfPresent(stepName, forKey: .stepName)
  }

  public var locationText: String? {
    guard let filePath = filePath?.nilIfEmpty else {
      return nil
    }
    var suffix = ""
    if let line {
      suffix = ":\(line)"
      if let column {
        suffix += ":\(column)"
      }
    }
    return filePath + suffix
  }
}

public struct DeploymentStatusSignal: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var level: DeploymentStatusLevel
  public var title: String
  public var message: String
  public var urlText: String?
  public var logExcerpt: [DeploymentLogEntry]
  public var expectedBranch: String?
  public var expectedCommitSHA: String?
  public var observedBranch: String?
  public var observedCommitSHA: String?
  public var attributionVerified: Bool?

  private enum CodingKeys: String, CodingKey {
    case id
    case level
    case title
    case message
    case urlText
    case logExcerpt
    case expectedBranch
    case expectedCommitSHA
    case observedBranch
    case observedCommitSHA
    case attributionVerified
  }

  public init(
    id: UUID = UUID(),
    level: DeploymentStatusLevel,
    title: String,
    message: String,
    urlText: String? = nil,
    logExcerpt: [DeploymentLogEntry] = [],
    expectedBranch: String? = nil,
    expectedCommitSHA: String? = nil,
    observedBranch: String? = nil,
    observedCommitSHA: String? = nil,
    attributionVerified: Bool? = nil
  ) {
    self.id = id
    self.level = level
    self.title = title
    self.message = DeploymentLogExcerptPolicy.redactedAndBoundedMessage(message)
    self.urlText = urlText
    self.logExcerpt = DeploymentLogExcerptPolicy.boundedEntries(logExcerpt)
    self.expectedBranch = expectedBranch
    self.expectedCommitSHA = expectedCommitSHA
    self.observedBranch = observedBranch
    self.observedCommitSHA = observedCommitSHA
    self.attributionVerified = attributionVerified
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    level = try container.decode(DeploymentStatusLevel.self, forKey: .level)
    title = try container.decode(String.self, forKey: .title)
    message = DeploymentLogExcerptPolicy.redactedAndBoundedMessage(
      try container.decode(String.self, forKey: .message)
    )
    urlText = try container.decodeIfPresent(String.self, forKey: .urlText)
    logExcerpt = DeploymentLogExcerptPolicy.boundedEntries(
      try container.decodeIfPresent([DeploymentLogEntry].self, forKey: .logExcerpt) ?? []
    )
    expectedBranch = try container.decodeIfPresent(String.self, forKey: .expectedBranch)
    expectedCommitSHA = try container.decodeIfPresent(String.self, forKey: .expectedCommitSHA)
    observedBranch = try container.decodeIfPresent(String.self, forKey: .observedBranch)
    observedCommitSHA = try container.decodeIfPresent(String.self, forKey: .observedCommitSHA)
    attributionVerified = try container.decodeIfPresent(Bool.self, forKey: .attributionVerified)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(level, forKey: .level)
    try container.encode(title, forKey: .title)
    try container.encode(message, forKey: .message)
    try container.encodeIfPresent(urlText, forKey: .urlText)
    try container.encode(logExcerpt, forKey: .logExcerpt)
    try container.encodeIfPresent(expectedBranch, forKey: .expectedBranch)
    try container.encodeIfPresent(expectedCommitSHA, forKey: .expectedCommitSHA)
    try container.encodeIfPresent(observedBranch, forKey: .observedBranch)
    try container.encodeIfPresent(observedCommitSHA, forKey: .observedCommitSHA)
    try container.encodeIfPresent(attributionVerified, forKey: .attributionVerified)
  }
}

public struct DeploymentStatusSnapshot: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var profileID: UUID
  public var releaseRecordID: UUID?
  public var provider: DeploymentProvider
  public var level: DeploymentStatusLevel
  public var title: String
  public var message: String
  public var siteURLText: String?
  public var checkedAt: Date
  public var signals: [DeploymentStatusSignal]
  public var expectedBranch: String?
  public var expectedCommitSHA: String?
  public var observedBranch: String?
  public var observedCommitSHA: String?
  public var attributionVerified: Bool?

  public init(
    id: UUID = UUID(),
    profileID: UUID,
    releaseRecordID: UUID?,
    provider: DeploymentProvider,
    level: DeploymentStatusLevel,
    title: String,
    message: String,
    siteURLText: String?,
    checkedAt: Date = Date(),
    signals: [DeploymentStatusSignal],
    expectedBranch: String? = nil,
    expectedCommitSHA: String? = nil,
    observedBranch: String? = nil,
    observedCommitSHA: String? = nil,
    attributionVerified: Bool? = nil
  ) {
    self.id = id
    self.profileID = profileID
    self.releaseRecordID = releaseRecordID
    self.provider = provider
    self.level = level
    self.title = title
    self.message = message
    self.siteURLText = siteURLText
    self.checkedAt = checkedAt
    self.signals = signals
    self.expectedBranch = expectedBranch
    self.expectedCommitSHA = expectedCommitSHA
    self.observedBranch = observedBranch
    self.observedCommitSHA = observedCommitSHA
    self.attributionVerified = attributionVerified
  }
}

public struct DeploymentPostPublishCheckItem: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var level: DeploymentStatusLevel
  public var title: String
  public var message: String
  public var urlText: String?

  public init(
    id: String,
    level: DeploymentStatusLevel,
    title: String,
    message: String,
    urlText: String? = nil
  ) {
    self.id = id
    self.level = level
    self.title = title
    self.message = message
    self.urlText = urlText
  }

  public var checklistMarker: String {
    switch level {
    case .success:
      return "x"
    case .running, .failed, .unknown:
      return " "
    }
  }
}

public struct DeploymentStatusProviderReadiness: Codable, Hashable, Sendable {
  public var provider: DeploymentProvider
  public var isAPIReady: Bool
  public var canCheckAnyStatus: Bool
  public var configuredSignals: [String]
  public var missingRequirements: [String]
  /// Non-blocking production-evidence gaps. These are separate from API
  /// requirements so local saves and Git publication remain usable.
  public var productionVerificationIssues: [String]
  public var needsExplicitProviderConfirmation: Bool
  public var fallbackMessage: String
  public var nextStep: String

  private enum CodingKeys: String, CodingKey {
    case provider
    case isAPIReady
    case canCheckAnyStatus
    case configuredSignals
    case missingRequirements
    case productionVerificationIssues
    case needsExplicitProviderConfirmation
    case fallbackMessage
    case nextStep
  }

  public init(
    provider: DeploymentProvider,
    isAPIReady: Bool,
    canCheckAnyStatus: Bool,
    configuredSignals: [String],
    missingRequirements: [String],
    productionVerificationIssues: [String] = [],
    needsExplicitProviderConfirmation: Bool = false,
    fallbackMessage: String,
    nextStep: String
  ) {
    self.provider = provider
    self.isAPIReady = isAPIReady
    self.canCheckAnyStatus = canCheckAnyStatus
    self.configuredSignals = configuredSignals
    self.missingRequirements = missingRequirements
    self.productionVerificationIssues = productionVerificationIssues
    self.needsExplicitProviderConfirmation = needsExplicitProviderConfirmation
    self.fallbackMessage = fallbackMessage
    self.nextStep = nextStep
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(DeploymentProvider.self, forKey: .provider)
    isAPIReady = try container.decode(Bool.self, forKey: .isAPIReady)
    canCheckAnyStatus = try container.decode(Bool.self, forKey: .canCheckAnyStatus)
    configuredSignals = try container.decode([String].self, forKey: .configuredSignals)
    missingRequirements = try container.decode([String].self, forKey: .missingRequirements)
    productionVerificationIssues =
      try container.decodeIfPresent(
        [String].self,
        forKey: .productionVerificationIssues
      ) ?? []
    needsExplicitProviderConfirmation =
      try container.decodeIfPresent(
        Bool.self,
        forKey: .needsExplicitProviderConfirmation
      ) ?? false
    fallbackMessage = try container.decode(String.self, forKey: .fallbackMessage)
    nextStep = try container.decode(String.self, forKey: .nextStep)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(provider, forKey: .provider)
    try container.encode(isAPIReady, forKey: .isAPIReady)
    try container.encode(canCheckAnyStatus, forKey: .canCheckAnyStatus)
    try container.encode(configuredSignals, forKey: .configuredSignals)
    try container.encode(missingRequirements, forKey: .missingRequirements)
    try container.encode(productionVerificationIssues, forKey: .productionVerificationIssues)
    try container.encode(
      needsExplicitProviderConfirmation,
      forKey: .needsExplicitProviderConfirmation
    )
    try container.encode(fallbackMessage, forKey: .fallbackMessage)
    try container.encode(nextStep, forKey: .nextStep)
  }

  public var statusTitle: String {
    if isAPIReady {
      return CoreL10n.format("%@ API 已就绪", provider.displayName)
    }
    if canCheckAnyStatus {
      return CoreL10n.format("%@ 可做降级校验", provider.displayName)
    }
    return CoreL10n.format("%@ 未配置", provider.displayName)
  }

  public var checklistMarkdown: String {
    let apiStatus = CoreL10n.text(isAPIReady ? "已就绪" : "未就绪")
    let canCheckStatus = CoreL10n.text(canCheckAnyStatus ? "是" : "否")
    var lines = [
      CoreL10n.text("# 部署状态配置检查"),
      "",
      CoreL10n.format("- 平台：%@", provider.displayName),
      CoreL10n.format("- API 状态：%@", apiStatus),
      CoreL10n.format("- 可检查状态：%@", canCheckStatus),
      CoreL10n.format("- 下一步：%@", nextStep),
    ]

    if !configuredSignals.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("## 已配置"))
      lines.append(contentsOf: configuredSignals.map { CoreL10n.format("- [x] %@", $0) })
    }

    if !missingRequirements.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("## 待补齐"))
      lines.append(contentsOf: missingRequirements.map { CoreL10n.format("- [ ] %@", $0) })
    }

    lines.append("")
    lines.append(CoreL10n.text("## 降级检查"))
    lines.append(fallbackMessage)
    return lines.joined(separator: "\n")
  }
}

extension DeploymentStatusSnapshot {
  public var nextActionTitle: String {
    switch level {
    case .success:
      return CoreL10n.text("保持监控")
    case .running:
      return CoreL10n.text("继续轮询")
    case .failed:
      return CoreL10n.text("处理失败后重试")
    case .unknown:
      return CoreL10n.text("补充状态证据")
    }
  }

  public var nextActionMessage: String {
    switch level {
    case .success:
      return CoreL10n.text("部署状态正常；保留记录即可，下一次发布后会继续检查。")
    case .running:
      return CoreL10n.text("部署仍在运行；稍后手动检查，或开启部署轮询等待完成。")
    case .failed:
      return CoreL10n.text("打开失败的 Actions、Pipeline 或状态端点，修复后重新检查部署。")
    case .unknown:
      return CoreL10n.text("检查仓库 Token、站点 URL 或状态端点配置，补齐后重新校验。")
    }
  }

  public var diagnosticSignals: [DeploymentStatusSignal] {
    signals.filter { $0.level == .failed || $0.level == .running || $0.level == .unknown }
  }

  public var clipboardSummary: String {
    let formatter = ISO8601DateFormatter()
    var lines = [
      title,
      CoreL10n.format("状态：%@", level.displayName),
      CoreL10n.format("Provider：%@", provider.displayName),
      CoreL10n.format("检查时间：%@", formatter.string(from: checkedAt)),
      CoreL10n.format("结论：%@", message),
      CoreL10n.format("下一步：%@ - %@", nextActionTitle, nextActionMessage),
    ]
    if let siteURLText {
      lines.append(CoreL10n.format("站点：%@", siteURLText))
    }
    if !signals.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("信号："))
      for signal in signals {
        lines.append(
          CoreL10n.format("- [%@] %@：%@", signal.level.displayName, signal.title, signal.message)
        )
        if let urlText = signal.urlText?.nilIfEmpty {
          lines.append("  \(urlText)")
        }
        if !signal.logExcerpt.isEmpty {
          lines.append(CoreL10n.text("  日志摘录："))
          for entry in signal.logExcerpt {
            let location = entry.locationText.map { " [\($0)]" } ?? ""
            lines.append(
              "  - [\(entry.level.displayName)] \(entry.source)\(location)：\(entry.message)"
            )
          }
        }
      }
    }
    return lines.joined(separator: "\n")
  }

  public var postPublishCheckItems: [DeploymentPostPublishCheckItem] {
    var items: [DeploymentPostPublishCheckItem] = []
    if let siteURLText = siteURLText?.nilIfEmpty {
      items.append(
        DeploymentPostPublishCheckItem(
          id: "site-url",
          level: .success,
          title: CoreL10n.text("站点入口"),
          message: CoreL10n.text("已记录发布后的站点 URL。"),
          urlText: siteURLText
        )
      )
    } else {
      items.append(
        DeploymentPostPublishCheckItem(
          id: "site-url",
          level: .unknown,
          title: CoreL10n.text("站点入口"),
          message: CoreL10n.text("还没有站点 URL，无法确认发布后的公开入口。")
        )
      )
    }

    if signals.isEmpty {
      items.append(
        DeploymentPostPublishCheckItem(
          id: "signals",
          level: .unknown,
          title: CoreL10n.text("部署信号"),
          message: CoreL10n.text("还没有 API、状态端点或页面校验结果。")
        )
      )
    } else {
      for signal in signals {
        items.append(
          DeploymentPostPublishCheckItem(
            id: "signal-\(signal.id.uuidString)",
            level: signal.level,
            title: signal.title,
            message: signal.message,
            urlText: signal.urlText
          )
        )
      }
    }

    if releaseRecordID != nil
      && !signals.contains(where: {
        $0.title == CoreL10n.text("发布页面内容") || $0.title == "发布页面内容"
      })
    {
      items.append(
        DeploymentPostPublishCheckItem(
          id: "article-page",
          level: .unknown,
          title: CoreL10n.text("文章页面校验"),
          message: CoreL10n.text("这条发布记录还没有完成文章页面内容校验；需要站点 URL 和文章路径。")
        )
      )
    }

    items.append(
      DeploymentPostPublishCheckItem(
        id: "next-action",
        level: level,
        title: nextActionTitle,
        message: nextActionMessage
      )
    )
    return items
  }

  public var postPublishChecklistMarkdown: String {
    let formatter = ISO8601DateFormatter()
    var lines = [
      CoreL10n.text("# 发布后校验报告"),
      "",
      CoreL10n.format("- 平台：%@", provider.displayName),
      CoreL10n.format("- 状态：%@", level.displayName),
      CoreL10n.format("- 标题：%@", title),
      CoreL10n.format("- 检查时间：%@", formatter.string(from: checkedAt)),
      CoreL10n.format("- 结论：%@", message),
    ]
    if let siteURLText = siteURLText?.nilIfEmpty {
      lines.append(CoreL10n.format("- 站点：%@", siteURLText))
    }

    lines.append("")
    lines.append(CoreL10n.text("## 校验清单"))
    for item in postPublishCheckItems {
      lines.append(CoreL10n.format("- [%@] %@：%@", item.checklistMarker, item.title, item.message))
      if let urlText = item.urlText?.nilIfEmpty {
        lines.append("  - \(urlText)")
      }
    }

    if !diagnosticSignals.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("## 需处理信号"))
      for signal in diagnosticSignals {
        lines.append(
          CoreL10n.format("- [%@] %@：%@", signal.level.displayName, signal.title, signal.message)
        )
        if let urlText = signal.urlText?.nilIfEmpty {
          lines.append("  - \(urlText)")
        }
      }
    }
    return lines.joined(separator: "\n")
  }
}
public enum DeploymentStatusError: LocalizedError, Equatable {
  case invalidResponse
  case invalidURL(String)
  case insecureCredentialURL
  case httpStatus(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return CoreL10n.text("部署状态响应无效。")
    case .invalidURL(let url):
      return CoreL10n.format("部署状态 URL 无效：%@", url)
    case .insecureCredentialURL:
      return CoreL10n.text("部署 API URL 必须使用 HTTPS；已阻止向不安全端点发送 Token。")
    case .httpStatus(let statusCode):
      return CoreL10n.format("部署状态 API 返回 HTTP %@。", String(statusCode))
    }
  }
}

struct GitHubPagesStatusResponse: Decodable {
  var status: String?
  var htmlURL: String?

  private enum CodingKeys: String, CodingKey {
    case status
    case htmlURL = "html_url"
  }
}

struct GitHubActionsRunsResponse: Decodable {
  var workflowRuns: [GitHubActionRunStatusResponse]

  private enum CodingKeys: String, CodingKey {
    case workflowRuns = "workflow_runs"
  }
}

struct GitHubActionRunStatusResponse: Decodable {
  var id: Int64?
  var name: String?
  var status: String?
  var conclusion: String?
  var htmlURL: String?
  var headBranch: String?
  var headSHA: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case status
    case conclusion
    case htmlURL = "html_url"
    case headBranch = "head_branch"
    case headSHA = "head_sha"
  }
}

struct GitHubActionsJobsResponse: Decodable {
  var jobs: [GitHubActionJobStatusResponse]

  private enum CodingKeys: String, CodingKey {
    case jobs
  }
}

struct GitHubActionJobStatusResponse: Decodable {
  var id: Int64?
  var name: String?
  var status: String?
  var conclusion: String?
  var htmlURL: String?
  var checkRunURL: String?
  var steps: [GitHubActionStepStatusResponse]?

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case status
    case conclusion
    case htmlURL = "html_url"
    case checkRunURL = "check_run_url"
    case steps
  }
}

struct GitHubActionStepStatusResponse: Decodable {
  var number: Int?
  var name: String?
  var status: String?
  var conclusion: String?
}

struct GitHubCheckRunAnnotationResponse: Decodable {
  var path: String?
  var startLine: Int?
  var endLine: Int?
  var startColumn: Int?
  var endColumn: Int?
  var annotationLevel: String?
  var message: String?
  var title: String?
  var rawDetails: String?

  private enum CodingKeys: String, CodingKey {
    case path
    case startLine = "start_line"
    case endLine = "end_line"
    case startColumn = "start_column"
    case endColumn = "end_column"
    case annotationLevel = "annotation_level"
    case message
    case title
    case rawDetails = "raw_details"
  }
}

struct GitLabPipelineStatusResponse: Decodable {
  var status: String?
  var webURL: String?
  var ref: String?
  var sha: String?

  private enum CodingKeys: String, CodingKey {
    case status
    case webURL = "web_url"
    case ref
    case sha
  }
}

struct NetlifyDeployStatusResponse: Decodable {
  var id: String?
  var name: String?
  var title: String?
  var state: String?
  var branch: String?
  var commitRef: String?
  var deployURL: String?
  var adminURL: String?
  var url: String?
  var errorMessage: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case title
    case state
    case branch
    case commitRef = "commit_ref"
    case deployURL = "deploy_url"
    case adminURL = "admin_url"
    case url
    case errorMessage = "error_message"
  }
}

struct VercelDeploymentsResponse: Decodable {
  var deployments: [VercelDeploymentStatusResponse]
}

struct VercelDeploymentStatusResponse: Decodable {
  var id: String?
  var uid: String?
  var name: String?
  var url: String?
  var state: String?
  var readyState: String?
  var target: String?
  var inspectorURL: String?
  var errorMessage: String?
  var meta: VercelDeploymentMeta?

  private enum CodingKeys: String, CodingKey {
    case id
    case uid
    case name
    case url
    case state
    case readyState
    case target
    case inspectorURL = "inspectorUrl"
    case errorMessage
    case meta
  }

  var deploymentIdentifier: String? {
    uid?.nilIfEmpty ?? id?.nilIfEmpty ?? url?.nilIfEmpty
  }
}

struct VercelDeploymentMeta: Decodable {
  var branch: String?
  var commitSHA: String?

  private enum CodingKeys: String, CodingKey {
    case branch = "githubCommitRef"
    case commitSHA = "githubCommitSha"
  }
}

struct CloudflarePagesDeploymentsResponse: Decodable {
  var result: [CloudflarePagesDeploymentStatusResponse]
}

struct CloudflarePagesDeploymentStatusResponse: Decodable {
  var id: String?
  var url: String?
  var aliases: [String]
  var latestStage: CloudflarePagesDeploymentStage?
  var deploymentTrigger: CloudflarePagesDeploymentTrigger?

  private enum CodingKeys: String, CodingKey {
    case id
    case url
    case aliases
    case latestStage = "latest_stage"
    case deploymentTrigger = "deployment_trigger"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id)
    url = try container.decodeIfPresent(String.self, forKey: .url)
    aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    latestStage = try container.decodeIfPresent(
      CloudflarePagesDeploymentStage.self, forKey: .latestStage)
    deploymentTrigger = try container.decodeIfPresent(
      CloudflarePagesDeploymentTrigger.self, forKey: .deploymentTrigger)
  }
}

struct CloudflarePagesDeploymentStage: Decodable {
  var name: String?
  var status: String?
}

struct CloudflarePagesDeploymentTrigger: Decodable {
  var metadata: CloudflarePagesDeploymentTriggerMetadata?
}

struct CloudflarePagesDeploymentTriggerMetadata: Decodable {
  var branch: String?
  var commitHash: String?
  var commitMessage: String?

  private enum CodingKeys: String, CodingKey {
    case branch
    case commitHash = "commit_hash"
    case commitMessage = "commit_message"
  }
}

struct EndpointStatusPayload {
  var rawStatus: String
  var level: DeploymentStatusLevel
  var title: String?
  var message: String?
  var urlText: String?
  var branch: String?
  var commitSHA: String?
}
