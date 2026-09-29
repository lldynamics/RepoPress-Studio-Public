import CryptoKit
import Foundation
import PublishingAICore

public struct CodexRuntimeSetupPlan: Equatable, Sendable {
  public enum Method: String, Sendable { case managed }
  public let method: Method
  public let runtimeURL: URL?
  public var isAutomatic: Bool { true }
  public var title: String {
    runtimeURL == nil ? CoreL10n.text("安装并继续") : CoreL10n.text("修复或更新连接组件")
  }
  public var explanation: String {
    CoreL10n.text("从 OpenAI 下载经过本应用验证的连接组件，由本应用独立管理。无需打开终端。")
  }
}

public enum CodexRuntimeSetupError: LocalizedError, Equatable {
  case installationBusy, invalidArchive, verificationFailed, noPreviousVersion
  case changedInstallation
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .installationBusy:
      return CoreL10n.text("另一个窗口正在准备连接组件，请稍后重新检测。")
    case .invalidArchive:
      return CoreL10n.text("组件下载校验失败，原有版本未改变。请重试。")
    case .verificationFailed:
      return CoreL10n.text("新组件未通过启动验证，原有版本未改变。请重试或选择其他连接。")
    case .noPreviousVersion:
      return CoreL10n.text("没有可恢复的上一版本。请重新安装连接组件。")
    case .changedInstallation:
      return CoreL10n.text("组件设置已变化，请重新检测后再试。")
    case .failed(let detail):
      return CoreL10n.format("组件准备失败：%@", detail)
    }
  }
}

/// Downloads into a new release directory; only a verified candidate becomes
/// active. System package managers, PATH, shell profiles and credentials are
/// never modified. The shared client reconnects after active work finishes.
public struct CodexRuntimeSetupService: Sendable {
  public static var recommendedVersion: CodexAppServerRuntimeVersion {
    CodexRuntimeRelease.approved.version
  }
  public static let installationGuide = URL(string: "https://learn.chatgpt.com/docs/codex/cli")!
  let layout: CodexManagedRuntime
  let release: CodexRuntimeRelease
  let download: @Sendable (URL, URL) async throws -> Void
  let validate: @Sendable (URL, CodexAppServerRuntimeVersion) async throws -> Void

  public init(directory: URL = CodexManagedRuntime.defaultDirectory()) {
    self.init(
      directory: directory, release: .approved,
      download: Self.downloadArchive, validate: Self.validateExecutable)
  }

  init(
    directory: URL, release: CodexRuntimeRelease,
    download: @escaping @Sendable (URL, URL) async throws -> Void,
    validate: @escaping @Sendable (URL, CodexAppServerRuntimeVersion) async throws -> Void
  ) {
    layout = CodexManagedRuntime(directory: directory)
    self.release = release
    self.download = download
    self.validate = validate
  }

  public static func needsRecommendedUpdate(_ status: CodexAppServerRuntimeStatus) -> Bool {
    guard let version = status.parsedVersion else { return true }
    return version < recommendedVersion
  }

  public static func plan(for status: CodexAppServerRuntimeStatus) -> CodexRuntimeSetupPlan {
    .init(method: .managed, runtimeURL: status.executableURL)
  }

