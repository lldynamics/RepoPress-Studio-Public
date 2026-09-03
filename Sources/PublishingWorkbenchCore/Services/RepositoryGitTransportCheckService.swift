import Foundation
import PublishingCoreSupport
import PublishingGitCore

/// Runs non-mutating commands that explain which local Git channel a profile
/// would use to contact its remote.
public struct RepositoryGitTransportCheckService: Sendable {
  private let gitCommandRunner: GitCommandRunner

  public init(gitCommandRunner: GitCommandRunner = GitCommandRunner()) {
    self.gitCommandRunner = gitCommandRunner
  }

  /// Checks whether the configured remote and target branch can be *read*.
  ///
  /// This method intentionally never executes `push` or `push --dry-run`.
  /// A `true` result for `canReadRemote` must therefore not be interpreted as
  /// permission to write to the remote.
  public func check(
    profile: SiteProfile,
    remoteName: String = "origin"
  ) async -> RepositoryGitTransportCheck {
    let checkedAt = Date()
    let normalizedRemoteName = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
    let targetBranch = profile.branch.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let rootURL = profile.resolvedLocalRepositoryRootURL else {
      return failedCheck(
        remoteName: normalizedRemoteName,
        targetBranch: targetBranch,
        summary: CoreL10n.text("未配置本地仓库，无法检查 Git 推送通道"),
        detail: CoreL10n.text("请先在站点设置中选择本地仓库目录；本次检查没有执行推送。"),
        checkedAt: checkedAt
      )
    }

    guard Self.isValidRemoteName(normalizedRemoteName) else {
      return failedCheck(
        remoteName: normalizedRemoteName,
        targetBranch: targetBranch,
        summary: CoreL10n.text("Git 远端名称无效"),
        detail: CoreL10n.text("请使用仓库中已配置的远端名称（例如 origin）；本次检查没有执行推送。"),
        checkedAt: checkedAt
      )
    }

    guard Self.isValidBranchName(targetBranch) else {
      return failedCheck(
        remoteName: normalizedRemoteName,
        targetBranch: targetBranch,
        summary: CoreL10n.text("目标分支名称无效"),
        detail: CoreL10n.text("请在站点设置中填写有效分支名后重试；本次检查没有执行推送。"),
        checkedAt: checkedAt
      )
    }

    let remoteResult = await gitCommandRunner.runAsync(
      ["remote", "get-url", normalizedRemoteName],
      rootURL: rootURL
    )
    guard remoteResult.terminationStatus == 0 else {
      return failedCheck(
        remoteName: normalizedRemoteName,
        targetBranch: targetBranch,
        summary: CoreL10n.format("未找到 Git 远端 %@", normalizedRemoteName),
        detail: Self.remoteLookupFailureDetail(for: remoteResult),
        checkedAt: checkedAt
      )
    }

    let rawRemoteURL = remoteResult.standardOutput
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawRemoteURL.isEmpty else {
      return failedCheck(
        remoteName: normalizedRemoteName,
        targetBranch: targetBranch,
        summary: CoreL10n.text("Git 远端地址为空"),
        detail: CoreL10n.format("请重新配置远端 %@ 的地址；本次检查没有执行推送。", normalizedRemoteName),
        checkedAt: checkedAt
      )
    }

    let sanitizedRemoteURL = Self.sanitizedRemoteURL(rawRemoteURL)
    let transport = Self.transportKind(for: rawRemoteURL)
    let reference = "refs/heads/\(targetBranch)"
    let readResult = await gitCommandRunner.runAsync(
      [
        "-c", "credential.interactive=never",
        "ls-remote", "--heads", normalizedRemoteName, reference,
      ],
      rootURL: rootURL
    )

    guard readResult.terminationStatus == 0 else {
      return RepositoryGitTransportCheck(
        remoteName: normalizedRemoteName,
        sanitizedRemoteURL: sanitizedRemoteURL,
        transport: transport,
        targetBranch: targetBranch,
        canReadRemote: false,
        targetBranchExists: nil,
        summary: CoreL10n.text("无法读取 Git 远端"),
        detail: Self.remoteReadFailureDetail(for: readResult),
        checkedAt: checkedAt
      )
    }

    let branchExists = Self.outputContains(reference: reference, in: readResult.standardOutput)
    let summary =
      branchExists
      ? CoreL10n.text("远端可读取，写入权限尚未验证")
      : CoreL10n.text("远端可读取，未找到目标分支；写入权限尚未验证")
    let detail =
      branchExists
      ? CoreL10n.format(
        "已通过 %@ 读取远端 %@ 的 %@ 分支。本次仅执行读取检查，未验证推送权限。", transport.displayName, normalizedRemoteName,
        targetBranch)
      : CoreL10n.format(
        "已通过 %@ 读取远端 %@，但未找到 %@ 分支。本次仅执行读取检查，未验证推送权限。", transport.displayName, normalizedRemoteName,
        targetBranch)
    return RepositoryGitTransportCheck(
      remoteName: normalizedRemoteName,
      sanitizedRemoteURL: sanitizedRemoteURL,
      transport: transport,
      targetBranch: targetBranch,
      canReadRemote: true,
      targetBranchExists: branchExists,
      summary: summary,
      detail: detail,
      checkedAt: checkedAt
    )
  }

