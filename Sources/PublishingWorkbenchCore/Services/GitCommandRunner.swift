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
    self.output = Self.combinedDiagnosticOutput(
      standardOutput: standardOutput,
      standardError: self.standardError
    )
    self.output = GitCommandLogRedactor.redactedDiagnosticText(self.output)
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

  public func run(
    _ arguments: [String],
    rootURL: URL,
    inputLines: [String]? = nil,
    inputDelimiter: GitCommandInputDelimiter = .newline
  ) -> GitCommandResult {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = ["-C", rootURL.path] + arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    let outputCollector = BoundedOutputCollector(limit: maximumOutputBytes)
    installDrainHandler(
      on: outputPipe.fileHandleForReading,
      stream: .standardOutput,
      collector: outputCollector
    )
    installDrainHandler(
      on: errorPipe.fileHandleForReading,
      stream: .standardError,
      collector: outputCollector
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
    let statusMessage = didFinish
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
    return await withTaskCancellationHandler(operation: {
      await operation.run()
    }, onCancel: {
      operation.cancel()
    })
  }

  private func installDrainHandler(
    on handle: FileHandle,
    stream: GitOutputStream,
    collector: BoundedOutputCollector
  ) {
    handle.readabilityHandler = { readableHandle in
      let data = readableHandle.availableData
      if data.isEmpty {
        readableHandle.readabilityHandler = nil
      } else {
        collector.append(data, to: stream)
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
      statusMessage = "Git command timed out after \(Int(timeout))s: \(GitCommandRunner.redactedCommandDescription(arguments))"
    } else if cancelled {
      statusMessage = "Git command canceled: \(GitCommandRunner.redactedCommandDescription(arguments))"
    } else {
      statusMessage = nil
    }
    continuation?.resume(returning: GitCommandResult(
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
      let data = readableHandle.availableData
      if data.isEmpty {
        readableHandle.readabilityHandler = nil
      } else {
        self?.outputCollector.append(data, to: stream)
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

private enum GitCommandLogRedactor {
  private static let urlPattern = #"(?i)\b(?:https?|ssh|git\+https?|git)://[^\s"'<>]+"#
  private static let scpRemotePattern = #"(?i)(?<![\w./])(?:[^@\s/:]+(?::[^@\s/:]+)?@)?(?:github\.com|gitlab\.com|bitbucket\.org|[a-z0-9.-]+\.[a-z]{2,}):[^\s"'<>]+"#
  private static let authorizationHeaderPattern = #"((?i:authorization|proxy-authorization)\s*:\s*(?:(?:bearer|basic|token)\s+))[^\s,;&]+"#
  private static let bearerPattern = #"(?i)\b(bearer|basic)(\s+)[A-Za-z0-9._~+/=-]+"#
  private static let optionValuePattern = #"(?i)(--?(?:access[-_]?token|auth[-_]?token|api[-_]?(?:key|token)|private[-_]?token|refresh[-_]?token|client[-_]?secret|password|passwd|secret|authorization|username|user|header|extra[-_]?header))(\s+)[^\s,;&]+"#
  private static let tokenAssignmentPattern = #"(?i)(token)(\s*=\s*)[^\s,;&]+"#
  private static let keyValuePattern = #"(?i)(\b(?:access[-_]?token|auth[-_]?token|api[-_]?(?:key|token)|private[-_]?token|refresh[-_]?token|client[-_]?secret|password|passwd|secret|authorization|proxy-authorization|username|user)\b\s*[:=]\s*)[^\s,;&]+"#
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
    let normalized = argument
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
          components.host != nil else {
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
    let sanitized = core.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
      .last
      .map(String.init) ?? core
    return "\(sanitized)\(trailing)"
  }

  private static func splitTrailingPunctuation(_ raw: String) -> (String, String) {
    var core = raw
    var trailing = ""
    while let last = core.last,
          ",.;:!?)]}".contains(last) {
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
          NSMaxRange(relativeRange) <= (raw as NSString).length else {
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
