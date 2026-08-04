import Darwin
import Foundation

public struct LocalWhisperProcessResult: Sendable {
  public var exitCode: Int32
  public var standardOutput: String
  public var standardError: String
  public var standardOutputWasTruncated: Bool
  public var standardErrorWasTruncated: Bool

  public init(
    exitCode: Int32,
    standardOutput: String,
    standardError: String,
    standardOutputWasTruncated: Bool = false,
    standardErrorWasTruncated: Bool = false
  ) {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.standardOutputWasTruncated = standardOutputWasTruncated
    self.standardErrorWasTruncated = standardErrorWasTruncated
  }
}

public protocol LocalWhisperProcessRunner: Sendable {
  func run(executableURL: URL, arguments: [String]) async throws -> LocalWhisperProcessResult
}

public enum LocalWhisperProcessRunnerError: LocalizedError, Equatable, Sendable {
  case timedOut(seconds: TimeInterval)
  case pipeReadFailed(String)

  public var errorDescription: String? {
    switch self {
    case let .timedOut(seconds):
      return "Whisper 进程运行超过 \(Int(seconds.rounded())) 秒，已终止。"
    case let .pipeReadFailed(message):
      return "Whisper 进程输出读取失败：\(message)"
    }
  }
}

public struct SystemLocalWhisperProcessRunner: LocalWhisperProcessRunner {
  public static let defaultTimeout: TimeInterval = 30 * 60
  public static let defaultMaximumStandardOutputByteCount = 4 * 1_024 * 1_024
  public static let defaultMaximumStandardErrorByteCount = 1 * 1_024 * 1_024

  private let timeout: TimeInterval
  private let terminationGracePeriod: TimeInterval
  private let maximumStandardOutputByteCount: Int
  private let maximumStandardErrorByteCount: Int

  public init(
    timeout: TimeInterval = Self.defaultTimeout,
    terminationGracePeriod: TimeInterval = 1,
    maximumStandardOutputByteCount: Int = Self.defaultMaximumStandardOutputByteCount,
    maximumStandardErrorByteCount: Int = Self.defaultMaximumStandardErrorByteCount
  ) {
    let finiteTimeout = timeout.isFinite ? timeout : Self.defaultTimeout
    let finiteGracePeriod = terminationGracePeriod.isFinite ? terminationGracePeriod : 1
    self.timeout = min(max(0.05, finiteTimeout), 24 * 60 * 60)
    self.terminationGracePeriod = min(max(0.05, finiteGracePeriod), 10)
    self.maximumStandardOutputByteCount = max(0, maximumStandardOutputByteCount)
    self.maximumStandardErrorByteCount = max(0, maximumStandardErrorByteCount)
  }

  public func run(
    executableURL: URL,
    arguments: [String]
  ) async throws -> LocalWhisperProcessResult {
    let terminationController = LocalWhisperTerminationController(
      gracePeriod: terminationGracePeriod
    )

    return try await withTaskCancellationHandler {
      try Task.checkCancellation()

      let outputPipe = Pipe()
      let errorPipe = Pipe()

      let outputTask = Task.detached(priority: .utility) {
        Self.readBounded(
          from: outputPipe.fileHandleForReading,
          maximumByteCount: maximumStandardOutputByteCount,
          keepingTail: false
        )
      }
      let errorTask = Task.detached(priority: .utility) {
        Self.readBounded(
          from: errorPipe.fileHandleForReading,
          maximumByteCount: maximumStandardErrorByteCount,
          keepingTail: true
        )
      }

      let processIdentifier: Int32
      do {
        processIdentifier = try Self.spawn(
          executableURL: executableURL,
          arguments: arguments,
          environment: Self.sanitizedEnvironment(),
          outputPipe: outputPipe,
          errorPipe: errorPipe
        )
      } catch {
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()
        _ = await outputTask.value
        _ = await errorTask.value
        try Task.checkCancellation()
        throw error
      }

      // Process receives duplicated descriptors. Closing the parent's write
      // descriptors lets both concurrent readers observe EOF after termination.
      outputPipe.fileHandleForWriting.closeFile()
      errorPipe.fileHandleForWriting.closeFile()
      terminationController.didLaunch(processIdentifier: processIdentifier)

      let exitCode: Int32
      do {
        exitCode = try await waitForTermination(
          processIdentifier: processIdentifier,
          controller: terminationController
        )
      } catch {
        // The task group waits for the termination waiter before unwinding, so
        // the pipe readers cannot be left blocked behind a live child process.
        _ = await outputTask.value
        _ = await errorTask.value
        try Task.checkCancellation()
        throw error
      }

      let output = await outputTask.value
      let error = await errorTask.value
      try Task.checkCancellation()
      if let failure = output.failureDescription ?? error.failureDescription {
        throw LocalWhisperProcessRunnerError.pipeReadFailed(failure)
      }
      return LocalWhisperProcessResult(
        exitCode: exitCode,
        standardOutput: String(decoding: output.data, as: UTF8.self),
        standardError: String(decoding: error.data, as: UTF8.self),
        standardOutputWasTruncated: output.wasTruncated,
        standardErrorWasTruncated: error.wasTruncated
      )
    } onCancel: {
      terminationController.requestTermination()
    }
  }

