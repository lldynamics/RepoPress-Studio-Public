import Darwin
import Dispatch
import Foundation

/// Runs one untrusted `codex --version` process behind strict time and output
/// bounds. The probe owns the complete lifecycle so cancellation cannot leave
/// a waiter or child process behind.
final class CodexRuntimeVersionProbe: @unchecked Sendable {
  private static let maximumOutputByteCount = 4_096
  private static let maximumReturnedCharacterCount = 256
  private static let forceKillDelay: Duration = .milliseconds(100)

  private enum StopReason {
    case cancelled
    case outputLimit
    case timedOut
  }

  private let executableURL: URL
  private let expectedExecutableIdentity: CodexExecutableIdentity?
  private let outputPipe = Pipe()
  private let errorPipe = Pipe()
  private let lock = NSLock()
  private let processDidLaunch: (@Sendable (pid_t) -> Void)?

  private var output = Data()
  private var continuation: CheckedContinuation<String?, Never>?
  private var completedResult: String??
  private var timeoutTask: Task<Void, Never>?
  private var processTerminated = false
  private var stdoutReachedEnd = false
  private var terminationStatus: Int32?
  private var stopReason: StopReason?
  private var stopRequested = false
  private var terminationRequested = false
  private var readersClosed = false
  private var processIdentifier: pid_t?

  init(
    executableURL: URL,
    expectedExecutableIdentity: CodexExecutableIdentity? = nil,
    processDidLaunch: (@Sendable (pid_t) -> Void)? = nil
  ) {
    self.executableURL = executableURL
    self.expectedExecutableIdentity = expectedExecutableIdentity
    self.processDidLaunch = processDidLaunch
  }

  func run(timeout: Duration) async -> String? {
    if let expectedExecutableIdentity,
      CodexExecutableIdentity.capture(executableURL: executableURL)?.identity
        != expectedExecutableIdentity
    {
      finishLaunchFailure()
      return nil
    }
    let launchedProcessIdentifier: pid_t
    do {
      launchedProcessIdentifier = try launchProcess()
    } catch {
      finishLaunchFailure()
      return nil
    }
    let stopWasRequestedBeforePublication = lock.withLock {
      processIdentifier = launchedProcessIdentifier
      return stopRequested
    }
    monitorLeader(launchedProcessIdentifier)
    if let expectedExecutableIdentity,
      CodexExecutableIdentity.capture(executableURL: executableURL)?.identity
        != expectedExecutableIdentity
    {
      stop(.cancelled)
      return await result()
    }
    if !stopWasRequestedBeforePublication {
      // Reader callbacks are installed only after the PID is published. This
      // makes every output-limit stop able to terminate and reap its process
      // group instead of leaving cleanup waiting on a missing identifier.
      configureReaders()
    }
    processDidLaunch?(launchedProcessIdentifier)
    if stopWasRequestedBeforePublication {
      requestProcessGroupCleanup(launchedProcessIdentifier)
    }

    let timeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      self?.stop(.timedOut)
    }
    let didAlreadyComplete = lock.withLock {
      if completedResult != nil {
        return true
      }
      self.timeoutTask = timeoutTask
      return false
    }
    if didAlreadyComplete {
      timeoutTask.cancel()
    }

