import Foundation

#if canImport(Darwin)
  import Darwin
#endif

public struct GitCommandResult: Sendable, Hashable {
  public var terminationStatus: Int32
  /// Standard output preserved separately for callers that parse Git's
  /// machine-readable output. Use `output` for diagnostics and logs because
  /// this field intentionally retains the raw command output.
  public var standardOutput: String
  /// Standard error preserved separately for diagnostics after sensitive
  /// values have been redacted.
  public var standardError: String
  /// Combined, reader-facing diagnostic output retained for source
  /// compatibility with existing callers.
  public var output: String
  public var didTimeOut: Bool
  public var wasOutputTruncated: Bool

  /// Source-compatible initializer for callers that previously supplied one
  /// combined output string. The value is treated as standard output.
  public init(
    terminationStatus: Int32,
    output: String,
    didTimeOut: Bool = false,
    wasOutputTruncated: Bool = false
  ) {
    self.terminationStatus = terminationStatus
    self.standardOutput = output
    self.standardError = ""
    self.output = GitCommandLogRedactor.redactedDiagnosticText(output)
    self.didTimeOut = didTimeOut
    self.wasOutputTruncated = wasOutputTruncated
  }

  public init(
    terminationStatus: Int32,
    standardOutput: String,
    standardError: String,
    didTimeOut: Bool = false,
    wasOutputTruncated: Bool = false
  ) {
    self.terminationStatus = terminationStatus
    self.standardOutput = standardOutput
    self.standardError = GitCommandLogRedactor.redactedDiagnosticText(standardError)
    self.output = GitCommandLogRedactor.redactedDiagnosticText(
      Self.combinedDiagnosticOutput(
        standardOutput: standardOutput,
        standardError: self.standardError
      )
    )
    self.didTimeOut = didTimeOut
    self.wasOutputTruncated = wasOutputTruncated
  }

  fileprivate init(
    terminationStatus: Int32,
    standardOutput: String,
    standardError: String,
    diagnosticOutput: String,
    didTimeOut: Bool,
    wasOutputTruncated: Bool
  ) {
    self.terminationStatus = terminationStatus
    self.standardOutput = standardOutput
    self.standardError = GitCommandLogRedactor.redactedDiagnosticText(standardError)
    self.output = GitCommandLogRedactor.redactedDiagnosticText(diagnosticOutput)
    self.didTimeOut = didTimeOut
    self.wasOutputTruncated = wasOutputTruncated
  }

  private static func combinedDiagnosticOutput(
    standardOutput: String,
    standardError: String
  ) -> String {
    [standardOutput, standardError]
      .map(\.trimmedForPublishing)
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }
}

public enum GitCommandInputDelimiter: String, Sendable {
  case newline = "\n"
  case nul = "\0"
}

public struct GitCommandRunner: Sendable {
  public var executableURL: URL
  public var timeout: TimeInterval
  /// Total stdout + stderr retained for diagnostics. Streams are still drained
  /// after this cap so a noisy child process cannot block on full pipes.
  public var maximumOutputBytes: Int

  public init(
    executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
    timeout: TimeInterval = 15,
    maximumOutputBytes: Int = 1_048_576
  ) {
    self.executableURL = executableURL
    self.timeout = timeout
    self.maximumOutputBytes = max(0, maximumOutputBytes)
  }

  /// Returns a copyable Git command description with URLs, user info, token
  /// flags, authorization headers, and local home-directory usernames removed.
  /// The description is for diagnostics only and must not be used to execute
  /// the command.
  public static func redactedCommandDescription(_ arguments: [String]) -> String {
    GitCommandLogRedactor.redactedCommandDescription(arguments)
  }

  /// Redacts sensitive values from Git output before it is shown or persisted
  /// as a diagnostic. Machine-readable stdout remains available separately.
  public static func redactedDiagnosticText(_ text: String) -> String {
    GitCommandLogRedactor.redactedDiagnosticText(text)
  }

