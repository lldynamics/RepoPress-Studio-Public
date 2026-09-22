import Foundation
import PublishingAICore

/// Installation always follows the existing package manager. Unknown/custom
/// installations remain user-managed, rather than silently creating a second CLI.
public struct CodexRuntimeSetupPlan: Equatable, Sendable {
  public enum Method: String, Sendable { case standalone, homebrew, homebrewFormula, npm, manual }
  public let method: Method
  public let runtimeURL: URL?
  public let managerURL: URL?
  public var isAutomatic: Bool { method != .manual }
  public var title: String { runtimeURL == nil ? CoreL10n.text("安装并继续") : CoreL10n.text("更新连接组件") }
  public var explanation: String {
    switch method {
    case .standalone: return CoreL10n.text("从 OpenAI 下载官方安装器，将连接组件安装到当前用户目录。")
    case .homebrew, .homebrewFormula: return CoreL10n.text("使用现有 Homebrew 更新 Codex。")
    case .npm: return CoreL10n.text("使用现有 npm 更新 Codex，保留当前安装渠道。")
    case .manual: return CoreL10n.text("此组件由自定义路径提供，请按原安装方式更新后重新检测。")
    }
  }
}

public enum CodexRuntimeSetupError: LocalizedError {
  case changedInstallation, manualInstallation, invalidInstaller
  case failed(String)
  case verificationFailed
  public var errorDescription: String? {
    switch self {
    case .changedInstallation: return CoreL10n.text("连接组件的安装位置已变化，请重新检测后再试。")
    case .manualInstallation: return CoreL10n.text("无法确定原安装渠道，请打开官方安装说明完成更新。")
    case .invalidInstaller: return CoreL10n.text("官方安装器下载不完整或格式异常，请重试。")
    case .failed(let detail): return CoreL10n.format("组件准备失败：%@", detail)
    case .verificationFailed: return CoreL10n.text("安装命令已结束，但未检测到推荐版本。请检查安装位置后重试。")
    }
  }
}

public struct CodexRuntimeSetupService: Sendable {
  /// Verified against OpenAI's 0.153.4 model-picker fix, 2026-09-09.
  /// This is a recommendation, separate from the minimum protocol version.
  public static let recommendedVersion = CodexAppServerRuntimeVersion(
    major: 0, minor: 153, patch: 4)
  public static let installationGuide = URL(string: "https://developers.openai.com/codex/cli")!

  public init() {}

  public static func needsRecommendedUpdate(_ status: CodexAppServerRuntimeStatus) -> Bool {
    guard let version = status.parsedVersion else { return true }
    return version < recommendedVersion
  }

