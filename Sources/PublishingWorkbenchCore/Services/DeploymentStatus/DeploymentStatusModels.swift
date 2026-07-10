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
      return "自定义端点"
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
        detail: "读取 Pages 状态、Actions runs，并可继续校验站点 URL 或自定义状态端点。"
      )
    case .gitlabPages:
      return DeploymentProviderIntegrationDepth(
        title: "GitLab Pipeline API",
        detail: "读取项目 Pipeline，并可继续校验 GitLab Pages URL 或自定义状态端点。"
      )
    case .netlify:
      return DeploymentProviderIntegrationDepth(
        title: "Netlify Deploy API",
        detail: "配置 Site ID 和 Token 后调用 Netlify Deploy API；否则降级为站点 URL/状态端点检查。"
      )
    case .vercel:
      return DeploymentProviderIntegrationDepth(
        title: "Vercel Deployments API",
        detail: "配置 Project ID 和 Token 后调用 Vercel Deployments API，并按分支/commit 关联当前发布。"
      )
    case .cloudflarePages:
      return DeploymentProviderIntegrationDepth(
        title: "Cloudflare Pages API",
        detail: "配置 Account ID、Pages Project 和 Token 后调用 Cloudflare Pages Deployments API。"
      )
    case .custom:
      return DeploymentProviderIntegrationDepth(
        title: "自定义状态端点",
        detail: "读取自定义 JSON/HTTP 状态端点，或使用站点 URL 做可达性与发布后页面校验。"
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
      return "正常"
    case .running:
      return "部署中"
    case .failed:
      return "失败"
    case .unknown:
      return "未知"
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

public struct DeploymentStatusSignal: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var level: DeploymentStatusLevel
  public var title: String
  public var message: String
  public var urlText: String?

  public init(
    id: UUID = UUID(),
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
    signals: [DeploymentStatusSignal]
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
  public var fallbackMessage: String
  public var nextStep: String

  public init(
    provider: DeploymentProvider,
    isAPIReady: Bool,
    canCheckAnyStatus: Bool,
    configuredSignals: [String],
    missingRequirements: [String],
    fallbackMessage: String,
    nextStep: String
  ) {
    self.provider = provider
    self.isAPIReady = isAPIReady
    self.canCheckAnyStatus = canCheckAnyStatus
    self.configuredSignals = configuredSignals
    self.missingRequirements = missingRequirements
    self.fallbackMessage = fallbackMessage
    self.nextStep = nextStep
  }

  public var statusTitle: String {
    if isAPIReady {
      return "\(provider.displayName) API 已就绪"
    }
    if canCheckAnyStatus {
      return "\(provider.displayName) 可做降级校验"
    }
    return "\(provider.displayName) 未配置"
  }

  public var checklistMarkdown: String {
    var lines = [
      "# 部署状态配置检查",
      "",
      "- 平台：\(provider.displayName)",
      "- API 状态：\(isAPIReady ? "已就绪" : "未就绪")",
      "- 可检查状态：\(canCheckAnyStatus ? "是" : "否")",
      "- 下一步：\(nextStep)"
    ]

    if !configuredSignals.isEmpty {
      lines.append("")
      lines.append("## 已配置")
      lines.append(contentsOf: configuredSignals.map { "- [x] \($0)" })
    }

    if !missingRequirements.isEmpty {
      lines.append("")
      lines.append("## 待补齐")
      lines.append(contentsOf: missingRequirements.map { "- [ ] \($0)" })
    }

    lines.append("")
    lines.append("## 降级检查")
    lines.append(fallbackMessage)
    return lines.joined(separator: "\n")
  }
}

public extension DeploymentStatusSnapshot {
  var nextActionTitle: String {
    switch level {
    case .success:
      return "保持监控"
    case .running:
      return "继续轮询"
    case .failed:
      return "处理失败后重试"
    case .unknown:
      return "补充状态证据"
    }
  }

  var nextActionMessage: String {
    switch level {
    case .success:
      return "部署状态正常；保留记录即可，下一次发布后会继续检查。"
    case .running:
      return "部署仍在运行；稍后手动检查，或开启部署轮询等待完成。"
    case .failed:
      return "打开失败的 Actions、Pipeline 或状态端点，修复后重新检查部署。"
    case .unknown:
      return "检查仓库 Token、站点 URL 或状态端点配置，补齐后重新校验。"
    }
  }

  var diagnosticSignals: [DeploymentStatusSignal] {
    signals.filter { $0.level == .failed || $0.level == .running || $0.level == .unknown }
  }

  var clipboardSummary: String {
    let formatter = ISO8601DateFormatter()
    var lines = [
      title,
      "状态：\(level.displayName)",
      "Provider：\(provider.displayName)",
      "检查时间：\(formatter.string(from: checkedAt))",
      "结论：\(message)",
      "下一步：\(nextActionTitle) - \(nextActionMessage)"
    ]
    if let siteURLText {
      lines.append("站点：\(siteURLText)")
    }
    if !signals.isEmpty {
      lines.append("")
      lines.append("信号：")
      for signal in signals {
        lines.append("- [\(signal.level.displayName)] \(signal.title)：\(signal.message)")
        if let urlText = signal.urlText?.nilIfEmpty {
          lines.append("  \(urlText)")
        }
      }
    }
    return lines.joined(separator: "\n")
  }

  var postPublishCheckItems: [DeploymentPostPublishCheckItem] {
    var items: [DeploymentPostPublishCheckItem] = []
    if let siteURLText = siteURLText?.nilIfEmpty {
      items.append(
        DeploymentPostPublishCheckItem(
          id: "site-url",
          level: .success,
          title: "站点入口",
          message: "已记录发布后的站点 URL。",
          urlText: siteURLText
        )
      )
    } else {
      items.append(
        DeploymentPostPublishCheckItem(
          id: "site-url",
          level: .unknown,
          title: "站点入口",
          message: "还没有站点 URL，无法确认发布后的公开入口。"
        )
      )
    }

    if signals.isEmpty {
      items.append(
        DeploymentPostPublishCheckItem(
          id: "signals",
          level: .unknown,
          title: "部署信号",
          message: "还没有 API、状态端点或页面校验结果。"
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

    if releaseRecordID != nil && !signals.contains(where: { $0.title == "发布页面内容" }) {
      items.append(
        DeploymentPostPublishCheckItem(
          id: "article-page",
          level: .unknown,
          title: "文章页面校验",
          message: "这条发布记录还没有完成文章页面内容校验；需要站点 URL 和文章路径。"
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

  var postPublishChecklistMarkdown: String {
    let formatter = ISO8601DateFormatter()
    var lines = [
      "# 发布后校验报告",
      "",
      "- 平台：\(provider.displayName)",
      "- 状态：\(level.displayName)",
      "- 标题：\(title)",
      "- 检查时间：\(formatter.string(from: checkedAt))",
      "- 结论：\(message)"
    ]
    if let siteURLText = siteURLText?.nilIfEmpty {
      lines.append("- 站点：\(siteURLText)")
    }

    lines.append("")
    lines.append("## 校验清单")
    for item in postPublishCheckItems {
      lines.append("- [\(item.checklistMarker)] \(item.title)：\(item.message)")
      if let urlText = item.urlText?.nilIfEmpty {
        lines.append("  - \(urlText)")
      }
    }

    if !diagnosticSignals.isEmpty {
      lines.append("")
      lines.append("## 需处理信号")
      for signal in diagnosticSignals {
        lines.append("- [\(signal.level.displayName)] \(signal.title)：\(signal.message)")
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
  case httpStatus(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "部署状态响应无效。"
    case .invalidURL(let url):
      return "部署状态 URL 无效：\(url)"
    case .httpStatus(let statusCode):
      return "部署状态 API 返回 HTTP \(statusCode)。"
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
  var name: String?
  var status: String?
  var conclusion: String?
  var htmlURL: String?

  private enum CodingKeys: String, CodingKey {
    case name
    case status
    case conclusion
    case htmlURL = "html_url"
  }
}

struct GitLabPipelineStatusResponse: Decodable {
  var status: String?
  var webURL: String?

  private enum CodingKeys: String, CodingKey {
    case status
    case webURL = "web_url"
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
    latestStage = try container.decodeIfPresent(CloudflarePagesDeploymentStage.self, forKey: .latestStage)
    deploymentTrigger = try container.decodeIfPresent(CloudflarePagesDeploymentTrigger.self, forKey: .deploymentTrigger)
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
}