  @available(
    *, noasync,
    message: "Use runAsync instead in async contexts to avoid blocking cooperative thread pool"
  )
  public func run(
    _ arguments: [String],
    rootURL: URL,
    inputLines: [String]? = nil,
    inputDelimiter: GitCommandInputDelimiter = .newline
  ) -> GitCommandResult {
    if let reason = Self.repositoryConfigurationBlockReason(rootURL: rootURL) {
      return Self.blockedConfigurationResult(reason)
    }
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["-C", rootURL.path] + arguments
    process.environment = Self.isolatedGitEnvironment()

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    let outputCollector = BoundedOutputCollector(limit: maximumOutputBytes)
    let drainCoordinator = GitPipeDrainCoordinator()
    installDrainHandler(
      on: outputPipe.fileHandleForReading,
      stream: .standardOutput,
      collector: outputCollector,
      coordinator: drainCoordinator
    )
    installDrainHandler(
      on: errorPipe.fileHandleForReading,
      stream: .standardError,
      collector: outputCollector,
      coordinator: drainCoordinator
    )

    let inputData = standardInputData(
      lines: inputLines,
      delimiter: inputDelimiter
    )
    let inputPipe = Pipe()
    if inputData != nil {
      process.standardInput = inputPipe
    }

    let completed = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
      completed.signal()
    }

    do {
      try process.run()
      // Process owns duplicated write descriptors after launch. Closing our
      // copies lets the drainers observe EOF as soon as Git exits.
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe.fileHandleForWriting.closeFile()
      if let inputData {
        inputPipe.fileHandleForWriting.write(inputData)
        inputPipe.fileHandleForWriting.closeFile()
      }
    } catch {
      outputPipe.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil
      drainCoordinator.stopAndWait()
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe.fileHandleForWriting.closeFile()
      return GitCommandResult(
        terminationStatus: 127,
        standardOutput: "",
        standardError: error.localizedDescription
      )
    }

    let didFinish = completed.wait(timeout: .now() + timeout) == .success
    if !didFinish {
      process.terminate()
      if completed.wait(timeout: .now() + 1) == .timedOut {
        #if canImport(Darwin)
          Darwin.kill(process.processIdentifier, SIGKILL)
        #endif
        _ = completed.wait(timeout: .now() + 1)
      }
    }

    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
    drainCoordinator.stopAndWait()
    if !process.isRunning {
      outputCollector.append(
        outputPipe.fileHandleForReading.readDataToEndOfFile(),
        to: .standardOutput
      )
      outputCollector.append(
        errorPipe.fileHandleForReading.readDataToEndOfFile(),
        to: .standardError
      )
    }
    outputPipe.fileHandleForReading.closeFile()
    errorPipe.fileHandleForReading.closeFile()

