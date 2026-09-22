import Darwin
import Foundation

/// A `Process` backed stdio transport for `codex app-server`.
public final class CodexAppServerProcessTransport: CodexAppServerTransport, @unchecked Sendable {
  public static let defaultArguments = ["app-server", "--listen", "stdio://"]
  public static let maximumReadChunkByteCount = 32 * 1_024
  public static let maximumStderrChunkByteCount = 16 * 1_024
  static let defaultRuntimeVersionProbeTimeout: Duration = .seconds(2)

  private let configuredExecutableURL: URL?
  private let arguments: [String]
  private let validatesRuntimeVersion: Bool
  private let lock = NSLock()
  /// Serializes complete JSONL writes without blocking lifecycle transitions.
  /// `terminate()` must remain able to close the pipe and unblock a writer
  /// when the child process stops consuming stdin.
  private let writeLock = NSLock()
  private var processIdentifier: pid_t?
  private var input: FileHandle?
  private var output: FileHandle?
  private var errorOutput: FileHandle?
  private var stderrDrainTask: Task<Void, Never>?
  private var startupTask: Task<Void, Error>?
  private var startupTaskID: UUID?
  private var started = false
  private var terminated = false

  public init(
    executableURL: URL? = nil,
    arguments: [String] = CodexAppServerProcessTransport.defaultArguments
  ) {
    self.configuredExecutableURL = executableURL
    self.arguments = arguments
    self.validatesRuntimeVersion = true
  }

  /// Test-only process fixtures are not Codex runtimes and therefore cannot
  /// satisfy the production `codex --version` compatibility contract.
  init(
    testExecutableURL: URL,
    arguments: [String]
  ) {
    self.configuredExecutableURL = testExecutableURL
    self.arguments = arguments
    self.validatesRuntimeVersion = false
  }

  public static func discoverExecutableURL() -> URL? {
    discoverRuntimeLocation()?.url
  }

  public static func inspectRuntime() async -> CodexAppServerRuntimeStatus {
    guard let location = discoverRuntimeLocation() else {
      return CodexAppServerRuntimeStatus()
    }
    let version = await readVersion(executableURL: location.url)
    return CodexAppServerRuntimeStatus(
      executableURL: location.url,
      source: location.source,
      version: version
    )
  }

