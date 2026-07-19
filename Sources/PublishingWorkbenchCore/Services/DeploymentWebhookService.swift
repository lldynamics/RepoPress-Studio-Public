import Foundation

public struct DeploymentWebhookReceiveResult: Codable, Hashable, Sendable {
  public var snapshot: DeploymentStatusSnapshot
  public var matchedReleaseRecordID: UUID?
  public var sourceEvent: String

  public init(
    snapshot: DeploymentStatusSnapshot,
    matchedReleaseRecordID: UUID?,
    sourceEvent: String
  ) {
    self.snapshot = snapshot
    self.matchedReleaseRecordID = matchedReleaseRecordID
    self.sourceEvent = sourceEvent
  }
}

public enum DeploymentWebhookError: LocalizedError, Equatable {
  case emptyPayload
  case invalidJSON

  public var errorDescription: String? {
    switch self {
    case .emptyPayload:
      return CoreL10n.text("Webhook payload 为空。")
    case .invalidJSON:
      return CoreL10n.text("Webhook payload 不是有效 JSON。")
    }
  }
}

public struct DeploymentWebhookService {
  public init() {}

  public func receive(
    provider: DeploymentProvider,
    payloadText: String,
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?,
    receivedAt: Date = Date()
  ) throws -> DeploymentWebhookReceiveResult {
    let trimmed = payloadText.trimmedForPublishing
    guard !trimmed.isEmpty else {
      throw DeploymentWebhookError.emptyPayload
    }
    guard let data = trimmed.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data),
          let object = json as? [String: Any] else {
      throw DeploymentWebhookError.invalidJSON
    }

    let event = sourceEvent(in: object, provider: provider)
    let parsed = parsedWebhook(object: object, provider: provider)
    let title = parsed.title.nilIfEmpty ?? CoreL10n.format("%@ Webhook", provider.displayName)
    let message = parsed.message.nilIfEmpty ?? CoreL10n.format("收到 %@ 部署通知。", provider.displayName)
    let signal = DeploymentStatusSignal(
      level: parsed.level,
      title: title,
      message: message,
      urlText: parsed.urlText
    )
    let snapshot = DeploymentStatusSnapshot(
      profileID: profile.id,
      releaseRecordID: releaseRecord?.id,
      provider: provider,
      level: parsed.level,
      title: title,
      message: message,
      siteURLText: parsed.urlText ?? profile.deploymentSiteURL,
      checkedAt: receivedAt,
      signals: [signal]
    )