    let collected = outputCollector.result()
    let standardOutput = collected.standardOutput.trimmedForPublishing
    let standardError = Self.redactedDiagnosticText(
      collected.standardError.trimmedForPublishing
    )
    let statusMessage =
      didFinish
      ? nil
      : "Git command timed out after \(Int(timeout))s: \(Self.redactedCommandDescription(arguments))"
    return GitCommandResult(
      terminationStatus: didFinish ? process.terminationStatus : 124,
      standardOutput: standardOutput,
      standardError: standardError,
      diagnosticOutput: diagnosticOutput(
        statusMessage: statusMessage,
        standardOutput: standardOutput,
        standardError: standardError,
        didTruncate: collected.didTruncate
      ),
      didTimeOut: !didFinish,
      wasOutputTruncated: collected.didTruncate
    )
  }

  /// Runs Git without occupying the caller's executor while the child process
  /// is active. Cancelling the awaiting task terminates the child process.
  public func runAsync(
    _ arguments: [String],
    rootURL: URL,
    inputLines: [String]? = nil,
    inputDelimiter: GitCommandInputDelimiter = .newline
  ) async -> GitCommandResult {
    if let reason = Self.repositoryConfigurationBlockReason(rootURL: rootURL) {
      return Self.blockedConfigurationResult(reason)
    }
    let operation = GitCommandAsyncOperation(
      executableURL: executableURL,
      timeout: timeout,
      maximumOutputBytes: maximumOutputBytes,
      arguments: arguments,
      rootURL: rootURL,
      inputData: standardInputData(
        lines: inputLines,
        delimiter: inputDelimiter
      )
    )
    return await withTaskCancellationHandler(
      operation: {
        await operation.run()
      },
      onCancel: {
        operation.cancel()
      })
  }

  private func installDrainHandler(
    on handle: FileHandle,
    stream: GitOutputStream,
    collector: BoundedOutputCollector,
    coordinator: GitPipeDrainCoordinator
  ) {
    handle.readabilityHandler = { readableHandle in
      coordinator.perform {
        let data = readableHandle.availableData
        if data.isEmpty {
          readableHandle.readabilityHandler = nil
        } else {
          collector.append(data, to: stream)
        }
      }
    }
  }

  private func diagnosticOutput(
    statusMessage: String?,
    standardOutput: String,
    standardError: String,
    didTruncate: Bool
  ) -> String {
    var chunks = [statusMessage, standardOutput.nilIfEmpty, standardError.nilIfEmpty]
      .compactMap { $0 }
    if didTruncate {
      chunks.append("[Git output truncated after \(maximumOutputBytes) bytes]")
    }
    return chunks.joined(separator: "\n")
  }

  private func standardInputData(
    lines: [String]?,
    delimiter: GitCommandInputDelimiter
  ) -> Data? {
    guard let lines, !lines.isEmpty else {
      return nil
    }
    return Data(
      (lines.joined(separator: delimiter.rawValue) + delimiter.rawValue).utf8
    )
  }

  /// Git consults repository-local configuration before running commands.
  /// Supplying this highest-precedence environment config disables the
  /// fsmonitor command and hooks from an untrusted .git/config while
  private static let cachedIsolatedGitEnvironment: [String: String] = {
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_COUNT"] = "5"
    environment["GIT_CONFIG_KEY_0"] = "core.fsmonitor"
    environment["GIT_CONFIG_VALUE_0"] = "false"
    environment["GIT_CONFIG_KEY_1"] = "core.hooksPath"
    environment["GIT_CONFIG_VALUE_1"] = "/dev/null"
    environment["GIT_CONFIG_KEY_2"] = "commit.gpgSign"
    environment["GIT_CONFIG_VALUE_2"] = "false"
    environment["GIT_CONFIG_KEY_3"] = "tag.gpgSign"
    environment["GIT_CONFIG_VALUE_3"] = "false"
    environment["GIT_CONFIG_KEY_4"] = "log.showSignature"
    environment["GIT_CONFIG_VALUE_4"] = "false"
    environment["GIT_EDITOR"] = "/usr/bin/false"
    environment["GIT_SEQUENCE_EDITOR"] = "/usr/bin/false"
    environment["GIT_PAGER"] = "/usr/bin/cat"
    return environment
  }()

  /// Returns environment variables configured to run Git without invoking
  /// arbitrary repository hook scripts or interactive prompts, while
  /// preserving benign repository metadata such as branch and remote
  /// configuration. `/dev/null` is intentionally used as a non-directory
  /// hooks root so post-commit hooks are skipped as well as pre-commit hooks.
  static func isolatedGitEnvironment() -> [String: String] {
    cachedIsolatedGitEnvironment
  }

  private static func blockedConfigurationResult(_ reason: String) -> GitCommandResult {
    GitCommandResult(
      terminationStatus: 126,
      standardOutput: "",
      standardError: "Git command blocked: \(reason)"
    )
  }

  /// Returns a reason to fail closed when repository-local configuration can
  /// turn an otherwise read/write Git operation into an external command.
  /// This intentionally parses the files directly: invoking `git config` to
  /// inspect them would first honor the same include and executable settings
  /// that this gate is meant to protect.
  private static func repositoryConfigurationBlockReason(rootURL: URL) -> String? {
    let fileManager = FileManager.default
    let root = rootURL.standardizedFileURL
    let gitEntryURL = root.appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: gitEntryURL.path, isDirectory: &isDirectory) else {
      return nil
    }
    guard !isSymbolicLink(gitEntryURL) else {
      return "Git 元数据入口是符号链接"
    }

    let gitDirectoryURL: URL
    if isDirectory.boolValue {
      gitDirectoryURL = gitEntryURL
    } else {
      guard let pointer = boundedUTF8String(at: gitEntryURL),
        !pointer.contains("\0"),
        pointer.components(separatedBy: .newlines).count <= 2
      else {
        return "Git 工作树元数据指针无效或超过大小限制"
      }
      let trimmedPointer = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
      let prefix = "gitdir:"
      guard trimmedPointer.lowercased().hasPrefix(prefix) else {
        return "Git 工作树元数据指针无效"
      }
      let path = String(trimmedPointer.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !path.isEmpty, !path.contains("\0") else {
        return "Git 工作树元数据指针为空"
      }
      gitDirectoryURL = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
    }

    var configurationURLs = [
      gitDirectoryURL.appendingPathComponent("config"),
      gitDirectoryURL.appendingPathComponent("config.worktree"),
    ]

    let commondirURL = gitDirectoryURL.appendingPathComponent("commondir")
    if fileManager.fileExists(atPath: commondirURL.path) {
      guard !isSymbolicLink(commondirURL),
        let pointer = boundedUTF8String(at: commondirURL),
        !pointer.contains("\0"),
        pointer.components(separatedBy: .newlines).count <= 2
      else {
        return "Git commondir 指针无效或超过大小限制"
      }
      let commonPath = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !commonPath.isEmpty else {
        return "Git commondir 指针为空"
      }
      let commonDirectoryURL = URL(
        fileURLWithPath: commonPath,
        relativeTo: gitDirectoryURL
      ).standardizedFileURL
      configurationURLs.append(commonDirectoryURL.appendingPathComponent("config"))
      configurationURLs.append(commonDirectoryURL.appendingPathComponent("config.worktree"))
    }

    var visitedPaths = Set<String>()
    for configurationURL in configurationURLs {
      guard visitedPaths.insert(configurationURL.path).inserted else { continue }
      guard fileManager.fileExists(atPath: configurationURL.path) else { continue }
      guard !isSymbolicLink(configurationURL) else {
        return "Git 配置文件是符号链接：\(configurationURL.lastPathComponent)"
      }
      guard let configuration = boundedUTF8String(at: configurationURL) else {
        return "Git 配置文件无法安全读取或超过大小限制：\(configurationURL.lastPathComponent)"
      }
      if let reason = blockedConfigurationReason(
        in: configuration,
        fileName: configurationURL.lastPathComponent
      ) {
        return reason
      }
    }
    return nil
  }

  private static func boundedUTF8String(at url: URL) -> String? {
    try? BoundedFileReader.utf8String(
      at: url,
      maximumByteCount: 1_024 * 1_024
    )
  }

  private static func isSymbolicLink(_ url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private static func blockedConfigurationReason(
    in configuration: String,
    fileName: String
  ) -> String? {
    var section = ""
    var sectionDescriptor = ""
    let maximumLineByteCount = 16 * 1_024

    for rawLine in configuration.split(
      separator: "\n",
      omittingEmptySubsequences: false
    ) {
      let line = String(rawLine)
      guard line.utf8.count <= maximumLineByteCount else {
        return "Git 配置行超过大小限制：\(fileName)"
      }
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty,
        !trimmed.hasPrefix("#"),
        !trimmed.hasPrefix(";")
      else {
        continue
      }
      guard !trimmed.hasSuffix("\\") else {
        return "Git 配置不允许续行：\(fileName)"
      }

      if trimmed.hasPrefix("[") {
        guard trimmed.hasSuffix("]") else {
          return "Git 配置节格式无效：\(fileName)"
        }
        let body = trimmed.dropFirst().dropLast()
        guard
          let name = body.split(
            whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\"" }
          ).first,
          !name.isEmpty,
          name.utf8.count <= 256
        else {
          return "Git 配置节格式无效：\(fileName)"
        }
        sectionDescriptor = String(name).lowercased()
        section =
          sectionDescriptor.split(separator: ".", maxSplits: 1)
          .first
          .map(String.init) ?? sectionDescriptor
        if section == "include" || section.hasPrefix("includeif") {
          return "Git 配置禁止 include/includeIf：\(fileName)"
        }
        continue
      }

      let keyPart: Substring
      let value: String
      if let equalsIndex = trimmed.firstIndex(of: "=") {
        keyPart = trimmed[..<equalsIndex]
        value = String(trimmed[trimmed.index(after: equalsIndex)...])
      } else {
        keyPart = Substring(trimmed)
        value = "true"
      }
      let key = String(keyPart).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty,
        key.utf8.count <= 256,
        !key.contains("\0"),
        key.unicodeScalars.allSatisfy({
          CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }),
        !section.isEmpty
      else {
        return "Git 配置键格式无效：\(fileName)"
      }

      let lowercaseKey = key.lowercased()
      let normalizedValue =
        value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      switch section {
      case "core":
        if [
          "sshcommand",
          "gitproxy",
          "askpass",
          "attributesfile",
          "alternaterefscommand",
          "createobject",
          "worktree",
        ].contains(lowercaseKey) {
          return "Git 配置包含可执行 core 选项：core.\(key)"
        }
      case "diff":
        if ["external", "textconv", "command"].contains(lowercaseKey) {
          return "Git 配置包含可执行 diff 选项：diff.\(key)"
        }
      case "filter":
        if ["clean", "smudge", "process", "command"].contains(lowercaseKey) {
          return "Git 配置包含可执行 filter 选项：filter.*.\(key)"
        }
      case "merge":
        if lowercaseKey == "driver" {
          return "Git 配置包含外部 merge 驱动：merge.*.driver"
        }
      case "credential":
        if lowercaseKey == "helper" {
          return "Git 配置包含外部 credential helper"
        }
      case "gpg":
        if lowercaseKey == "program" {
          return "Git 配置包含外部签名程序"
        }
      case "remote":
        if ["uploadpack", "receivepack", "vcs"].contains(lowercaseKey) {
          return "Git 配置包含外部 remote 命令：remote.*.\(key)"
        }
        if ["url", "pushurl"].contains(lowercaseKey),
          isExecutableRemoteURL(normalizedValue)
        {
          return "Git 配置包含可执行 remote URL"
        }
      case "url":
        return "Git 配置禁止仓库级 URL 重写：\(sectionDescriptor)"
      case "protocol":
        return "Git 配置禁止仓库级协议覆盖：\(sectionDescriptor)"
      case "difftool", "mergetool", "browser", "man":
        if lowercaseKey == "cmd" {
          return "Git 配置包含外部工具命令：\(section).*.cmd"
        }
      case "interactive":
        if lowercaseKey == "difffilter" {
          return "Git 配置包含外部 interactive diff 过滤器"
        }
      case "submodule":
        if lowercaseKey == "update",
          normalizedValue.hasPrefix("!")
        {
          return "Git 配置包含外部 submodule 更新命令"
        }
      case "gc":
        if lowercaseKey == "recentobjectshook" {
          return "Git 配置包含外部 GC hook"
        }
      case "uploadpack":
        if lowercaseKey == "packobjectshook" {
          return "Git 配置包含外部 upload-pack hook"
        }
      case "tar":
        if lowercaseKey == "command" {
          return "Git 配置包含外部归档命令"
        }
      case "sendemail":
        if ["cccmd", "tocmd", "headercmd"].contains(lowercaseKey) {
          return "Git 配置包含外部 send-email 命令"
        }
      default:
        break
      }
    }
    return nil
  }

  private static func isExecutableRemoteURL(_ value: String) -> Bool {
    let lowercaseValue = value.lowercased()
    if lowercaseValue.hasPrefix("ext::") {
      return true
    }
    guard let schemeSeparator = lowercaseValue.range(of: "://") else {
      return lowercaseValue.range(
        of: #"^[a-z][a-z0-9+.-]*::"#,
        options: .regularExpression
      ) != nil
    }
    let scheme = lowercaseValue[..<schemeSeparator.lowerBound]
    return !["file", "git", "http", "https", "ssh"].contains(String(scheme))
  }
}

