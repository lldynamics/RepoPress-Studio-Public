import Foundation

public struct PublicRiskScanner: Sendable {
  private struct Rule: Sendable {
    let title: String
    let message: String
    let severity: PreflightSeverity
    let pattern: String
    let optionsRawValue: UInt

    init(
      title: String,
      message: String,
      severity: PreflightSeverity,
      pattern: String,
      options: NSRegularExpression.Options
    ) {
      self.title = title
      self.message = message
      self.severity = severity
      self.pattern = pattern
      optionsRawValue = options.rawValue
    }

    var options: NSRegularExpression.Options {
      NSRegularExpression.Options(rawValue: optionsRawValue)
    }
  }

  private struct ScannedField {
    var key: String
    var displayName: String
    var value: String
  }

  private let rules: [Rule]

  public init() {
    rules = [
      Rule(
        title: CoreL10n.text("疑似密钥泄露"),
        message: CoreL10n.text("包含疑似 API Key、Token、Secret 或密码，请移除后再公开发布。"),
        severity: .error,
        pattern: #"\b(api[_-]?key|secret|token|password|access[_-]?key|client[_-]?secret)\b\s*[:=]\s*["']?[A-Za-z0-9_./+=-]{12,}"#,
        options: [.caseInsensitive]
      ),
      Rule(
        title: CoreL10n.text("疑似密钥泄露"),
        message: CoreL10n.text("包含疑似服务访问 Token，请改用占位符或环境变量说明。"),
        severity: .error,
        pattern: #"\b(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"#,
        options: []
      ),
      Rule(
        title: CoreL10n.text("私钥块疑似泄露"),
        message: CoreL10n.text("包含 private key 标记，请确认没有把证书或私钥写入公开文章。"),
        severity: .error,
        pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#,
        options: [.caseInsensitive]
      ),
      Rule(
        title: CoreL10n.text("内网地址疑似泄露"),
        message: CoreL10n.text("包含 localhost 或内网 IP，公开前请确认不是调试地址、家庭网络或公司内网信息。"),
        severity: .warning,
        pattern: #"\b(localhost|127\.0\.0\.1|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3})\b"#,
        options: [.caseInsensitive]
      ),
      Rule(
        title: CoreL10n.text("本机路径疑似泄露"),
        message: CoreL10n.text("包含本机绝对路径，公开前建议改成相对路径或脱敏说明。"),
        severity: .warning,
        pattern: #"(/Users/\S+|/Volumes/\S+|[A-Za-z]:\\Users\\\S+)"#,
        options: []
      ),
    ]
  }

  public func scan(draft: ArticleDraft) -> [PreflightIssue] {
    let fields = scannedFields(for: draft)
    var issues: [PreflightIssue] = []

    for field in fields where !field.value.trimmedForPublishing.isEmpty {
      for rule in rules where matches(rule: rule, in: field.value) {
        issues.append(
          PreflightIssue(
            severity: rule.severity,
            title: rule.title,
            message: CoreL10n.format("%@：%@", field.displayName, rule.message),
            field: field.key,
            category: .publicRisk
          )
        )
      }
    }

    return issues
  }

  private func scannedFields(for draft: ArticleDraft) -> [ScannedField] {
    let attachmentText = draft.attachments
      .map { "\($0.originalFilename)\n\($0.relativePublishPath)\n\($0.repositoryPath)\n\($0.altText)\n\($0.caption)" }
      .joined(separator: "\n")

    return [
      ScannedField(key: "title", displayName: CoreL10n.text("标题"), value: draft.title),
      ScannedField(key: "summary", displayName: CoreL10n.text("摘要"), value: draft.summary),
      ScannedField(key: "tags", displayName: CoreL10n.text("标签/分类"), value: (draft.tags + draft.categories).joined(separator: "\n")),
      ScannedField(key: "body", displayName: CoreL10n.text("正文"), value: draft.bodyMarkdown),
      ScannedField(key: "attachments", displayName: CoreL10n.text("图片元数据"), value: attachmentText),
    ]
  }

  private func matches(rule: Rule, in value: String) -> Bool {
    guard let regex = try? NSRegularExpression(
      pattern: rule.pattern,
      options: rule.options
    ) else {
      return false
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.firstMatch(in: value, range: range) != nil
  }
}