    return DeploymentWebhookReceiveResult(
      snapshot: snapshot,
      matchedReleaseRecordID: releaseRecord?.id,
      sourceEvent: event
    )
  }

  private func sourceEvent(in object: [String: Any], provider: DeploymentProvider) -> String {
    stringValue(for: ["event", "type", "action", "object_kind"], in: object)
      ?? "\(provider.rawValue).webhook"
  }

  private func parsedWebhook(
    object: [String: Any],
    provider: DeploymentProvider
  ) -> (level: DeploymentStatusLevel, title: String, message: String, urlText: String?) {
    switch provider {
    case .githubPages:
      return githubWebhook(object)
    case .gitlabPages:
      return gitLabWebhook(object)
    case .netlify:
      return netlifyWebhook(object)
    case .vercel:
      return vercelWebhook(object)
    case .cloudflarePages:
      return cloudflareWebhook(object)
    case .custom:
      return genericWebhook(object, provider: provider)
    }
  }

  private func githubWebhook(_ object: [String: Any]) -> (DeploymentStatusLevel, String, String, String?) {
    if let run = dictionaryValue(for: ["workflow_run"], in: object) {
      let status = stringValue(for: ["conclusion", "status"], in: run)
      return (
        level(from: status),
        stringValue(for: ["name"], in: run) ?? "GitHub Actions",
        joinedMessage([
          status.map(statusLabel),
          stringValue(for: ["head_branch"], in: run).map(branchLabel),
          stringValue(for: ["head_sha"], in: run).map(commitLabel),
        ]),
        stringValue(for: ["html_url"], in: run)
      )
    }

    if let deployment = dictionaryValue(for: ["deployment_status"], in: object) {
      let status = stringValue(for: ["state"], in: deployment)
      return (
        level(from: status),
        "GitHub Deployment",
        joinedMessage([
          status.map(statusLabel),
          stringValue(for: ["description"], in: deployment),
        ]),
        stringValue(for: ["target_url", "environment_url"], in: deployment)
      )
    }

    return genericWebhook(object, provider: .githubPages)
  }

  private func gitLabWebhook(_ object: [String: Any]) -> (DeploymentStatusLevel, String, String, String?) {
    let attributes = dictionaryValue(for: ["object_attributes"], in: object) ?? object
    let status = stringValue(for: ["status", "state"], in: attributes)
    return (
      level(from: status),
      stringValue(for: ["name", "stage"], in: attributes) ?? "GitLab Pipeline",
      joinedMessage([
        status.map(statusLabel),
        stringValue(for: ["ref"], in: attributes).map(branchLabel),
        stringValue(for: ["sha", "commit_sha"], in: attributes).map(commitLabel),
      ]),
      stringValue(for: ["url", "web_url"], in: attributes)
        ?? dictionaryValue(for: ["project"], in: object).flatMap { stringValue(for: ["web_url"], in: $0) }
    )
  }

  private func netlifyWebhook(_ object: [String: Any]) -> (DeploymentStatusLevel, String, String, String?) {
    let deploy = dictionaryValue(for: ["deploy"], in: object) ?? object
    let status = stringValue(for: ["state", "status"], in: deploy)
    return (
      level(from: status),
      stringValue(for: ["name", "site_name"], in: deploy) ?? "Netlify Deploy",
      joinedMessage([
        status.map(statusLabel),
        stringValue(for: ["branch"], in: deploy).map(branchLabel),
        stringValue(for: ["commit_ref", "commit_sha", "sha"], in: deploy).map(commitLabel),
        stringValue(for: ["error_message"], in: deploy),
      ]),
      stringValue(for: ["admin_url", "deploy_url", "url", "ssl_url"], in: deploy)
    )
  }

  private func vercelWebhook(_ object: [String: Any]) -> (DeploymentStatusLevel, String, String, String?) {
    let deployment = dictionaryValue(for: ["deployment"], in: object)
      ?? dictionaryValue(for: ["payload"], in: object)
      ?? object
    let meta = dictionaryValue(for: ["meta"], in: deployment) ?? [:]
    let status = stringValue(for: ["readyState", "state", "status"], in: deployment)
    return (
      level(from: status),
      stringValue(for: ["name"], in: deployment) ?? "Vercel Deployment",
      joinedMessage([
        status.map(statusLabel),
        stringValue(for: ["target"], in: deployment).map(targetLabel),
        stringValue(for: ["githubCommitRef", "branch"], in: meta).map(branchLabel),
        stringValue(for: ["githubCommitSha", "commit"], in: meta).map(commitLabel),
      ]),
      stringValue(for: ["inspectorUrl", "url"], in: deployment)
    )
  }

  private func cloudflareWebhook(_ object: [String: Any]) -> (DeploymentStatusLevel, String, String, String?) {
    let deployment = dictionaryValue(for: ["deployment"], in: object)
      ?? dictionaryValue(for: ["data"], in: object)
      ?? object
    let stage = dictionaryValue(for: ["latest_stage"], in: deployment) ?? deployment
    let trigger = dictionaryValue(for: ["deployment_trigger"], in: deployment)
      .flatMap { dictionaryValue(for: ["metadata"], in: $0) } ?? [:]
    let status = stringValue(for: ["status", "state"], in: stage)
    return (
      level(from: status),
      stringValue(for: ["name"], in: stage) ?? "Cloudflare Pages",
      joinedMessage([
        status.map(statusLabel),
        stringValue(for: ["branch"], in: trigger).map(branchLabel),
        stringValue(for: ["commit_hash"], in: trigger).map(commitLabel),
        stringValue(for: ["commit_message"], in: trigger),
      ]),
      stringValue(for: ["url"], in: deployment)
        ?? arrayValue(for: ["aliases"], in: deployment)?.compactMap { $0 as? String }.first
    )
  }

  private func genericWebhook(
    _ object: [String: Any],
    provider: DeploymentProvider
  ) -> (DeploymentStatusLevel, String, String, String?) {
    let status = stringValue(for: ["status", "state", "conclusion", "level", "result"], in: object)
    let message = stringValue(for: ["message", "summary", "description"], in: object)
    return (
      level(from: status),
      stringValue(for: ["title", "name", "deployment", "service"], in: object)
        ?? CoreL10n.format("%@ Webhook", provider.displayName),
      joinedMessage([status.map(statusLabel), message]),
      stringValue(for: ["url", "html_url", "deploy_url", "deployment_url"], in: object)
    )
  }

  private func level(from status: String?) -> DeploymentStatusLevel {
    let normalized = status?.lowercased().trimmedForPublishing ?? ""
    if ["success", "succeeded", "ready", "ok", "built", "uploaded", "live", "published"].contains(normalized) {
      return .success
    }
    if ["building", "queued", "pending", "running", "processing", "in_progress", "created", "initializing"].contains(normalized) {
      return .running
    }
    if ["failed", "failure", "error", "errored", "canceled", "cancelled", "timed_out", "timeout"].contains(normalized) {
      return .failed
    }
    return .unknown
  }

  private func joinedMessage(_ parts: [String?]) -> String {
    parts.compactMap { $0?.trimmedForPublishing.nilIfEmpty }.joined(separator: " · ")
  }

  private func statusLabel(_ value: String) -> String {
    CoreL10n.format("状态：%@", value)
  }

  private func branchLabel(_ value: String) -> String {
    CoreL10n.format("分支：%@", value)
  }

  private func commitLabel(_ value: String) -> String {
    CoreL10n.format("提交：%@", value)
  }

  private func targetLabel(_ value: String) -> String {
    CoreL10n.format("目标：%@", value)
  }

  private func stringValue(for keys: [String], in object: [String: Any]) -> String? {
    for key in keys {
      if let value = object[key] as? String, let normalized = value.trimmedForPublishing.nilIfEmpty {
        return normalized
      }
      if let value = object[key] as? NSNumber {
        return value.stringValue
      }
    }
    return nil
  }

  private func dictionaryValue(for keys: [String], in object: [String: Any]) -> [String: Any]? {
    for key in keys {
      if let value = object[key] as? [String: Any] {
        return value
      }
    }
    return nil
  }

  private func arrayValue(for keys: [String], in object: [String: Any]) -> [Any]? {
    for key in keys {
      if let value = object[key] as? [Any] {
        return value
      }
    }
    return nil
  }
}