  private func waitForTermination(
    processIdentifier: Int32,
    controller: LocalWhisperTerminationController
  ) async throws -> Int32 {
    try await withThrowingTaskGroup(of: Int32.self) { group in
      group.addTask {
        try await Task.detached(priority: .utility) {
          try Self.waitForExit(processIdentifier: processIdentifier)
        }.value
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        try Task.checkCancellation()
        throw LocalWhisperProcessRunnerError.timedOut(seconds: timeout)
      }

      do {
        guard let result = try await group.next() else {
          throw CancellationError()
        }
        controller.didTerminate()
        group.cancelAll()
        return result
      } catch {
        controller.requestTermination()
        group.cancelAll()
        throw error
      }
    }
  }

  private static func spawn(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    outputPipe: Pipe,
    errorPipe: Pipe
  ) throws -> Int32 {
    let executablePath = executableURL.path
    let argumentStrings = [executablePath] + arguments
    let environmentStrings = environment
      .map { "\($0.key)=\($0.value)" }
      .sorted()
    guard (argumentStrings + environmentStrings).allSatisfy({ !$0.utf8.contains(0) }) else {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(EINVAL),
        userInfo: [NSLocalizedDescriptionKey: "Whisper 启动参数包含无效的空字符。"]
      )
    }

    var fileActions: posix_spawn_file_actions_t?
    try checkPOSIX(posix_spawn_file_actions_init(&fileActions))
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    let outputReadDescriptor = outputPipe.fileHandleForReading.fileDescriptor
    let outputWriteDescriptor = outputPipe.fileHandleForWriting.fileDescriptor
    let errorReadDescriptor = errorPipe.fileHandleForReading.fileDescriptor
    let errorWriteDescriptor = errorPipe.fileHandleForWriting.fileDescriptor
    try checkPOSIX(posix_spawn_file_actions_addopen(
      &fileActions,
      STDIN_FILENO,
      "/dev/null",
      O_RDONLY,
      0
    ))
    try checkPOSIX(posix_spawn_file_actions_adddup2(
      &fileActions,
      outputWriteDescriptor,
      STDOUT_FILENO
    ))
    try checkPOSIX(posix_spawn_file_actions_adddup2(
      &fileActions,
      errorWriteDescriptor,
      STDERR_FILENO
    ))
    for descriptor in [
      outputReadDescriptor,
      outputWriteDescriptor,
      errorReadDescriptor,
      errorWriteDescriptor,
    ] where descriptor != STDIN_FILENO
      && descriptor != STDOUT_FILENO
      && descriptor != STDERR_FILENO {
      try checkPOSIX(posix_spawn_file_actions_addclose(&fileActions, descriptor))
    }

    var attributes: posix_spawnattr_t?
    try checkPOSIX(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try checkPOSIX(posix_spawnattr_setpgroup(&attributes, 0))
    try checkPOSIX(posix_spawnattr_setflags(
      &attributes,
      Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    ))

    var processIdentifier: Int32 = 0
    let spawnStatus = withMutableCStringArray(argumentStrings) { argumentPointers in
      withMutableCStringArray(environmentStrings) { environmentPointers in
        executablePath.withCString { executablePointer in
          posix_spawn(
            &processIdentifier,
            executablePointer,
            &fileActions,
            &attributes,
            argumentPointers,
            environmentPointers
          )
        }
      }
    }
    try checkPOSIX(spawnStatus)
    return processIdentifier
  }

  private static func waitForExit(processIdentifier: Int32) throws -> Int32 {
    var status: Int32 = 0
    while Darwin.waitpid(processIdentifier, &status, 0) == -1 {
      if errno == EINTR { continue }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let terminatingSignal = status & 0x7F
    if terminatingSignal == 0 {
      return (status >> 8) & 0xFF
    }
    return 128 + terminatingSignal
  }

  private static func checkPOSIX(_ status: Int32) throws {
    guard status != 0 else { return }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(status))
  }