private final class GitCommandAsyncOperation: @unchecked Sendable {
  private let executableURL: URL
  private let timeout: TimeInterval
  private let maximumOutputBytes: Int
  private let arguments: [String]
  private let rootURL: URL
  private let inputData: Data?
  private let lock = NSLock()
  private let outputCollector: BoundedOutputCollector
  private let drainCoordinator = GitPipeDrainCoordinator()
  private var process: Process?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var timeoutTask: Task<Void, Never>?
  private var continuation: CheckedContinuation<GitCommandResult, Never>?
  private var didFinish = false
  private var didTimeOut = false
  private var wasCancelled = false

  init(
    executableURL: URL,
    timeout: TimeInterval,
    maximumOutputBytes: Int,
    arguments: [String],
    rootURL: URL,
    inputData: Data?
  ) {
    self.executableURL = executableURL
    self.timeout = timeout
    self.maximumOutputBytes = maximumOutputBytes
    self.arguments = arguments
    self.rootURL = rootURL
    self.inputData = inputData
    outputCollector = BoundedOutputCollector(limit: maximumOutputBytes)
  }

  func run() async -> GitCommandResult {
    await withCheckedContinuation { continuation in
      start(continuation)
    }
  }

  func cancel() {
    lock.lock()
    wasCancelled = true
    let process = self.process
    lock.unlock()
    terminate(process)
  }

