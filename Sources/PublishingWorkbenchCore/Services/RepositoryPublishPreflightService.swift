import Foundation
import PublishingAICore

#if canImport(Darwin)
  import Darwin
#endif

/// Runs site-generator integrity checks before a Git publication.
/// This is deliberately separate from Git mutation services: a failed result
/// blocks a caller from publishing but never stages, commits, or pushes files.
public struct RepositoryPublishPreflightService: Sendable {
  public static let defaultTimeout: TimeInterval = 120
  public static let defaultMaximumOutputBytes = 64 * 1_024

  private let commandRunner: RepositoryPublishPreflightCommandRunner
  private let temporaryDirectory: @Sendable () -> URL
  private let fileExists: @Sendable (String) -> Bool
  private let createDirectory: @Sendable (URL) throws -> Void
  private let removeItem: @Sendable (URL) -> Void
  private let trustedZolaExecutable: @Sendable () -> String?
  private let trustedExecutable: @Sendable (String) -> String?
  private let timeout: TimeInterval
  private let maximumOutputBytes: Int

  public init(
    commandRunner: RepositoryPublishPreflightCommandRunner = .production,
    timeout: TimeInterval = RepositoryPublishPreflightService.defaultTimeout,
    maximumOutputBytes: Int = RepositoryPublishPreflightService.defaultMaximumOutputBytes,
    temporaryDirectory: @escaping @Sendable () -> URL = {
      FileManager.default.temporaryDirectory
    },
    fileExists: @escaping @Sendable (String) -> Bool = {
      FileManager.default.fileExists(atPath: $0)
    },
    createDirectory: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: $0.path
      )
    },
    removeItem: @escaping @Sendable (URL) -> Void = {
      try? FileManager.default.removeItem(at: $0)
    },
    trustedZolaExecutable: @escaping @Sendable () -> String? = Self.resolveTrustedZolaExecutable,
    trustedExecutable: @escaping @Sendable (String) -> String? = Self.resolveTrustedExecutable
  ) {
    self.commandRunner = commandRunner
    self.timeout = max(1, timeout)
    self.maximumOutputBytes = max(1_024, maximumOutputBytes)
    self.temporaryDirectory = temporaryDirectory
    self.fileExists = fileExists
    self.createDirectory = createDirectory
    self.removeItem = removeItem
    self.trustedZolaExecutable = trustedZolaExecutable
    self.trustedExecutable = trustedExecutable
  }

  public func run(profile: SiteProfile) -> RepositoryPublishPreflightResult {
    guard profile.siteKind == .zola else {
      return runAdditionalEngine(profile: profile)
    }

    let rootURL = URL(fileURLWithPath: profile.localRepositoryRootPath, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    guard fileExists(rootURL.path) else {
      return .init(
        outcome: .failed(.repositoryUnavailable),
        message: CoreL10n.text("未找到本地站点仓库，无法执行发布前门禁。")
      )
    }
    guard hasZolaConfiguration(in: rootURL) else {
      return .init(
        outcome: .skipped(.zolaConfigurationNotFound),
        message: CoreL10n.text("仓库中未找到 Zola 配置，未执行 Zola 发布前门禁。")
      )
    }
    guard let executablePath = trustedZolaExecutable() else {
      return .init(
        outcome: .failed(.zolaUnavailable),
        message: CoreL10n.text("未找到受信任的 Zola 工具，已阻止发布。")
      )
    }

    let check = RepositoryPublishPreflightCommand(
      stage: .check,
      executablePath: executablePath,
      arguments: ["check", "--skip-external-links"],
      workingDirectoryPath: rootURL.path,
      timeout: timeout,
      maximumOutputBytes: maximumOutputBytes
    )
    let checkResult = commandRunner.run(check)
    if let failure = failure(for: checkResult, stage: .check) {
      return result(for: failure, commandResult: checkResult, stage: .check)
    }

    let outputRoot = temporaryDirectory()
      .appendingPathComponent("RepoPress-Zola-Preflight-\(UUID().uuidString)", isDirectory: true)
      .standardizedFileURL
    guard outputRoot.path != rootURL.path,
      !outputRoot.path.hasPrefix(rootURL.path + "/")
    else {
      return .init(
        outcome: .failed(.temporaryOutputUnavailable),
        message: CoreL10n.text("无法创建仓库外的临时构建目录，已阻止发布。")
      )
    }
    let publicOutput = outputRoot.appendingPathComponent("public", isDirectory: true)
    do {
      try createDirectory(outputRoot)
    } catch {
      return .init(
        outcome: .failed(.temporaryOutputUnavailable),
        message: CoreL10n.text("无法创建仓库外的临时构建目录，已阻止发布。"),
        diagnostics: [CoreL10n.text("临时目录创建失败。")]
      )
    }
    defer { removeItem(outputRoot) }

    // The output path is created under the process temporary directory rather
    // than in the repository, so build artifacts cannot contaminate a commit.
    let build = RepositoryPublishPreflightCommand(
      stage: .build,
      executablePath: executablePath,
      arguments: ["build", "--force", "--minify", "--output-dir", publicOutput.path],
      workingDirectoryPath: rootURL.path,
      timeout: timeout,
      maximumOutputBytes: maximumOutputBytes
    )
    let buildResult = commandRunner.run(build)
    if let failure = failure(for: buildResult, stage: .build) {
      return result(for: failure, commandResult: buildResult, stage: .build)
    }

    return .init(
      outcome: .passed,
      message: CoreL10n.text("Zola 检查和独立临时目录构建均已通过。"),
      diagnostics: diagnostics(for: checkResult) + diagnostics(for: buildResult)
    )
  }

  private func runAdditionalEngine(profile: SiteProfile) -> RepositoryPublishPreflightResult {
    let kind = profile.siteKind
    guard [.hugo, .astro, .vitePress, .hexo, .jekyll, .quartz, .docusaurus, .mkDocs].contains(kind)
    else {
      return .init(
        outcome: .skipped(.unsupportedSiteKind),
        message: CoreL10n.text("当前站点类型尚无本地编译门禁。")
      )
    }
    guard let configuredRoot = profile.localRepositoryRootURL else {
      return .init(
        outcome: .failed(.repositoryUnavailable),
        message: CoreL10n.text("未找到本地站点仓库，无法执行发布前门禁。")
      )
    }
    let rootURL = configuredRoot.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return .init(
        outcome: .failed(.repositoryUnavailable),
        message: CoreL10n.text("未找到本地站点仓库，无法执行发布前门禁。")
      )
    }
    guard hasConfiguration(for: kind, in: rootURL) else {
      return .init(
        outcome: .failed(.configurationUnavailable),
        message: CoreL10n.text("未找到当前站点引擎的配置，已阻止发布。")
      )
    }

    let toolName: String
    switch kind {
    case .hugo: toolName = "hugo"
    case .jekyll: toolName = "bundle"
    case .mkDocs: toolName = "mkdocs"
    default: toolName = "node"
    }
    guard let executablePath = trustedExecutable(toolName) else {
      return .init(
        outcome: .failed(.toolUnavailable),
        message: CoreL10n.format("未找到受信任的 %@ 工具，已阻止发布。", toolName)
      )
    }
    if let cliName = nodeCLIName(for: kind) {
      let cliURL = rootURL.appendingPathComponent("node_modules/.bin/\(cliName)")
      let resolved = cliURL.resolvingSymlinksInPath()
      guard fileExists(cliURL.path),
        resolved.path.hasPrefix(rootURL.path + "/")
      else {
        return .init(
          outcome: .failed(.dependencyUnavailable),
          message: CoreL10n.format("未找到当前仓库安装的 %@ 依赖，已阻止发布。", cliName)
        )
      }
    }
    if kind == .quartz {
      let cliURL = rootURL.appendingPathComponent("quartz/bootstrap-cli.mjs")
      guard fileExists(cliURL.path),
        cliURL.resolvingSymlinksInPath().path.hasPrefix(rootURL.path + "/")
      else {
        return .init(
          outcome: .failed(.dependencyUnavailable),
          message: CoreL10n.text("未找到当前仓库的 Quartz 4 命令入口，已阻止发布。")
        )
      }
    }

    let outputRoot = temporaryDirectory()
      .appendingPathComponent(
        "RepoPress-\(kind.rawValue)-Preflight-\(UUID().uuidString)", isDirectory: true
      )
      .standardizedFileURL.resolvingSymlinksInPath()
    guard outputRoot.path != rootURL.path,
      !outputRoot.path.hasPrefix(rootURL.path + "/")
    else {
      return .init(
        outcome: .failed(.temporaryOutputUnavailable),
        message: CoreL10n.text("无法创建仓库外的临时构建目录，已阻止发布。")
      )
    }
    let stagedRoot = outputRoot.appendingPathComponent("source", isDirectory: true)
    let publicOutput = outputRoot.appendingPathComponent("public", isDirectory: true)
    do {
      try createDirectory(outputRoot)
      // A staged copy is required for generators that write cache, metadata or
      // default output into their working directory even when an output flag is supplied.
      try FileManager.default.copyItem(at: rootURL, to: stagedRoot)
    } catch {
      removeItem(outputRoot)
      return .init(
        outcome: .failed(.temporaryOutputUnavailable),
        message: CoreL10n.text("无法复制仓库到临时构建目录，已阻止发布。")
      )
    }
    defer { removeItem(outputRoot) }
    guard !hasEscapingSymbolicLink(in: stagedRoot) else {
      return .init(
        outcome: .failed(.unsafeRepositoryLink),
        message: CoreL10n.text("仓库含指向临时副本外的符号链接，已阻止发布前编译。")
      )
    }

    let environment = [
      "CI": "1",
      "ASTRO_TELEMETRY_DISABLED": "1",
      "XDG_CACHE_HOME": outputRoot.appendingPathComponent("cache").path,
      "TMPDIR": outputRoot.path,
    ]
    let commands = additionalCommands(
      for: kind,
      executablePath: executablePath,
      stagedRoot: stagedRoot,
      outputRoot: outputRoot,
      publicOutput: publicOutput,
      environment: environment
    )
    guard !commands.isEmpty else {
      return .init(
        outcome: .failed(.dependencyUnavailable),
        message: CoreL10n.text("无法制定站点编译命令，已阻止发布。")
      )
    }
    var diagnostics: [String] = []
    for command in commands {
      let commandResult = commandRunner.run(command)
      diagnostics += self.diagnostics(for: commandResult)
      if let failure = failure(for: commandResult, stage: command.stage) {
        return result(
          for: failure,
          commandResult: commandResult,
          stage: command.stage,
          engineName: kind.displayName
        )
      }
    }
    return .init(
      outcome: .passed,
      message: CoreL10n.format("%@ 临时目录编译检查已通过。", kind.displayName),
      diagnostics: diagnostics
    )
  }

  private func hasEscapingSymbolicLink(in stagedRoot: URL) -> Bool {
    var enumerationFailed = false
    guard
      let enumerator = FileManager.default.enumerator(
        at: stagedRoot,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: [],
        errorHandler: { _, _ in
          enumerationFailed = true
          return false
        }
      )
    else { return true }
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
        return true
      }
      guard values.isSymbolicLink == true else { continue }
      let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
      guard resolved.hasPrefix(stagedRoot.path + "/") else { return true }
    }
    return enumerationFailed
  }

  private func hasConfiguration(for kind: SiteKind, in rootURL: URL) -> Bool {
    let names: [String]
    switch kind {
    case .hugo:
      names = [
        "hugo.toml", "hugo.yaml", "hugo.yml", "hugo.json", "config.toml", "config.yaml",
        "config.yml", "config.json", "config",
      ]
    case .astro:
      names = ["package.json"]
    case .vitePress:
      names = ["package.json"]
    case .hexo:
      names = ["_config.yml", "_config.yaml"]
    case .jekyll:
      names = ["Gemfile"]
    case .quartz:
      names = ["quartz.config.ts"]
    case .docusaurus:
      names = [
        "docusaurus.config.js", "docusaurus.config.ts", "docusaurus.config.mjs",
        "docusaurus.config.cjs",
      ]
    case .mkDocs:
      names = ["mkdocs.yml", "mkdocs.yaml"]
    default:
      return false
    }
    return names.contains { fileExists(rootURL.appendingPathComponent($0).path) }
  }

  private func nodeCLIName(for kind: SiteKind) -> String? {
    switch kind {
    case .astro: "astro"
    case .vitePress: "vitepress"
    case .hexo: "hexo"
    case .docusaurus: "docusaurus"
    default: nil
    }
  }

  private func additionalCommands(
    for kind: SiteKind,
    executablePath: String,
    stagedRoot: URL,
    outputRoot: URL,
    publicOutput: URL,
    environment: [String: String]
  ) -> [RepositoryPublishPreflightCommand] {
    let cli = nodeCLIName(for: kind).map {
      stagedRoot.appendingPathComponent("node_modules/.bin/\($0)").path
    }
    let cachePath = outputRoot.appendingPathComponent("cache").path
    let specs: [(RepositoryPublishPreflightCommand.Stage, [String])]
    switch kind {
    case .hugo:
      specs = [
        (
          .check,
          [
            "--renderToMemory", "--buildDrafts", "--buildFuture", "--buildExpired", "--cacheDir",
            cachePath,
          ]
        ),
        (
          .build, ["-e", "production", "--destination", publicOutput.path, "--cacheDir", cachePath]
        ),
      ]
    case .astro:
      guard let cli else { return [] }
      specs = [
        (.check, [cli, "check"]),
        (.build, [cli, "build", "--outDir", publicOutput.path]),
      ]
    case .vitePress:
      guard let cli else { return [] }
      let docsRoot = fileExists(stagedRoot.appendingPathComponent("docs").path) ? "docs" : "."
      specs = [(.build, [cli, "build", docsRoot, "--outDir", publicOutput.path])]
    case .hexo:
      guard let cli else { return [] }
      specs = [(.build, [cli, "generate", "--bail"])]
    case .jekyll:
      specs = [(.build, ["exec", "jekyll", "build", "--destination", publicOutput.path])]
    case .quartz:
      specs = [(.build, ["quartz/bootstrap-cli.mjs", "build", "--output", publicOutput.path])]
    case .docusaurus:
      guard let cli else { return [] }
      specs = [(.build, [cli, "build", "--out-dir", publicOutput.path])]
    case .mkDocs:
      specs = [(.build, ["build", "--strict", "--site-dir", publicOutput.path])]
    default:
      specs = []
    }
    return specs.map { stage, arguments in
      RepositoryPublishPreflightCommand(
        stage: stage,
        executablePath: executablePath,
        arguments: arguments,
        workingDirectoryPath: stagedRoot.path,
        timeout: timeout,
        maximumOutputBytes: maximumOutputBytes,
        environmentOverrides: environment
      )
    }
  }

  private func hasZolaConfiguration(in rootURL: URL) -> Bool {
    ["config.toml", "config.yaml", "config.yml"].contains {
      fileExists(rootURL.appendingPathComponent($0).path)
    }
  }

  private func failure(
    for result: RepositoryPublishPreflightCommandResult,
    stage: RepositoryPublishPreflightCommand.Stage
  ) -> RepositoryPublishPreflightFailure? {
    switch result.termination {
    case .timedOut:
      return .timedOut
    case .outputTruncated:
      return .outputTruncated
    case .launchFailed:
      return .launchFailed
    case .exited:
      guard result.exitStatus == 0 else {
        return stage == .check ? .checkFailed : .buildFailed
      }
      return nil
    }
  }

  private func result(
    for failure: RepositoryPublishPreflightFailure,
    commandResult: RepositoryPublishPreflightCommandResult,
    stage: RepositoryPublishPreflightCommand.Stage,
    engineName: String = "Zola"
  ) -> RepositoryPublishPreflightResult {
    let stageName =
      stage == .check
      ? CoreL10n.format("%@ 检查", engineName)
      : CoreL10n.format("%@ 构建", engineName)
    let message: String
    switch failure {
    case .timedOut:
      message = CoreL10n.format("%@超时，已阻止发布。", stageName)
    case .outputTruncated:
      message = CoreL10n.format("%@输出超过安全上限，已阻止发布。", stageName)
    case .launchFailed:
      message = CoreL10n.format("无法启动受信任的 %@ 工具，已阻止发布。", engineName)
    default:
      message = CoreL10n.format("%@失败，已阻止发布。", stageName)
    }
    return .init(
      outcome: .failed(failure),
      message: message,
      diagnostics: diagnostics(for: commandResult)
    )
  }

  private func diagnostics(for result: RepositoryPublishPreflightCommandResult) -> [String] {
    let combined = [result.standardOutput, result.standardError]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    guard !combined.isEmpty else { return [] }
    let safeText = Self.sanitizeDiagnostic(combined)
    return safeText.isEmpty ? [] : [safeText]
  }

  private static func sanitizeDiagnostic(_ text: String) -> String {
    let bounded = String(text.prefix(4_096))
    let withoutControls = bounded.unicodeScalars.filter {
      $0.value >= 32 || $0 == "\n" || $0 == "\t"
    }.map(String.init).joined()
    let home =
      ProcessInfo.processInfo.environment["HOME"]
      ?? FileManager.default.homeDirectoryForCurrentUser.path
    return
      withoutControls
      .replacingOccurrences(of: home, with: "~")
      .replacingOccurrences(
        of: #"(?i)(token|secret|password|authorization)\s*[:=]\s*[^\s]+"#,
        with: "$1=[已隐藏]",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Resolves Zola only from the same trusted executable directories used by
  /// local site preview; repository paths and PATH entries outside that allowlist
  /// are never considered.
  public static func resolveTrustedZolaExecutable() -> String? {
    resolveTrustedExecutable(named: "zola")
  }

  public static func resolveTrustedExecutable(named name: String) -> String? {
    guard ["zola", "hugo", "node", "bundle", "mkdocs"].contains(name) else { return nil }
    for directory in LocalSitePreviewProcessService.trustedToolDirectories {
      let candidate = URL(fileURLWithPath: directory, isDirectory: true)
        .appendingPathComponent(name)
        .standardizedFileURL
        .path
      guard candidate.hasPrefix("/") else { continue }
      guard LocalSitePreviewProcessService.isTrustedExecutable(atPath: candidate) else { continue }
      return candidate
    }
    return nil
  }
}

extension RepositoryPublishPreflightCommandRunner {
  /// Production runner: direct POSIX spawn only. It does not invoke a
  /// shell, a repository script, or a package manager.
  public static let production = RepositoryPublishPreflightCommandRunner { command in
    RepositoryPublishPreflightProcessRunner.run(command)
  }
}

private enum RepositoryPublishPreflightProcessRunner {
  private static let terminationGrace: TimeInterval = 0.2

  static func run(_ command: RepositoryPublishPreflightCommand)
    -> RepositoryPublishPreflightCommandResult
  {
    guard command.executablePath.hasPrefix("/") else {
      return .init(termination: .launchFailed, standardError: "工具路径不是绝对路径。")
    }
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    defer {
      close(outputPipe.fileHandleForReading)
      close(outputPipe.fileHandleForWriting)
      close(errorPipe.fileHandleForReading)
      close(errorPipe.fileHandleForWriting)
    }
    let outputFD = outputPipe.fileHandleForReading.fileDescriptor
    let errorFD = errorPipe.fileHandleForReading.fileDescriptor
    guard makeNonblocking(outputFD), makeNonblocking(errorFD) else {
      return .init(termination: .launchFailed, standardError: "无法读取站点编译工具输出。")
    }
    let processID: pid_t
    do {
      processID = try launch(command, outputPipe: outputPipe, errorPipe: errorPipe)
    } catch {
      return .init(termination: .launchFailed, standardError: "无法启动站点编译工具。")
    }
    close(outputPipe.fileHandleForWriting)
    close(errorPipe.fileHandleForWriting)

    var output = RepositoryPublishPreflightOutputState()
    let deadline = ProcessInfo.processInfo.systemUptime + command.timeout
    var timedOut = false
    while true {
      collect(outputFD, into: &output, maximumBytes: command.maximumOutputBytes)
      collect(errorFD, into: &output, maximumBytes: command.maximumOutputBytes)
      var information = siginfo_t()
      let result = Darwin.waitid(
        P_PID, id_t(processID), &information, WEXITED | WNOWAIT | WNOHANG)
      if result == 0, information.si_pid == processID { break }
      if result == -1, errno != EINTR {
        // ECHILD means ownership has already gone; never signal a potentially
        // reused PID or process group after losing that ownership.
        return .init(termination: .launchFailed, standardError: "无法确认站点编译工具退出状态。")
      }
      if output.wasTruncated { break }
      if ProcessInfo.processInfo.systemUptime >= deadline {
        timedOut = true
        break
      }
      Thread.sleep(forTimeInterval: 0.01)
    }

    // Keep the leader unreaped until group cleanup ends, pinning its PID so a
    // late signal cannot target an unrelated process. Also clean children when
    // the CLI leader exits before them, rather than waiting forever for EOF.
    _ = Darwin.kill(-processID, SIGTERM)
    let graceDeadline = ProcessInfo.processInfo.systemUptime + terminationGrace
    while ProcessInfo.processInfo.systemUptime < graceDeadline {
      collect(outputFD, into: &output, maximumBytes: command.maximumOutputBytes)
      collect(errorFD, into: &output, maximumBytes: command.maximumOutputBytes)
      Thread.sleep(forTimeInterval: 0.01)
    }
    _ = Darwin.kill(-processID, SIGKILL)
    _ = Darwin.kill(processID, SIGKILL)
    var status: Int32 = 0
    var waitResult: pid_t
    repeat {
      waitResult = Darwin.waitpid(processID, &status, 0)
    } while waitResult == -1 && errno == EINTR
    collect(outputFD, into: &output, maximumBytes: command.maximumOutputBytes)
    collect(errorFD, into: &output, maximumBytes: command.maximumOutputBytes)
    let text = String(decoding: output.data, as: UTF8.self)
    if timedOut { return .init(termination: .timedOut, standardOutput: text) }
    guard waitResult == processID else {
      return .init(termination: .launchFailed, standardOutput: text)
    }
    let exitStatus = status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
    return .init(
      termination: output.wasTruncated ? .outputTruncated : .exited,
      exitStatus: exitStatus,
      standardOutput: text
    )
  }

  private static func launch(
    _ command: RepositoryPublishPreflightCommand, outputPipe: Pipe, errorPipe: Pipe
  ) throws -> pid_t {
    let arguments = try CodexRuntimeCStringArray([command.executablePath] + command.arguments)
    let environment = LocalSitePreviewProcessService.launchEnvironment()
      .merging(command.environmentOverrides) { _, override in override }
    let environmentStrings = try CodexRuntimeCStringArray(
      environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw LaunchError.failed }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard
      posix_spawn_file_actions_addchdir_np(&actions, command.workingDirectoryPath) == 0,
      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
      posix_spawn_file_actions_adddup2(
        &actions, outputPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(
        &actions, errorPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) == 0
    else { throw LaunchError.failed }
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { throw LaunchError.failed }
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else { throw LaunchError.failed }
    var processID: pid_t = 0
    let result = command.executablePath.withCString {
      posix_spawn(
        &processID, $0, &actions, &attributes, arguments.pointer, environmentStrings.pointer)
    }
    guard result == 0, processID > 0 else { throw LaunchError.failed }
    return processID
  }

  private static func makeNonblocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    return flags != -1 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1
  }

  private static func collect(
    _ descriptor: Int32, into output: inout RepositoryPublishPreflightOutputState,
    maximumBytes: Int
  ) {
    var buffer = [UInt8](repeating: 0, count: 8_192)
    // Bound each drain so a continuously writing CLI cannot starve its timer.
    for _ in 0..<32 {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if count == -1, errno == EINTR { continue }
      guard count > 0 else { return }
      let remaining = max(0, maximumBytes - output.data.count)
      output.data.append(contentsOf: buffer.prefix(min(count, remaining)))
      if count > remaining { output.wasTruncated = true }
    }
  }

  private static func close(_ handle: FileHandle) {
    do {
      try handle.close()
    } catch {
      // Closing an already closed pipe after launch failure is harmless.
    }
  }

  private enum LaunchError: Error { case failed }
}

private struct RepositoryPublishPreflightOutputState {
  var data = Data()
  var wasTruncated = false
}