  private static func withMutableCStringArray<Result>(
    _ strings: [String],
    body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
  ) -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer {
      for pointer in pointers where pointer != nil {
        free(pointer)
      }
    }
    return pointers.withUnsafeMutableBufferPointer { buffer in
      body(buffer.baseAddress!)
    }
  }

  private static func sanitizedEnvironment() -> [String: String] {
    [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "LANG": "en_US.UTF-8",
      "LC_ALL": "en_US.UTF-8",
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "TMPDIR": FileManager.default.temporaryDirectory.path,
    ]
  }

  private static func readBounded(
    from handle: FileHandle,
    maximumByteCount: Int,
    keepingTail: Bool
  ) -> LocalWhisperBoundedReadResult {
    var captured = Data()
    var wasTruncated = false
    var failureDescription: String?
    defer { try? handle.close() }

    while true {
      do {
        guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else {
          break
        }
        if keepingTail {
          captured.append(chunk)
          if captured.count > maximumByteCount {
            captured.removeFirst(captured.count - maximumByteCount)
            wasTruncated = true
          }
        } else {
          let remainingByteCount = max(0, maximumByteCount - captured.count)
          if remainingByteCount > 0 {
            captured.append(contentsOf: chunk.prefix(remainingByteCount))
          }
          if chunk.count > remainingByteCount {
            wasTruncated = true
          }
        }
      } catch {
        failureDescription = error.localizedDescription
        break
      }
    }
    return LocalWhisperBoundedReadResult(
      data: captured,
      wasTruncated: wasTruncated,
      failureDescription: failureDescription
    )
  }
}

private struct LocalWhisperBoundedReadResult: Sendable {
  var data: Data
  var wasTruncated: Bool
  var failureDescription: String?
}

private final class LocalWhisperTerminationController: @unchecked Sendable {
  private let lock = NSLock()
  private let gracePeriod: TimeInterval
  private var hasLaunched = false
  private var hasTerminated = false
  private var terminationRequested = false
  private var sentTerminationSignal = false
  private var processIdentifier: Int32?

  init(gracePeriod: TimeInterval) {
    self.gracePeriod = gracePeriod
  }

  func didLaunch(processIdentifier: Int32) {
    lock.lock()
    hasLaunched = true
    self.processIdentifier = processIdentifier
    let shouldTerminate = terminationRequested && !hasTerminated && !sentTerminationSignal
    if shouldTerminate {
      sentTerminationSignal = true
    }
    lock.unlock()
    if shouldTerminate {
      sendTerminationSignal()
    }
  }

  func didTerminate() {
    lock.lock()
    hasTerminated = true
    lock.unlock()
  }

  func requestTermination() {
    lock.lock()
    terminationRequested = true
    let shouldTerminate = hasLaunched && !hasTerminated && !sentTerminationSignal
    if shouldTerminate {
      sentTerminationSignal = true
    }
    lock.unlock()
    if shouldTerminate {
      sendTerminationSignal()
    }
  }

  private func sendTerminationSignal() {
    lock.lock()
    let processIdentifier = processIdentifier
    lock.unlock()
    guard let processIdentifier, processIdentifier > 0 else { return }
    Darwin.kill(-processIdentifier, SIGTERM)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gracePeriod) { [weak self] in
      self?.forceKillIfNeeded()
    }
  }

  private func forceKillIfNeeded() {
    lock.lock()
    let shouldForceKill = hasLaunched && terminationRequested
    let processIdentifier = processIdentifier
    lock.unlock()
    guard shouldForceKill, let processIdentifier, processIdentifier > 0 else { return }
    // The direct process may have already exited while a descendant ignores
    // SIGTERM. Signalling the group still guarantees bounded cancellation.
    Darwin.kill(-processIdentifier, SIGKILL)
  }
}

public enum LocalWhisperTranscriptionError: LocalizedError, Equatable, Sendable {
  case invalidConfiguration(String)
  case audioUnavailable
  case audioTooLarge
  case processTimedOut
  case processFailed(String)
  case transcriptUnavailable
  case transcriptTooLarge