  private func start(_ continuation: CheckedContinuation<GitCommandResult, Never>) {
    lock.lock()
    self.continuation = continuation
    let shouldCancel = wasCancelled
    lock.unlock()
    if shouldCancel {
      finish(terminationStatus: 130)
      return
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["-C", rootURL.path] + arguments
    process.environment = GitCommandRunner.isolatedGitEnvironment()

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    installDrainHandler(on: outputPipe.fileHandleForReading, stream: .standardOutput)
    installDrainHandler(on: errorPipe.fileHandleForReading, stream: .standardError)

    let inputPipe = Pipe()
    if inputData != nil {
      process.standardInput = inputPipe
    }
    process.terminationHandler = { [weak self] process in
      self?.finish(terminationStatus: process.terminationStatus)
    }

    lock.lock()
    self.process = process
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe
    let cancelAfterSetup = wasCancelled
    lock.unlock()

    do {
      try process.run()
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe.fileHandleForWriting.closeFile()
      if let inputData {
        inputPipe.fileHandleForWriting.write(inputData)
        inputPipe.fileHandleForWriting.closeFile()
      }
    } catch {
      finish(terminationStatus: 127, launchError: error.localizedDescription)
      return
    }

    if cancelAfterSetup {
      terminate(process)
      return
    }

    let timeoutTask = Task.detached { [weak self] in
      let nanoseconds = UInt64(max(0, self?.timeout ?? 0) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      self?.timeOut()
    }
    lock.lock()
    if didFinish {
      lock.unlock()
      timeoutTask.cancel()
    } else {
      self.timeoutTask = timeoutTask
      lock.unlock()
    }
  }

  private func timeOut() {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return
    }
    didTimeOut = true
    let process = self.process
    lock.unlock()
    terminate(process)
  }

  private func terminate(_ process: Process?) {
    guard let process, process.isRunning else { return }
    process.terminate()
    Task.detached {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard process.isRunning else { return }
      #if canImport(Darwin)
        Darwin.kill(process.processIdentifier, SIGKILL)
      #endif
    }
  }

  private func finish(terminationStatus: Int32, launchError: String? = nil) {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return
    }
    didFinish = true
    timeoutTask?.cancel()
    timeoutTask = nil
    let continuation = self.continuation
    self.continuation = nil
    let outputPipe = self.outputPipe
    let errorPipe = self.errorPipe
    self.outputPipe = nil
    self.errorPipe = nil
    let timedOut = didTimeOut
    let cancelled = wasCancelled
    lock.unlock()

    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    drainCoordinator.stopAndWait()
    if let outputPipe {
      outputCollector.append(
        outputPipe.fileHandleForReading.readDataToEndOfFile(),
        to: .standardOutput
      )
      outputPipe.fileHandleForReading.closeFile()
    }
    if let errorPipe {
      outputCollector.append(
        errorPipe.fileHandleForReading.readDataToEndOfFile(),
        to: .standardError
      )
      errorPipe.fileHandleForReading.closeFile()
    }

    let collected = outputCollector.result()
    let standardOutput = collected.standardOutput.trimmedForPublishing
    let standardError = GitCommandRunner.redactedDiagnosticText(
      collected.standardError.trimmedForPublishing
    )
    let statusMessage: String?
    if let launchError {
      statusMessage = launchError
    } else if timedOut {
      statusMessage =
        "Git command timed out after \(Int(timeout))s: \(GitCommandRunner.redactedCommandDescription(arguments))"
    } else if cancelled {
      statusMessage =
        "Git command canceled: \(GitCommandRunner.redactedCommandDescription(arguments))"
    } else {
      statusMessage = nil
    }
    continuation?.resume(
      returning: GitCommandResult(
        terminationStatus: timedOut ? 124 : (cancelled ? 130 : terminationStatus),
        standardOutput: standardOutput,
        standardError: standardError,
        diagnosticOutput: diagnosticOutput(
          statusMessage: statusMessage,
          standardOutput: standardOutput,
          standardError: standardError,
          didTruncate: collected.didTruncate
        ),
        didTimeOut: timedOut,
        wasOutputTruncated: collected.didTruncate
      ))
  }

