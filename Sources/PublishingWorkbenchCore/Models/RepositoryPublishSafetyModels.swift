import Foundation

public enum RepositoryPublishSafetySeverity: String, Hashable, Sendable {
  case warning
  case blocker
}

public enum RepositoryPublishSafetyDiagnosticCode: String, Hashable, Sendable {
  case structuralDelete = "RP_STRUCTURAL_DELETE"
  case crossSectionMove = "RP_CROSS_SECTION_MOVE"
  case massDelete = "RP_MASS_DELETE"
  case massContentRewrite = "RP_MASS_CONTENT_REWRITE"
  case publishGuardChanged = "RP_PUBLISH_GUARD_CHANGED"
}

public struct RepositoryPublishSafetyDiagnostic: Hashable, Sendable, Identifiable {
  public let code: RepositoryPublishSafetyDiagnosticCode
  public let severity: RepositoryPublishSafetySeverity
  public let title: String
  public let message: String
  public let paths: [String]

  public var id: String {
    ([code.rawValue] + paths).joined(separator: "\u{1F}")
  }

  public init(
    code: RepositoryPublishSafetyDiagnosticCode,
    severity: RepositoryPublishSafetySeverity,
    title: String,
    message: String,
    paths: [String]
  ) {
    self.code = code
    self.severity = severity
    self.title = title
    self.message = message
    self.paths = paths.sorted()
  }
}

public struct RepositoryPublishSafetyReport: Hashable, Sendable {
  public let diagnostics: [RepositoryPublishSafetyDiagnostic]

  public init(diagnostics: [RepositoryPublishSafetyDiagnostic] = []) {
    self.diagnostics = diagnostics
  }

  public var blockers: [RepositoryPublishSafetyDiagnostic] {
    diagnostics.filter { $0.severity == .blocker }
  }

  public var warnings: [RepositoryPublishSafetyDiagnostic] {
    diagnostics.filter { $0.severity == .warning }
  }

  public var canPublish: Bool {
    blockers.isEmpty
  }
}

public enum RepositoryPublishSafetyError: LocalizedError, Equatable, Sendable {
  case blocked([RepositoryPublishSafetyDiagnostic])

  public var errorDescription: String? {
    switch self {
    case .blocked(let diagnostics):
      let details = diagnostics.map { diagnostic in
        let paths = diagnostic.paths.prefix(5).joined(separator: "、")
        let remaining = max(0, diagnostic.paths.count - 5)
        let suffix = remaining == 0 ? "" : "（另有 \(remaining) 个路径）"
        return "\(diagnostic.title)：\(paths)\(suffix)"
      }.joined(separator: "\n")
      return "发布前安全检查已停止本次提交：\n\(details)"
    }
  }
}