  public func prepare(
    plan: CodexRuntimeSetupPlan,
    onProgress: @escaping @Sendable (String) -> Void
  ) async throws -> CodexAppServerRuntimeStatus {
    try Task.checkCancellation()
    let installationLock = try CodexRuntimeInstallationLock(directory: layout.directory)
    defer { installationLock.unlock() }
    let originalSelectionData = try selectionData()
    let selection = layout.readableSelection ?? .init()
    let identifier = "\(release.version)-\(UUID().uuidString)"
    let staging = layout.releasesDirectory.appendingPathComponent(identifier, isDirectory: true)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let archive = staging.appendingPathComponent("download.tar.gz")
    var activated = false
    defer { if !activated { try? FileManager.default.removeItem(at: staging) } }

    onProgress(CoreL10n.text("正在下载 ChatGPT 连接组件…"))
    try await download(release.archiveURL, archive)
    try Task.checkCancellation()
    onProgress(CoreL10n.text("正在校验下载内容…"))
    guard try Self.digest(of: archive) == release.sha256 else {
      throw CodexRuntimeSetupError.invalidArchive
    }
    let listing = try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tzf", archive.path])
    guard Self.isSafeArchiveListing(listing) else { throw CodexRuntimeSetupError.invalidArchive }
    onProgress(CoreL10n.text("正在安装并验证连接组件…"))
    _ = try await Self.run(
      URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", staging.path])
    try FileManager.default.removeItem(at: archive)
    guard let executable = layout.executableURL(for: identifier),
      FileManager.default.isExecutableFile(atPath: executable.path)
    else { throw CodexRuntimeSetupError.invalidArchive }
    try await validate(executable, release.version)
    try Task.checkCancellation()
    // Preference edits from another process must not be overwritten by a
    // candidate whose download began under a different selection.
    guard try selectionData() == originalSelectionData else {
      throw CodexRuntimeSetupError.changedInstallation
    }
    var next = selection
    next.previousRelease = selection.activeRelease
    next.activeRelease = identifier
    next.useSystem = false
    next.deferredVersion = nil
    if layout.readableSelection == nil, let originalSelectionData {
      try originalSelectionData.write(
        to: layout.directory.appendingPathComponent("selection-recovery-\(UUID().uuidString).json"),
        options: .withoutOverwriting)
    }
    try layout.save(next)
    activated = true
    return .init(
      executableURL: executable, source: .managed, version: "codex-cli \(release.version)")
  }

  public var canRollback: Bool {
    guard let previous = layout.readableSelection?.previousRelease,
      let executable = layout.executableURL(for: previous)
    else { return false }
    return FileManager.default.isExecutableFile(atPath: executable.path)
  }

  private func selectionData() throws -> Data? {
    guard FileManager.default.fileExists(atPath: layout.selectionURL.path) else { return nil }
    return try Data(contentsOf: layout.selectionURL)
  }

  public func rollback() async throws {
    let installationLock = try CodexRuntimeInstallationLock(directory: layout.directory)
    defer { installationLock.unlock() }
    var selection = try layout.selection()
    guard let previous = selection.previousRelease,
      let executable = layout.executableURL(for: previous),
      let version = await CodexAppServerProcessTransport.readVersion(executableURL: executable),
      let parsed = CodexAppServerRuntimeVersion(output: version), parsed.isSupported
    else { throw CodexRuntimeSetupError.noPreviousVersion }
    try await validate(executable, parsed)
    try Task.checkCancellation()
    let old = selection.activeRelease
    selection.activeRelease = previous
    selection.previousRelease = old
    selection.useSystem = false
    selection.deferredVersion = release.version.description
    try layout.save(selection)
  }

  static func isSafeArchiveListing(_ text: String) -> Bool {
    let paths = text.split(separator: "\n")
    return !paths.isEmpty && paths.contains("bin/codex")
      && paths.allSatisfy { path in
        !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
      }
  }

  static func digest(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      try Task.checkCancellation()
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func downloadArchive(_ url: URL, _ destination: URL) async throws {
    _ = try await run(
      URL(fileURLWithPath: "/usr/bin/curl"),
      [
        "--fail", "--location", "--silent", "--show-error", "--proto", "=https",
        "--proto-redir", "=https", "--max-redirs", "5", "--connect-timeout", "20",
        "--max-time", "300", "--max-filesize", "209715200", "--output", destination.path,
        url.absoluteString,
      ])
  }

  static func validateExecutable(_ executable: URL, _ expected: CodexAppServerRuntimeVersion)
    async throws
  {
    let validationHome = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RepoPress-Codex-Validation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: validationHome, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: validationHome) }
    var environment = CodexRuntimeProcessEnvironment.sanitized()
    environment["CODEX_HOME"] = validationHome.path
    guard
      let output = await CodexAppServerProcessTransport.readVersion(
        executableURL: executable, environment: environment),
      CodexAppServerRuntimeVersion(output: output) == expected, expected.isSupported
    else { throw CodexRuntimeSetupError.verificationFailed }
    let client = CodexAppServerClient(
      transport: CodexAppServerProcessTransport(
        executableURL: executable, environment: environment),
      requestTimeout: .seconds(15))
    do {
      try await client.start()
      await client.shutdown()
    } catch {
      await client.shutdown()
      throw CodexRuntimeSetupError.verificationFailed
    }
  }

  private static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
    let result = await AIComponentProcessRunner(executableURL: executable, arguments: arguments)
      .run(timeout: .seconds(360))
    try Task.checkCancellation()
    guard result.succeeded else {
      if result.interruption == "timedOut" {
        throw CodexRuntimeSetupError.failed(CoreL10n.text("下载或安装超时，请检查网络后重试。"))
      }
      let detail = sanitizedDiagnostic(result.output)
      throw CodexRuntimeSetupError.failed(
        detail.isEmpty ? CoreL10n.text("请检查网络连接、可用磁盘空间和目录写入权限。") : detail)
    }
    return result.output
  }

  static func sanitizedDiagnostic(_ value: String) -> String {
    String(value.suffix(1_500)).replacingOccurrences(
      of: #"(https?://)[^\s/@]+:[^\s/@]+@"#, with: "$1[已隐藏]@", options: .regularExpression)
  }
}