  private func installDrainHandler(on handle: FileHandle, stream: GitOutputStream) {
    handle.readabilityHandler = { [weak self] readableHandle in
      guard let self else { return }
      self.drainCoordinator.perform {
        let data = readableHandle.availableData
        if data.isEmpty {
          readableHandle.readabilityHandler = nil
        } else {
          self.outputCollector.append(data, to: stream)
        }
      }
    }
  }

  private func diagnosticOutput(
    statusMessage: String?,
    standardOutput: String,
    standardError: String,
    didTruncate: Bool
  ) -> String {
    var chunks = [statusMessage, standardOutput.nilIfEmpty, standardError.nilIfEmpty]
      .compactMap { $0 }
    if didTruncate {
      chunks.append("[Git output truncated after \(maximumOutputBytes) bytes]")
    }
    return chunks.joined(separator: "\n")
  }
}

private enum GitOutputStream {
  case standardOutput
  case standardError
}

/// Coordinates pipe callbacks with the final synchronous drain. Removing a
/// `readabilityHandler` does not cancel a callback that is already running. If
/// that callback has consumed the final bytes but has not appended them yet,
/// reading the collector immediately can lose short-lived command output.
private final class GitPipeDrainCoordinator: @unchecked Sendable {
  private let condition = NSCondition()
  private var acceptsNewDrains = true
  private var activeDrainCount = 0