  public static func plan(
    for status: CodexAppServerRuntimeStatus,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> CodexRuntimeSetupPlan {
    guard let runtime = status.executableURL else {
      return .init(method: .standalone, runtimeURL: nil, managerURL: nil)
    }
    let resolved = runtime.resolvingSymlinksInPath().path
    let parent = runtime.deletingLastPathComponent()
    let brew = parent.appendingPathComponent("brew")
    let npm = parent.appendingPathComponent("npm")
    let home = environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
    let codexDirectory = environment["CODEX_HOME"] ?? home + "/.codex"
    if status.source == .homebrew,
      resolved.contains("/Caskroom/codex/") || resolved.contains("/Cellar/codex/"),
      fileManager.isExecutableFile(atPath: brew.path)
    {
      return .init(
        method: resolved.contains("/Caskroom/codex/") ? .homebrew : .homebrewFormula,
        runtimeURL: runtime, managerURL: brew)
    }
    if resolved.contains("/node_modules/@openai/codex/"),
      fileManager.isExecutableFile(atPath: npm.path)
    {
      return .init(method: .npm, runtimeURL: runtime, managerURL: npm)
    }
    if runtime.standardizedFileURL.path == home + "/.local/bin/codex",
      resolved.hasPrefix(codexDirectory + "/packages/standalone/")
    {
      return .init(method: .standalone, runtimeURL: runtime, managerURL: nil)
    }
    return .init(method: .manual, runtimeURL: runtime, managerURL: nil)
  }

  public func prepare(
    plan: CodexRuntimeSetupPlan,
    onProgress: @escaping @Sendable (String) -> Void
  ) async throws -> CodexAppServerRuntimeStatus {
    try Task.checkCancellation()
    let current = await CodexAppServerProcessTransport.inspectRuntime()
    try Task.checkCancellation()
    guard Self.plan(for: current) == plan else { throw CodexRuntimeSetupError.changedInstallation }
    guard plan.isAutomatic else { throw CodexRuntimeSetupError.manualInstallation }
    var environment = CodexRuntimeProcessEnvironment.sanitized()
    // GUI processes may have only /usr/bin:/bin. npm and brew need their own bin.
    if let manager = plan.managerURL {
      environment["PATH"] =
        manager.deletingLastPathComponent().path + ":"
        + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
    }
    switch plan.method {
    case .homebrew, .homebrewFormula, .npm:
      guard let manager = plan.managerURL else { throw CodexRuntimeSetupError.manualInstallation }
      environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
      environment["HOMEBREW_NO_ENV_HINTS"] = "1"
      onProgress(CoreL10n.text("正在下载并更新连接组件…"))
      try await run(
        manager, arguments: Self.managerArguments(for: plan.method), environment: environment)
    case .standalone:
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "RepoPress-Codex-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let script = directory.appendingPathComponent("install.sh")
      onProgress(CoreL10n.text("正在下载 OpenAI 官方安装器…"))
      try await run(
        URL(fileURLWithPath: "/usr/bin/curl"),
        arguments: [
          "--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir",
          "=https", "--max-redirs", "5", "--max-time", "60", "--max-filesize", "1048576",
          "--output", script.path, "https://chatgpt.com/codex/install.sh",
        ], environment: environment)
      let data = try Data(contentsOf: script)
      guard data.count <= 1_048_576, data.starts(with: Data("#!/bin/sh".utf8)) else {
        throw CodexRuntimeSetupError.invalidInstaller
      }
      try Task.checkCancellation()
      environment["CODEX_NON_INTERACTIVE"] = "true"
      onProgress(CoreL10n.text("正在安装连接组件，完成后将自动检查…"))
      try await run(
        URL(fileURLWithPath: "/bin/sh"),
        arguments: [script.path, "--release", Self.recommendedVersion.description],
        environment: environment)
    case .manual: throw CodexRuntimeSetupError.manualInstallation
    }
    try Task.checkCancellation()
    onProgress(CoreL10n.text("正在验证组件版本…"))
    let installed = await CodexAppServerProcessTransport.inspectRuntime()
    guard installed.isCompatible, !Self.needsRecommendedUpdate(installed) else {
      throw CodexRuntimeSetupError.verificationFailed
    }
    return installed
  }

  private func run(_ executable: URL, arguments: [String], environment: [String: String])
    async throws
  {
    try Task.checkCancellation()
    let result = await AIComponentProcessRunner(
      executableURL: executable, arguments: arguments, environment: environment
    ).run(timeout: .seconds(600))
    try Task.checkCancellation()
    guard result.succeeded else {
      if result.interruption == "timedOut" {
        throw CodexRuntimeSetupError.failed(CoreL10n.text("下载或安装超时，请检查网络后重试。"))
      }
      let detail = Self.sanitizedDiagnostic(result.output)
      throw CodexRuntimeSetupError.failed(
        detail.isEmpty ? CoreL10n.text("安装程序未正常完成，请检查网络和安装目录的写入权限。") : detail)
    }
  }

  static func managerArguments(for method: CodexRuntimeSetupPlan.Method) -> [String] {
    switch method {
    case .homebrew: return ["upgrade", "--cask", "codex"]
    case .homebrewFormula: return ["upgrade", "--formula", "codex"]
    case .npm: return ["install", "--global", "@openai/codex@latest"]
    case .standalone, .manual: return []
    }
  }

  static func sanitizedDiagnostic(_ value: String) -> String {
    let text = String(value.suffix(1_500))
    return text.replacingOccurrences(
      of: #"(https?://)[^\s/@]+:[^\s/@]+@"#, with: "$1[已隐藏]@", options: .regularExpression)
  }
}
