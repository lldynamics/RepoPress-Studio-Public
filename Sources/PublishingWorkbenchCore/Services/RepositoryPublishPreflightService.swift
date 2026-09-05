import Foundation
import os

/// Runs Zola's repository-wide integrity checks before a Git publication.
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
    trustedZolaExecutable: @escaping @Sendable () -> String? = Self.resolveTrustedZolaExecutable
  ) {
    self.commandRunner = commandRunner
    self.timeout = max(1, timeout)
    self.maximumOutputBytes = max(1_024, maximumOutputBytes)
    self.temporaryDirectory = temporaryDirectory
    self.fileExists = fileExists
    self.createDirectory = createDirectory
    self.removeItem = removeItem
    self.trustedZolaExecutable = trustedZolaExecutable
  }

  public func run(profile: SiteProfile) -> RepositoryPublishPreflightResult {
    guard profile.siteKind == .zola else {
      return .init(
        outcome: .skipped(.nonZolaProfile),
        message: CoreL10n.text("当前站点不是 Zola，未执行 Zola 发布前门禁。")
      )
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
    stage: RepositoryPublishPreflightCommand.Stage
  ) -> RepositoryPublishPreflightResult {
    let stageName =
      stage == .check
      ? CoreL10n.text("Zola 检查")
      : CoreL10n.text("Zola 构建")
    let message: String
    switch failure {
    case .timedOut:
      message = CoreL10n.format("%@超时，已阻止发布。", stageName)
    case .outputTruncated:
      message = CoreL10n.format("%@输出超过安全上限，已阻止发布。", stageName)
    case .launchFailed:
      message = CoreL10n.text("无法启动受信任的 Zola 工具，已阻止发布。")
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
    for directory in LocalSitePreviewProcessService.trustedToolDirectories {
      let candidate = URL(fileURLWithPath: directory, isDirectory: true)
        .appendingPathComponent("zola")
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
  /// Production runner: direct Process execution only. It does not invoke a
  /// shell, a repository script, or a package manager.
  public static let production = RepositoryPublishPreflightCommandRunner { command in
    RepositoryPublishPreflightProcessRunner.run(command)
  }
}

private enum RepositoryPublishPreflightProcessRunner {
  static func run(_ command: RepositoryPublishPreflightCommand)
    -> RepositoryPublishPreflightCommandResult
  {
    guard command.executablePath.hasPrefix("/") else {
      return .init(termination: .launchFailed, standardError: "工具路径不是绝对路径。")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executablePath)
    process.arguments = command.arguments
    process.currentDirectoryURL = URL(
      fileURLWithPath: command.workingDirectoryPath, isDirectory: true)
    process.environment = LocalSitePreviewProcessService.launchEnvironment()

    let collector = RepositoryPublishPreflightOutputCollector(
      maximumBytes: command.maximumOutputBytes)
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    outputPipe.fileHandleForReading.readabilityHandler = { collector.append($0.availableData) }
    errorPipe.fileHandleForReading.readabilityHandler = { collector.append($0.availableData) }
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }

    do {
      try process.run()
    } catch {
      outputPipe.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
      return .init(termination: .launchFailed, standardError: "无法启动 Zola。")
    }

    let waitResult = exited.wait(timeout: .now() + command.timeout)
    if waitResult == .timedOut {
      process.terminate()
      _ = exited.wait(timeout: .now() + 2)
      outputPipe.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
      return .init(termination: .timedOut, standardOutput: collector.snapshot.text)
    }
    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
    let collectedOutput = collector.snapshot
    if collectedOutput.wasTruncated {
      return .init(
        termination: .outputTruncated, exitStatus: process.terminationStatus,
        standardOutput: collectedOutput.text)
    }
    return .init(
      termination: .exited,
      exitStatus: process.terminationStatus,
      standardOutput: collectedOutput.text
    )
  }
}

private struct RepositoryPublishPreflightOutputState {
  var data = Data()
  var wasTruncated = false
}

private final class RepositoryPublishPreflightOutputCollector: Sendable {
  private let maximumBytes: Int
  private let state = OSAllocatedUnfairLock(initialState: RepositoryPublishPreflightOutputState())

  init(maximumBytes: Int) {
    self.maximumBytes = maximumBytes
  }

  func append(_ chunk: Data) {
    state.withLock { state in
      guard !state.wasTruncated else { return }
      let remaining = maximumBytes - state.data.count
      guard remaining > 0 else {
        state.wasTruncated = true
        return
      }
      state.data.append(chunk.prefix(remaining))
      if chunk.count > remaining { state.wasTruncated = true }
    }
  }

  var snapshot: (text: String, wasTruncated: Bool) {
    state.withLock {
      (String(decoding: $0.data, as: UTF8.self), $0.wasTruncated)
    }
  }
}