  func perform(_ operation: () -> Void) {
    condition.lock()
    guard acceptsNewDrains else {
      condition.unlock()
      return
    }
    activeDrainCount += 1
    condition.unlock()

    operation()

    condition.lock()
    activeDrainCount -= 1
    if !acceptsNewDrains, activeDrainCount == 0 {
      condition.broadcast()
    }
    condition.unlock()
  }

  func stopAndWait() {
    condition.lock()
    acceptsNewDrains = false
    while activeDrainCount > 0 {
      condition.wait()
    }
    condition.unlock()
  }
}

private enum GitCommandLogRedactor {
  private static let urlPattern = #"(?i)\b(?:https?|ssh|git\+https?|git)://[^\s"'<>]+"#
  private static let scpRemotePattern =
    #"(?i)(?<![\w./])(?:[^@\s/:]+(?::[^@\s/:]+)?@)?(?:github\.com|gitlab\.com|bitbucket\.org|[a-z0-9.-]+\.[a-z]{2,}):[^\s"'<>]+"#
  private static let authorizationHeaderPattern =
    #"((?i:authorization|proxy-authorization)\s*:\s*(?:(?:bearer|basic|token)\s+))[^\s,;&]+"#
  private static let bearerPattern = #"(?i)\b(bearer|basic)(\s+)[A-Za-z0-9._~+/=-]+"#
  private static let optionValuePattern =
    #"(?i)(--?(?:access[-_]?token|auth[-_]?token|api[-_]?(?:key|token)|private[-_]?token|refresh[-_]?token|client[-_]?secret|password|passwd|secret|authorization|username|user|header|extra[-_]?header))(\s+)[^\s,;&]+"#
  private static let tokenAssignmentPattern = #"(?i)(token)(\s*=\s*)[^\s,;&]+"#
  private static let keyValuePattern =
    #"(?i)(\b(?:access[-_]?token|auth[-_]?token|api[-_]?(?:key|token)|private[-_]?token|refresh[-_]?token|client[-_]?secret|password|passwd|secret|authorization|proxy-authorization|username|user)\b\s*[:=]\s*)[^\s,;&]+"#
  private static let homeDirectoryPattern = #"((?:/Users|/home)/)[^/\s"'<>]+"#

  static func redactedCommandDescription(_ arguments: [String]) -> String {
    var redactedArguments: [String] = []
    var redactsNextArgument = false

    for argument in arguments {
      if redactsNextArgument {
        redactedArguments.append(posixShellQuote("[REDACTED]"))
        redactsNextArgument = false
        continue
      }

      if let equalsIndex = argument.firstIndex(of: "=") {
        let option = String(argument[..<equalsIndex])
        if isSensitiveOption(option) {
          redactedArguments.append(
            posixShellQuote("\(option)=[REDACTED]")
          )
          continue
        }
      }

      if isSensitiveOption(argument) {
        redactedArguments.append(posixShellQuote(argument))
        redactsNextArgument = true
        continue
      }

      redactedArguments.append(
        posixShellQuote(redactedDiagnosticText(argument))
      )
    }

    return (["git"] + redactedArguments).joined(separator: " ")
  }