    return await withTaskCancellationHandler {
      await result()
    } onCancel: {
      self.stop(.cancelled)
    }
  }

  private func configureReaders() {
    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.consumeOutput(handle.availableData)
    }
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      // Diagnostics are intentionally discarded: they may contain local paths
      // or credentials. Reading continuously prevents a full stderr pipe from
      // blocking the child before it can exit.
      _ = handle.availableData
    }
  }

  private func consumeOutput(_ data: Data) {
    var shouldStop = false
    lock.lock()
    if data.isEmpty {
      stdoutReachedEnd = true
    } else if stopReason == nil {
      if output.count + data.count > Self.maximumOutputByteCount {
        stopReason = .outputLimit
        shouldStop = true
      } else {
        output.append(data)
      }
    }
    lock.unlock()

    if shouldStop {
      stop(.outputLimit)
    } else {
      completeIfReady()
    }
  }

  private func processDidTerminate(status: Int32?) {
    lock.lock()
    terminationStatus = status
    processTerminated = true
    lock.unlock()
    completeIfReady()
  }

  private func stop(_ reason: StopReason) {
    let processIdentifier: pid_t?
    lock.lock()
    if completedResult != nil || stopRequested {
      lock.unlock()
      return
    }
    stopRequested = true
    if stopReason == nil {
      stopReason = reason
    }
    stdoutReachedEnd = true
    processIdentifier = self.processIdentifier
    lock.unlock()

    closeReaders()
    if let processIdentifier {
      requestProcessGroupCleanup(processIdentifier)
    }
    completeIfReady()
  }

  private func launchProcess() throws -> pid_t {
    let arguments = try CodexRuntimeCStringArray([executableURL.path, "--version"])
    let environment = try CodexRuntimeCStringArray(
      CodexRuntimeProcessEnvironment.sanitized()
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
    )

    var fileActions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw CodexRuntimeVersionProbeLaunchError.failed
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    let outputReadDescriptor = outputPipe.fileHandleForReading.fileDescriptor
    let outputWriteDescriptor = outputPipe.fileHandleForWriting.fileDescriptor
    let errorReadDescriptor = errorPipe.fileHandleForReading.fileDescriptor
    let errorWriteDescriptor = errorPipe.fileHandleForWriting.fileDescriptor
    guard
      posix_spawn_file_actions_addopen(
        &fileActions,
        STDIN_FILENO,
        "/dev/null",
        O_RDONLY,
        0
      ) == 0,
      posix_spawn_file_actions_adddup2(
        &fileActions,
        outputWriteDescriptor,
        STDOUT_FILENO
      ) == 0,
      posix_spawn_file_actions_adddup2(
        &fileActions,
        errorWriteDescriptor,
        STDERR_FILENO
      ) == 0,
      posix_spawn_file_actions_addclose(&fileActions, outputReadDescriptor) == 0,
      posix_spawn_file_actions_addclose(&fileActions, errorReadDescriptor) == 0,
      posix_spawn_file_actions_addclose(&fileActions, outputWriteDescriptor) == 0,
      posix_spawn_file_actions_addclose(&fileActions, errorWriteDescriptor) == 0
    else {
      throw CodexRuntimeVersionProbeLaunchError.failed
    }

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw CodexRuntimeVersionProbeLaunchError.failed
    }
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
      throw CodexRuntimeVersionProbeLaunchError.failed
    }

    var processIdentifier: pid_t = 0
    let spawnResult = executableURL.path.withCString { executablePath in
      posix_spawn(
        &processIdentifier,
        executablePath,
        &fileActions,
        &attributes,
        arguments.pointer,
        environment.pointer
      )
    }
    closeParentPipeWriters()
    guard spawnResult == 0, processIdentifier > 0 else {
      throw CodexRuntimeVersionProbeLaunchError.failed
    }
    return processIdentifier
  }

  private func monitorLeader(_ processIdentifier: pid_t) {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      var information = siginfo_t()
      while Darwin.waitid(
        P_PID,
        id_t(processIdentifier),
        &information,
        WEXITED | WNOWAIT
      ) == -1, errno == EINTR {}
      self?.requestProcessGroupCleanup(processIdentifier)
    }
  }

  private func requestProcessGroupCleanup(_ processIdentifier: pid_t) {
    let shouldRequest = lock.withLock {
      guard !terminationRequested else { return false }
      terminationRequested = true
      if self.processIdentifier == processIdentifier {
        self.processIdentifier = nil
      }
      return true
    }
    guard shouldRequest else { return }

    _ = Darwin.kill(-processIdentifier, SIGTERM)
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + Self.forceKillDelay.timeInterval
    ) { [self] in
      forceKillProcessGroupAndReapLeader(processIdentifier)
    }
  }

  private func forceKillProcessGroupAndReapLeader(_ processIdentifier: pid_t) {
    _ = Darwin.kill(-processIdentifier, SIGKILL)
    _ = Darwin.kill(processIdentifier, SIGKILL)
    var status: Int32 = 0
    while true {
      let result = Darwin.waitpid(processIdentifier, &status, 0)
      if result == processIdentifier {
        processDidTerminate(status: status)
        return
      }
      if result == -1, errno == EINTR {
        continue
      }
      processDidTerminate(status: nil)
      return
    }
  }

  private func closeParentPipeWriters() {
    do {
      try outputPipe.fileHandleForWriting.close()
    } catch {
      // The child owns its duplicated descriptor after a successful spawn.
    }
    do {
      try errorPipe.fileHandleForWriting.close()
    } catch {
      // The child owns its duplicated descriptor after a successful spawn.
    }
  }

  private func completeIfReady() {
    let continuation: CheckedContinuation<String?, Never>?
    let result: String?
    let timeoutTask: Task<Void, Never>?

    lock.lock()
    guard completedResult == nil,
      processTerminated,
      stdoutReachedEnd || stopReason != nil
    else {
      lock.unlock()
      return
    }
    result = makeResultLocked()
    completedResult = .some(result)
    continuation = self.continuation
    self.continuation = nil
    timeoutTask = self.timeoutTask
    self.timeoutTask = nil
    lock.unlock()

    timeoutTask?.cancel()
    closeReaders()
    continuation?.resume(returning: result)
  }

  private func makeResultLocked() -> String? {
    guard stopReason == nil,
      terminationStatus == 0,
      output.count <= Self.maximumOutputByteCount,
      let value = String(data: output, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return String(value.prefix(Self.maximumReturnedCharacterCount))
  }

  private func result() async -> String? {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let completedResult {
        lock.unlock()
        continuation.resume(returning: completedResult)
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  private func finishLaunchFailure() {
    lock.lock()
    processTerminated = true
    stdoutReachedEnd = true
    terminationStatus = nil
    lock.unlock()
    completeIfReady()
  }

  private func closeReaders() {
    let shouldClose = lock.withLock {
      guard !readersClosed else { return false }
      readersClosed = true
      return true
    }
    guard shouldClose else { return }
    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
    do {
      try outputPipe.fileHandleForReading.close()
    } catch {
      // Cleanup is best-effort after the probe result has been determined.
    }
    do {
      try errorPipe.fileHandleForReading.close()
    } catch {
      // Cleanup is best-effort after the probe result has been determined.
    }
  }

  deinit {
    timeoutTask?.cancel()
    closeReaders()
    if let processIdentifier {
      _ = Darwin.kill(-processIdentifier, SIGKILL)
      _ = Darwin.kill(processIdentifier, SIGKILL)
      var status: Int32 = 0
      while Darwin.waitpid(processIdentifier, &status, 0) == -1, errno == EINTR {}
    }
  }
}

private enum CodexRuntimeVersionProbeLaunchError: Error {
  case failed
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let components = self.components
    return TimeInterval(components.seconds)
      + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
  }
}