  private func failedCheck(
    remoteName: String,
    targetBranch: String,
    summary: String,
    detail: String,
    checkedAt: Date
  ) -> RepositoryGitTransportCheck {
    RepositoryGitTransportCheck(
      remoteName: remoteName,
      sanitizedRemoteURL: nil,
      transport: .unknown,
      targetBranch: targetBranch,
      canReadRemote: false,
      targetBranchExists: nil,
      summary: summary,
      detail: detail,
      checkedAt: checkedAt
    )
  }

  private static func outputContains(reference: String, in output: String) -> Bool {
    output.split(whereSeparator: \.isNewline).contains { line in
      line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == Substring(reference)
    }
  }

  private static func isValidRemoteName(_ name: String) -> Bool {
    guard !name.isEmpty, name.utf8.count <= 255 else { return false }
    return name.allSatisfy { character in
      character.isLetter || character.isNumber || character == "-" || character == "_"
        || character == "."
    }
  }

  private static func isValidBranchName(_ branch: String) -> Bool {
    guard !branch.isEmpty,
      branch.utf8.count <= 255,
      !branch.hasPrefix("/"),
      !branch.hasSuffix("/"),
      !branch.hasSuffix("."),
      !branch.contains(".."),
      !branch.contains("//"),
      !branch.contains("@{"),
      !branch.contains(where: {
        $0.isWhitespace || $0.isNewline || $0 == "~" || $0 == "^" || $0 == ":" || $0 == "?"
          || $0 == "*" || $0 == "[" || $0 == "\\"
      })
    else {
      return false
    }
    return branch.split(separator: "/").allSatisfy {
      $0 != "." && $0 != ".." && !$0.hasSuffix(".lock")
    }
  }

  private static func transportKind(for remoteURL: String) -> RepositoryGitTransportKind {
    let value = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercase = value.lowercased()
    if lowercase.hasPrefix("ssh://") {
      return .ssh
    }
    if lowercase.hasPrefix("https://") {
      return .https
    }
    if lowercase.hasPrefix("file://") || value.hasPrefix("/") || value.hasPrefix("./")
      || value.hasPrefix("../") || value.hasPrefix("~")
    {
      return .local
    }
    if !value.contains("://"),
      let separator = value.lastIndex(of: ":"),
      separator > value.startIndex,
      !value[..<separator].contains("/")
    {
      return .ssh
    }
    if !value.contains("://") {
      return .local
    }
    return .unknown
  }

  private static func sanitizedRemoteURL(_ rawRemoteURL: String) -> String {
    let trimmed = rawRemoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if var components = URLComponents(string: trimmed), components.scheme != nil {
      components.user = nil
      components.password = nil
      components.query = nil
      components.fragment = nil
      if let sanitized = components.string, !sanitized.isEmpty {
        return GitCommandRunner.redactedDiagnosticText(sanitized)
      }
    }

    if let atIndex = trimmed.lastIndex(of: "@"),
      let colonIndex = trimmed[atIndex...].firstIndex(of: ":"),
      colonIndex > atIndex
    {
      return GitCommandRunner.redactedDiagnosticText(
        String(trimmed[trimmed.index(after: atIndex)...]))
    }
    return GitCommandRunner.redactedDiagnosticText(trimmed)
  }

  private static func remoteLookupFailureDetail(for result: GitCommandResult) -> String {
    if result.didTimeOut {
      return CoreL10n.text("读取本地 Git 远端配置超时。请确认仓库目录有效后重试；本次检查没有执行推送。")
    }
    return CoreL10n.text("请确认仓库已配置该远端名称；本次检查没有执行推送。")
  }

  private static func remoteReadFailureDetail(for result: GitCommandResult) -> String {
    if result.didTimeOut {
      return CoreL10n.text("读取远端超时。请检查网络、VPN 或系统 Git 凭据（SSH agent/HTTPS 凭据）后重试；本次检查没有执行推送。")
    }
    return CoreL10n.text("请检查远端地址、网络和系统 Git 凭据（SSH agent/HTTPS 凭据）后重试；本次检查没有执行推送。")
  }
}