  static func redactedDiagnosticText(_ text: String) -> String {
    var redacted = text
    redacted = replacingMatches(in: redacted, pattern: urlPattern) { raw, _ in
      redactedURLToken(raw)
    }
    redacted = replacingMatches(in: redacted, pattern: scpRemotePattern) { raw, _ in
      redactedSCPRemoteToken(raw)
    }
    redacted = replacingMatches(
      in: redacted,
      pattern: authorizationHeaderPattern
    ) { raw, match in
      "\(capture(raw, match: match, group: 1))[REDACTED]"
    }
    redacted = replacingMatches(in: redacted, pattern: bearerPattern) { raw, match in
      "\(capture(raw, match: match, group: 1))\(capture(raw, match: match, group: 2))[REDACTED]"
    }
    redacted = replacingMatches(in: redacted, pattern: optionValuePattern) { raw, match in
      "\(capture(raw, match: match, group: 1))\(capture(raw, match: match, group: 2))[REDACTED]"
    }
    redacted = replacingMatches(in: redacted, pattern: tokenAssignmentPattern) { raw, match in
      "\(capture(raw, match: match, group: 1))\(capture(raw, match: match, group: 2))[REDACTED]"
    }
    redacted = replacingMatches(in: redacted, pattern: keyValuePattern) { raw, match in
      "\(capture(raw, match: match, group: 1))[REDACTED]"
    }
    redacted = replacingMatches(in: redacted, pattern: homeDirectoryPattern) { raw, match in
      "\(capture(raw, match: match, group: 1))[REDACTED]"
    }
    return redacted
  }

  private static func isSensitiveOption(_ argument: String) -> Bool {
    if argument == "-H" {
      return true
    }
    let normalized =
      argument
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    let exactOptions: Set<String> = [
      "--token",
      "--access-token",
      "--auth-token",
      "--api-key",
      "--api-token",
      "--private-token",
      "--refresh-token",
      "--client-secret",
      "--password",
      "--passwd",
      "--secret",
      "--authorization",
      "--username",
      "--user",
      "--header",
      "--extra-header",
    ]
    return exactOptions.contains(normalized)
  }

  private static func redactedURLToken(_ raw: String) -> String {
    let (core, trailing) = splitTrailingPunctuation(raw)
    guard let components = URLComponents(string: core),
      components.host != nil
    else {
      return "[REDACTED_URL]\(trailing)"
    }
    var sanitized = components
    sanitized.user = nil
    sanitized.password = nil
    sanitized.query = nil
    sanitized.fragment = nil
    return "\(sanitized.string ?? "[REDACTED_URL]")\(trailing)"
  }

  private static func redactedSCPRemoteToken(_ raw: String) -> String {
    let (core, trailing) = splitTrailingPunctuation(raw)
    let sanitized =
      core.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
      .last
      .map(String.init) ?? core
    return "\(sanitized)\(trailing)"
  }

  private static func splitTrailingPunctuation(_ raw: String) -> (String, String) {
    var core = raw
    var trailing = ""
    while let last = core.last,
      ",.;:!?)]}".contains(last)
    {
      trailing.insert(last, at: trailing.startIndex)
      core.removeLast()
    }
    return (core, trailing)
  }

  private static func replacingMatches(
    in text: String,
    pattern: String,
    transform: (String, NSTextCheckingResult) -> String
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return text
    }
    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = regex.matches(in: text, range: fullRange)
    guard !matches.isEmpty else { return text }

    var result = text
    let source = text as NSString
    for match in matches.reversed() {
      let raw = source.substring(with: match.range)
      result = (result as NSString).replacingCharacters(
        in: match.range,
        with: transform(raw, match)
      )
    }
    return result
  }

  private static func capture(
    _ raw: String,
    match: NSTextCheckingResult,
    group: Int
  ) -> String {
    let absoluteRange = match.range(at: group)
    guard absoluteRange.location != NSNotFound else { return "" }
    let relativeRange = NSRange(
      location: absoluteRange.location - match.range.location,
      length: absoluteRange.length
    )
    guard relativeRange.location >= 0,
      NSMaxRange(relativeRange) <= (raw as NSString).length
    else {
      return ""
    }
    return (raw as NSString).substring(with: relativeRange)
  }
}

private final class BoundedOutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var standardOutput = Data()
  private var standardError = Data()
  private var didTruncate = false

  init(limit: Int) {
    self.limit = limit
  }

  func append(_ data: Data, to stream: GitOutputStream) {
    lock.lock()
    defer { lock.unlock() }
    let retainedByteCount = standardOutput.count + standardError.count
    let remaining = max(0, limit - retainedByteCount)
    if remaining > 0 {
      switch stream {
      case .standardOutput:
        standardOutput.append(data.prefix(remaining))
      case .standardError:
        standardError.append(data.prefix(remaining))
      }
    }
    if data.count > remaining {
      didTruncate = true
    }
  }

  func result() -> (standardOutput: String, standardError: String, didTruncate: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (
      String(data: standardOutput, encoding: .utf8) ?? "",
      String(data: standardError, encoding: .utf8) ?? "",
      didTruncate
    )
  }
}