  static func discoverRuntimeLocation(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fallbackCandidates: [(path: String, source: CodexAppServerRuntimeSource)] = [
      ("/opt/homebrew/bin/codex", .homebrew),
      ("/usr/local/bin/codex", .homebrew),
      ("/usr/bin/codex", .path),
      ("/bin/codex", .path),
    ],
    fileManager: FileManager = .default
  )
    -> (url: URL, source: CodexAppServerRuntimeSource)?
  {
    let pathCandidates =
      environment["PATH"]?
      .split(separator: ":", omittingEmptySubsequences: true)
      .compactMap { entry -> (path: String, source: CodexAppServerRuntimeSource)? in
        let directory = String(entry)
        guard directory.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: directory, isDirectory: true)
          .appendingPathComponent("codex", isDirectory: false)
          .standardizedFileURL.path
        let source: CodexAppServerRuntimeSource =
          path == "/opt/homebrew/bin/codex" || path == "/usr/local/bin/codex"
          ? .homebrew : .path
        return (path, source)
      } ?? []
    let userCandidates: [(path: String, source: CodexAppServerRuntimeSource)] =
      [
        (
          (environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path)
            + "/.local/bin/codex", .path
        )
      ]
    var visitedPaths = Set<String>()
    for candidate in pathCandidates + userCandidates + fallbackCandidates {
      let standardizedPath = URL(fileURLWithPath: candidate.path).standardizedFileURL.path
      guard visitedPaths.insert(standardizedPath).inserted,
        fileManager.isExecutableFile(atPath: standardizedPath)
      else { continue }
      return (URL(fileURLWithPath: standardizedPath), candidate.source)
    }
    return nil
  }

  static func readVersion(
    executableURL: URL,
    expectedExecutableIdentity: CodexExecutableIdentity? = nil,
    timeout: Duration = defaultRuntimeVersionProbeTimeout
  ) async -> String? {
    guard let executable = CodexExecutableIdentity.capture(executableURL: executableURL),
      expectedExecutableIdentity.map({ $0 == executable.identity }) ?? true
    else { return nil }
    let probe = CodexRuntimeVersionProbe(
      executableURL: executable.url,
      expectedExecutableIdentity: executable.identity
    )
    return await probe.run(timeout: timeout)
  }

  public func start() async throws {
    let startup: (id: UUID, task: Task<Void, Error>)? = try withLock {
      if started { return nil }
      guard !terminated else { throw CodexAppServerError.processExited }
      if let startupTask, let startupTaskID {
        return (startupTaskID, startupTask)
      }
      let startupTaskID = UUID()
      let startupTask = Task { [weak self] in
        guard let self else { throw CodexAppServerError.processExited }
        try await self.performStart()
      }
      self.startupTask = startupTask
      self.startupTaskID = startupTaskID
      return (startupTaskID, startupTask)
    }
    guard let startup else { return }

    do {
      // Callers share one transport startup. Cancellation belongs to the
      // individual waiter; only `terminate()` owns cancellation of the shared
      // lifecycle task. Otherwise one abandoned UI request can make every
      // concurrent caller observe a failed transport startup.
      try await startup.task.value
      try Task.checkCancellation()
      clearStartupTask(ifCurrent: startup.id)
    } catch {
      clearStartupTask(ifCurrent: startup.id)
      throw error
    }
  }

  private func performStart() async throws {
    let executableURL = configuredExecutableURL ?? Self.discoverExecutableURL()
    guard let executableURL,
      let executable = CodexExecutableIdentity.capture(executableURL: executableURL)
    else {
      throw CodexAppServerError.executableNotFound
    }

    if validatesRuntimeVersion {
      guard
        let versionOutput = await Self.readVersion(
          executableURL: executable.url,
          expectedExecutableIdentity: executable.identity
        ),
        CodexAppServerRuntimeVersion.parse(versionOutput)?.isSupported == true,
        CodexExecutableIdentity.capture(executableURL: executable.url)?.identity
          == executable.identity
      else {
        throw CodexAppServerError.processExited
      }
    }

    try Task.checkCancellation()
    try withLock {
      if started { return }
      guard !terminated else { throw CodexAppServerError.processExited }
      guard
        CodexExecutableIdentity.capture(executableURL: executable.url)?.identity
          == executable.identity
      else { throw CodexAppServerError.processExited }
      let inputPipe = Pipe()
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      let processIdentifier: pid_t
      do {
        processIdentifier = try Self.spawn(
          executableURL: executable.url,
          arguments: arguments,
          environment: CodexRuntimeProcessEnvironment.sanitized(),
          inputPipe: inputPipe,
          outputPipe: outputPipe,
          errorPipe: errorPipe
        )
      } catch {
        throw CodexAppServerError.processExited
      }

      // Detect a replacement between validation and launch. The child is
      // immediately reaped rather than ever serving a request from an
      // executable whose checked identity no longer matches.
      guard
        CodexExecutableIdentity.capture(executableURL: executable.url)?.identity
          == executable.identity
      else {
        Self.terminateProcessGroup(processIdentifier)
        throw CodexAppServerError.processExited
      }

      self.processIdentifier = processIdentifier
      self.input = inputPipe.fileHandleForWriting
      self.output = outputPipe.fileHandleForReading
      self.errorOutput = errorPipe.fileHandleForReading
      self.started = true

      // Drain stderr so a noisy process cannot block on a full pipe.  We intentionally discard it:
      // stderr can contain command-line diagnostics or credentials and must never be surfaced as a
      // client error or written to logs.  The read size is bounded on every iteration.
      let stderr = errorPipe.fileHandleForReading
      self.stderrDrainTask = Task.detached(priority: .utility) {
        while !Task.isCancelled {
          let data = stderr.availableData
          guard !data.isEmpty else {
            return
          }
          _ = data.count
        }
      }
    }
  }

  private func clearStartupTask(ifCurrent startupID: UUID) {
    withLock {
      guard startupTaskID == startupID else { return }
      startupTask = nil
      startupTaskID = nil
    }
  }

  public func send(_ data: Data) async throws {
    do {
      try withWriteLock {
        let handle: FileHandle = try withLock {
          guard started, !terminated, let input else {
            throw CodexAppServerError.processNotRunning
          }
          return input
        }
        // A concurrent termination may close the snapshotted handle. That is
        // intentional: it makes a blocked pipe write fail instead of making
        // termination wait behind the writer. Concurrent sends still cannot
        // interleave because they share `writeLock`.
        try handle.write(contentsOf: data)
      }
    } catch {
      if let error = error as? CodexAppServerError {
        throw error
      }
      throw CodexAppServerError.processExited
    }
  }

  public func receive() async throws -> Data? {
    let handle: FileHandle = try withLock {
      guard started, !terminated, let output else {
        throw CodexAppServerError.processNotRunning
      }
      return output
    }

    let data = await Task.detached(priority: .utility) {
      handle.availableData
    }.value
    if Task.isCancelled {
      throw CodexAppServerError.cancelled
    }
    return data.isEmpty ? nil : data
  }

  public func terminate() async {
    let snapshot: (pid_t?, [FileHandle], Task<Void, Error>?) = withLock {
      if terminated {
        return (nil, [], nil)
      }
      terminated = true
      let processIdentifier = self.processIdentifier
      self.processIdentifier = nil
      let handles = [input, output, errorOutput].compactMap { $0 }
      self.input = nil
      self.output = nil
      self.errorOutput = nil
      stderrDrainTask?.cancel()
      stderrDrainTask = nil
      let startupTask = self.startupTask
      self.startupTask = nil
      startupTaskID = nil
      return (processIdentifier, handles, startupTask)
    }
    let processIdentifier = snapshot.0
    let handles = snapshot.1
    snapshot.2?.cancel()

    if let processIdentifier {
      Self.terminateProcessGroup(processIdentifier)
    }
    for handle in handles {
      try? handle.close()
    }
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
    writeLock.lock()
    defer { writeLock.unlock() }
    return try body()
  }

  deinit {
    lock.lock()
    let processIdentifier = self.processIdentifier
    self.processIdentifier = nil
    let handles = [input, output, errorOutput].compactMap { $0 }
    stderrDrainTask?.cancel()
    startupTask?.cancel()
    lock.unlock()
    if let processIdentifier {
      Self.terminateProcessGroup(processIdentifier)
    }
    for handle in handles {
      try? handle.close()
    }
  }

  private static func spawn(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    inputPipe: Pipe,
    outputPipe: Pipe,
    errorPipe: Pipe
  ) throws -> pid_t {
    let argv = try CodexRuntimeCStringArray([executableURL.path] + arguments)
    let env = try CodexRuntimeCStringArray(
      environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      throw CodexRuntimeProcessError.spawnFailed
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    let inputRead = inputPipe.fileHandleForReading.fileDescriptor
    let inputWrite = inputPipe.fileHandleForWriting.fileDescriptor
    let outputRead = outputPipe.fileHandleForReading.fileDescriptor
    let outputWrite = outputPipe.fileHandleForWriting.fileDescriptor
    let errorRead = errorPipe.fileHandleForReading.fileDescriptor
    let errorWrite = errorPipe.fileHandleForWriting.fileDescriptor
    guard
      posix_spawn_file_actions_adddup2(&actions, inputRead, STDIN_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, outputWrite, STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, errorWrite, STDERR_FILENO) == 0,
      posix_spawn_file_actions_addclose(&actions, inputWrite) == 0,
      posix_spawn_file_actions_addclose(&actions, outputRead) == 0,
      posix_spawn_file_actions_addclose(&actions, errorRead) == 0,
      posix_spawn_file_actions_addclose(&actions, inputRead) == 0,
      posix_spawn_file_actions_addclose(&actions, outputWrite) == 0,
      posix_spawn_file_actions_addclose(&actions, errorWrite) == 0
    else { throw CodexRuntimeProcessError.spawnFailed }
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { throw CodexRuntimeProcessError.spawnFailed }
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else { throw CodexRuntimeProcessError.spawnFailed }
    var processIdentifier: pid_t = 0
    let result = executableURL.path.withCString {
      posix_spawn(&processIdentifier, $0, &actions, &attributes, argv.pointer, env.pointer)
    }
    try? inputPipe.fileHandleForReading.close()
    try? outputPipe.fileHandleForWriting.close()
    try? errorPipe.fileHandleForWriting.close()
    guard result == 0, processIdentifier > 0 else { throw CodexRuntimeProcessError.spawnFailed }
    return processIdentifier
  }

  private static func terminateProcessGroup(_ processIdentifier: pid_t) {
    _ = Darwin.kill(-processIdentifier, SIGTERM)
    let deadline = Date().addingTimeInterval(0.1)
    var status: Int32 = 0
    var leaderWasReaped = false
    while Date() < deadline {
      if !leaderWasReaped {
        let result = Darwin.waitpid(processIdentifier, &status, WNOHANG)
        if result == processIdentifier || (result == -1 && errno == ECHILD) {
          leaderWasReaped = true
        } else if result == -1 && errno != EINTR {
          break
        }
      }
      errno = 0
      let groupProbe = Darwin.kill(-processIdentifier, 0)
      if groupProbe == -1, errno == ESRCH {
        return
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    _ = Darwin.kill(-processIdentifier, SIGKILL)
    _ = Darwin.kill(processIdentifier, SIGKILL)
    if !leaderWasReaped {
      while Darwin.waitpid(processIdentifier, &status, 0) == -1, errno == EINTR {}
    }
  }
}