  public var errorDescription: String? {
    switch self {
    case let .invalidConfiguration(message):
      return message
    case .audioUnavailable:
      return "音频文件不可读取。"
    case .audioTooLarge:
      return "音频文件超过本地转写上限（512 MiB）。"
    case .processTimedOut:
      return "本地 Whisper 转写超时，进程已停止。"
    case let .processFailed(message):
      return "本地 Whisper 转写失败：\(message)"
    case .transcriptUnavailable:
      return "Whisper 没有生成可用的转写文本。"
    case .transcriptTooLarge:
      return "转写文本超过单次插入上限。"
    }
  }
}

/// Runs a local whisper.cpp-compatible CLI. It never sends audio to a remote
/// service and only keeps the generated text in the caller's process.
public struct LocalWhisperTranscriptionService: Sendable {
  public static let maximumAudioByteCount: Int64 = 512 * 1_024 * 1_024
  public static let maximumTranscriptUTF8Count = 2 * 1_024 * 1_024

  private let processRunner: any LocalWhisperProcessRunner

  public init(
    processRunner: any LocalWhisperProcessRunner = SystemLocalWhisperProcessRunner()
  ) {
    self.processRunner = processRunner
  }

  public func transcribe(
    audioURL: URL,
    configuration: LocalWhisperConfiguration
  ) async throws -> LocalWhisperTranscriptionResult {
    guard configuration.isConfigured else {
      throw LocalWhisperTranscriptionError.invalidConfiguration(
        "请先选择 whisper-cli/whisper.cpp 可执行文件和本地模型。"
      )
    }
    let executableURL = URL(fileURLWithPath: configuration.executablePath)
    let modelURL = URL(fileURLWithPath: configuration.modelPath)
    let sourceURL = audioURL.standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: executableURL.path),
          FileManager.default.isReadableFile(atPath: modelURL.path) else {
      throw LocalWhisperTranscriptionError.invalidConfiguration(
        "Whisper 可执行文件或模型文件不可用。"
      )
    }
    guard FileManager.default.isReadableFile(atPath: sourceURL.path),
          let resourceValues = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]),
          let size = resourceValues.fileSize else {
      throw LocalWhisperTranscriptionError.audioUnavailable
    }
    guard Int64(size) <= Self.maximumAudioByteCount else {
        throw LocalWhisperTranscriptionError.audioTooLarge
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepoPress-Whisper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputBaseURL = directory.appendingPathComponent("transcript")
    let language = configuration.language.trimmedForPublishing.nilIfEmpty ?? "auto"
    let arguments = [
      "-m", modelURL.path,
      "-f", sourceURL.path,
      "-l", language,
      "-nt",
      "-otxt",
      "-of", outputBaseURL.path,
    ]
    let processResult: LocalWhisperProcessResult
    do {
      processResult = try await processRunner.run(
        executableURL: executableURL,
        arguments: arguments
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch LocalWhisperProcessRunnerError.timedOut {
      throw LocalWhisperTranscriptionError.processTimedOut
    }
    guard processResult.exitCode == 0 else {
      let errorText = processResult.standardError
        .split(whereSeparator: \.isNewline)
        .suffix(3)
        .joined(separator: " ")
        .prefix(500)
      throw LocalWhisperTranscriptionError.processFailed(
        String(errorText).nilIfEmpty ?? "进程退出码 \(processResult.exitCode)"
      )
    }

    let outputURL = outputBaseURL.appendingPathExtension("txt")
    let outputText = try transcriptText(
      at: outputURL,
      fallback: processResult.standardOutput
    )
    let normalizedText = outputText
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
      .trimmedForPublishing
    guard !normalizedText.isEmpty else {
      throw LocalWhisperTranscriptionError.transcriptUnavailable
    }
    guard normalizedText.utf8.count <= Self.maximumTranscriptUTF8Count else {
      throw LocalWhisperTranscriptionError.transcriptTooLarge
    }
    return LocalWhisperTranscriptionResult(
      text: normalizedText,
      language: language,
      executableName: executableURL.lastPathComponent
    )
  }

  private func transcriptText(at outputURL: URL, fallback: String) throws -> String {
    guard FileManager.default.fileExists(atPath: outputURL.path) else {
      return fallback
    }
    do {
      return try BoundedFileReader.utf8String(
        at: outputURL,
        maximumByteCount: Self.maximumTranscriptUTF8Count
      )
    } catch BoundedFileReadError.exceedsByteLimit {
      throw LocalWhisperTranscriptionError.transcriptTooLarge
    } catch {
      throw LocalWhisperTranscriptionError.transcriptUnavailable
    }
  }
}
