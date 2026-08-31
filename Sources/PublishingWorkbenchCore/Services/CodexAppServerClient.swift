import Darwin
import Foundation

/// The byte-oriented transport used by ``CodexAppServerClient``.
///
/// A transport sends one JSONL request at a time and returns arbitrary stdout chunks.  Keeping
/// this boundary small makes the client straightforward to test without launching a real Codex
/// process, while the production transport below remains the only place that touches `Process`.
public protocol CodexAppServerTransport: Sendable {
  func start() async throws
  func send(_ data: Data) async throws
  func receive() async throws -> Data?
  func terminate() async
}

extension CodexAppServerError {
  /// A stable, typed sentinel for a request which exceeded the client's
  /// bounded RPC deadline. Keeping this RPC-shaped preserves the existing
  /// public error surface while avoiding string parsing by callers.
  public static var requestTimedOut: Self {
    .rpc(code: -32_002, message: "Codex 请求超时，请重试。")
  }

  /// A stable, typed sentinel for a model turn which exceeded its deadline.
  public static var turnTimedOut: Self {
    .rpc(code: -32_003, message: "Codex turn 执行超时，请重试。")
  }

  /// A bounded JSONL reader must reject an unterminated response before it can
  /// retain unbounded process output in memory.
  static var frameTooLarge: Self {
    .rpc(code: -32_004, message: "Codex 响应帧超过大小限制，已停止当前连接。")
  }
}

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
    var visitedPaths = Set<String>()
    for candidate in pathCandidates + fallbackCandidates {
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

/// A small, actor-isolated JSON-RPC client for the Codex app-server protocol.
public actor CodexAppServerClient {
  /// The shared runtime used by the settings/login flow and AI requests.
  public static let shared = CodexAppServerClient()

  /// A read-only view of a turn after the client has installed its completion waiter.
  ///
  /// This is intentionally internal: tests use it to synchronize cancellation with the
  /// client's active-turn state without changing the cancellation protocol or production flow.
  struct ActiveTurnSnapshot: Equatable, Sendable {
    let threadID: String
    let turnID: String
  }

  private let transportFactory: @Sendable () -> any CodexAppServerTransport
  private var transport: any CodexAppServerTransport
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  private var nextRequestID = 0
  private var pendingRequests: [Int: CheckedContinuation<CodexAppServerJSONValue, Error>] = [:]
  private var requestTimeoutTasks: [Int: Task<Void, Never>] = [:]
  private var startupTask: Task<Void, Error>?
  /// Identity is separate from `Task` because an invalidated startup task can
  /// finish after a new transport generation has already begun.
  private var startupTaskID: UUID?
  private var readerTask: Task<Void, Never>?
  private var isInitialized = false
  private var transportEnded = false
  private var transportEndError = CodexAppServerError.endOfStream
  private var transportGeneration = 0
  private var lineBuffer = Data()

  /// One app-server response is expected to fit comfortably below this limit.
  /// The limit applies to one JSONL frame, not to an arbitrary stdout chunk,
  /// so multiple valid frames may arrive together.
  static let maximumFrameByteCount = 1_024 * 1_024

  private struct TurnState {
    let threadID: String
    var model: String?
    var turnID: String?
    var text = ""
    var allowedDynamicToolNames = Set<String>()
    var toolCalls: [AIToolCall] = []
    var result: CodexAppServerCompletion?
    var failure: CodexAppServerError?
    var waiter: CheckedContinuation<CodexAppServerCompletion, Error>?
  }

  private var turnStates: [String: TurnState] = [:]
  private var threadIDByTurnID: [String: String] = [:]
  private var turnTimeoutTasks: [String: Task<Void, Never>] = [:]

  private enum LoginOutcome {
    case succeeded
    case failed(CodexAppServerError)
  }

  private var loginOutcomes: [String: LoginOutcome] = [:]
  private var loginWaiters: [String: CheckedContinuation<Void, Error>] = [:]
  private var loginTimeoutTasks: [String: Task<Void, Never>] = [:]
  private var activeLoginIDs = Set<String>()
  /// Completed notifications can race with a local cancellation RPC. Keep a
  /// small tombstone set so a late success cannot be buffered and mistaken for
  /// a future wait using the same login identifier.
  private var ignoredLoginOutcomeIDs = Set<String>()
  private var ignoredLoginOutcomeOrder: [String] = []
  private let loginTimeout: Duration
  private let requestTimeout: Duration
  private let turnTimeout: Duration

  private static let maximumIgnoredLoginOutcomeCount = 64

  private static let textOnlyThreadDeveloperInstructions =
    "Answer only from the supplied text. Never inspect the filesystem, run commands, or use tools."

  private static let dynamicToolThreadDeveloperInstructions =
    "Answer only from the supplied text. Never inspect the filesystem, run commands, or browse. You may call only the dynamic tools explicitly supplied by RepoPress Studio. Their immediate acknowledgement only records the call; do not claim success until a later tool-role message contains the host-validated result."

  public init(
    executableURL: URL? = nil,
    transport: (any CodexAppServerTransport)? = nil,
    loginTimeout: Duration = CodexAppServerClient.defaultLoginTimeout,
    requestTimeout: Duration = CodexAppServerClient.defaultRequestTimeout,
    turnTimeout: Duration = CodexAppServerClient.defaultTurnTimeout
  ) {
    if let transport {
      self.transportFactory = { transport }
      self.transport = transport
    } else {
      let factory: @Sendable () -> any CodexAppServerTransport = {
        CodexAppServerProcessTransport(executableURL: executableURL)
      }
      self.transportFactory = factory
      self.transport = factory()
    }
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    self.encoder.outputFormatting = [.sortedKeys]
    self.loginTimeout = loginTimeout
    self.requestTimeout = requestTimeout
    self.turnTimeout = turnTimeout
  }

  /// Creates a client whose transport can be replaced after EOF or process
  /// exit. Production uses this internally for each app-server generation;
  /// the initializer is also useful for deterministic recovery tests.
  public init(
    transportFactory: @escaping @Sendable () -> any CodexAppServerTransport,
    loginTimeout: Duration = CodexAppServerClient.defaultLoginTimeout,
    requestTimeout: Duration = CodexAppServerClient.defaultRequestTimeout,
    turnTimeout: Duration = CodexAppServerClient.defaultTurnTimeout
  ) {
    self.transportFactory = transportFactory
    self.transport = transportFactory()
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    self.encoder.outputFormatting = [.sortedKeys]
    self.loginTimeout = loginTimeout
    self.requestTimeout = requestTimeout
    self.turnTimeout = turnTimeout
  }

  /// The login flow is user-facing and must not wait forever if the browser
  /// callback is lost. Callers can inject a short duration in tests.
  public static let defaultLoginTimeout: Duration = .seconds(5 * 60)

  /// Ordinary JSON-RPC calls must not leave an actor continuation pending
  /// forever. Callers can inject a much shorter duration in tests.
  public static let defaultRequestTimeout: Duration = .seconds(60)

  /// A model turn can legitimately take longer than a metadata RPC, but it
  /// still needs an upper bound so a lost completion notification cannot keep
  /// the UI task alive indefinitely.
  public static let defaultTurnTimeout: Duration = .seconds(5 * 60)

  /// Internal observability for regression tests. The production UI does not
  /// need to know whether a continuation is installed.
  var loginWaiterCount: Int {
    loginWaiters.count
  }

  var activeTurnSnapshot: ActiveTurnSnapshot? {
    for state in turnStates.values {
      if let turnID = state.turnID, state.waiter != nil {
        return ActiveTurnSnapshot(threadID: state.threadID, turnID: turnID)
      }
    }
    return nil
  }

  public func start() async throws {
    try await ensureStarted()
  }

  public func accountStatus() async throws -> CodexAppServerAccountStatus {
    let value = try await request(method: "account/read", params: .object([:]))
    return parseAccountStatus(value)
  }

  public func startChatGPTLogin() async throws -> CodexAppServerLoginResult {
    let value = try await request(
      method: "account/login/start",
      params: .object([
        "appBrand": .string("chatgpt"),
        "type": .string("chatgpt"),
        "useHostedLoginSuccessPage": .bool(true),
      ])
    )
    guard let object = value.objectValue else {
      throw CodexAppServerError.invalidResponse
    }
    let loginObject = object["login"]?.objectValue ?? object
    let loginID = firstString(in: loginObject, keys: ["loginId", "loginID", "id"])
    let authURLString = firstString(in: loginObject, keys: ["authUrl", "authURL", "url"])
    guard let loginID, !loginID.isEmpty,
      let authURLString, let authURL = Self.validatedLoginURL(authURLString)
    else {
      throw CodexAppServerError.invalidResponse
    }
    registerLogin(loginID: loginID)
    return CodexAppServerLoginResult(loginID: loginID, authURL: authURL)
  }

  public func startChatGPTDeviceCodeLogin() async throws -> CodexAppServerDeviceCodeLoginResult {
    let value = try await request(
      method: "account/login/start",
      params: .object(["type": .string("chatgptDeviceCode")])
    )
    guard let object = value.objectValue else {
      throw CodexAppServerError.invalidResponse
    }
    let loginObject = object["login"]?.objectValue ?? object
    let loginID = firstString(in: loginObject, keys: ["loginId", "loginID", "id"])
    let verificationURLString = firstString(
      in: loginObject,
      keys: ["verificationUrl", "verificationURL", "url"]
    )
    let userCode = firstString(in: loginObject, keys: ["userCode", "code"])
    guard let loginID, !loginID.isEmpty,
      let verificationURLString,
      let verificationURL = Self.validatedLoginURL(verificationURLString),
      let userCode, !userCode.isEmpty
    else {
      throw CodexAppServerError.invalidResponse
    }
    registerLogin(loginID: loginID)
    return CodexAppServerDeviceCodeLoginResult(
      loginID: loginID,
      verificationURL: verificationURL,
      userCode: userCode
    )
  }

  public func waitForLoginCompletion(loginID: String) async throws {
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          if let outcome = loginOutcomes.removeValue(forKey: loginID) {
            resumeLoginWaiter(continuation, with: outcome)
          } else if loginWaiters[loginID] != nil {
            continuation.resume(throwing: CodexAppServerError.invalidResponse)
          } else {
            loginWaiters[loginID] = continuation
            scheduleLoginTimeout(loginID: loginID)
          }
        }
      },
      onCancel: {
        Task { [weak self] in
          await self?.cancelLogin(loginID: loginID)
        }
      })
  }

  public func cancelLogin(loginID: String) async {
    let waiter = loginWaiters.removeValue(forKey: loginID)
    loginOutcomes.removeValue(forKey: loginID)
    let wasActive = activeLoginIDs.remove(loginID) != nil
    cancelLoginTimeout(loginID: loginID)
    waiter?.resume(throwing: CodexAppServerError.cancelled)
    guard wasActive || waiter != nil else { return }
    markLoginOutcomeIgnored(loginID)
    await sendLoginCancellation(loginID: loginID)
  }

  public func logout() async throws {
    _ = try await request(method: "account/logout", params: .object([:]))
  }

  public func rateLimits() async throws -> CodexAppServerRateLimits {
    let value = try await request(method: "account/rateLimits/read", params: .object([:]))
    return parseRateLimits(value)
  }

  /// Returns the models available to the authenticated app-server account.
  ///
  /// The catalog is paginated by an opaque cursor. The cursor is tracked so a
  /// malformed or stale server response cannot make the client request the
  /// same page forever. Hidden models are also filtered locally when callers
  /// use the default, public catalog.
  public func models(includeHidden: Bool = false) async throws -> [CodexAppServerModel] {
    let pageLimit = 100
    let maximumPages = 1_024
    var cursor: String?
    var visitedCursors = Set<String>()
    var seenModelKeys = Set<String>()
    var models: [CodexAppServerModel] = []
    var pageCount = 0

    while pageCount < maximumPages {
      let cursorKey = cursor ?? ""
      guard visitedCursors.insert(cursorKey).inserted else { break }

      var params: [String: CodexAppServerJSONValue] = [
        "includeHidden": .bool(includeHidden),
        "limit": .number(Double(pageLimit)),
      ]
      if let cursor {
        params["cursor"] = .string(cursor)
      }

      let value = try await request(method: "model/list", params: .object(params))
      guard let root = value.objectValue else {
        throw CodexAppServerError.invalidResponse
      }
      let modelValues =
        root["data"]?.arrayValue
        ?? root["models"]?.arrayValue
        ?? root["items"]?.arrayValue
      guard let modelValues else {
        throw CodexAppServerError.invalidResponse
      }

      for modelValue in modelValues {
        let data: Data
        do {
          data = try encoder.encode(modelValue)
          let model = try decoder.decode(CodexAppServerModel.self, from: data)
          guard !model.id.isEmpty || !model.model.isEmpty else { continue }
          guard includeHidden || !model.hidden else { continue }
          let modelKeys = [model.id, model.model].filter { !$0.isEmpty }
          guard !modelKeys.contains(where: seenModelKeys.contains) else { continue }
          modelKeys.forEach { seenModelKeys.insert($0) }
          models.append(model)
        } catch {
          throw CodexAppServerError.invalidResponse
        }
      }

      pageCount += 1
      let pagination = root["pagination"]?.objectValue ?? root["page"]?.objectValue ?? [:]
      let nextCursor =
        firstNonEmptyString(
          in: root,
          keys: ["nextCursor", "next_cursor"]
        )
        ?? firstNonEmptyString(
          in: pagination,
          keys: ["nextCursor", "next_cursor"]
        )
      guard let nextCursor, !visitedCursors.contains(nextCursor) else { break }
      cursor = nextCursor
    }

    return models
  }

  public func complete(
    prompt: String,
    model: String? = nil,
    reasoningEffort: String? = nil,
    workingDirectory: URL? = nil
  ) async throws -> CodexAppServerCompletion {
    try await complete(
      prompt: prompt,
      model: model,
      reasoningEffort: reasoningEffort,
      workingDirectory: workingDirectory,
      dynamicTools: []
    )
  }

  /// Runs an ephemeral text turn with host-owned dynamic function tools.
  /// App Server only chooses and reports a call; execution authority remains
  /// in the workbench Agent loop.
  public func complete(
    prompt: String,
    model: String? = nil,
    reasoningEffort: String? = nil,
    workingDirectory: URL? = nil,
    dynamicTools: [AIToolDefinition]
  ) async throws -> CodexAppServerCompletion {
    try await ensureStarted()
    let normalizedModel = Self.trimmedNonEmpty(model)
    let normalizedReasoningEffort = Self.trimmedNonEmpty(reasoningEffort)
    let normalizedDynamicTools = try Self.validatedDynamicTools(dynamicTools)
    let thread = try await startThread(
      model: normalizedModel,
      workingDirectory: workingDirectory,
      dynamicTools: normalizedDynamicTools
    )
    let threadID = thread.id
    turnStates[threadID] = TurnState(
      threadID: threadID,
      model: thread.model,
      allowedDynamicToolNames: Set(normalizedDynamicTools.map(\.function.name))
    )

    do {
      let turnID = try await startTurn(
        threadID: threadID,
        prompt: prompt,
        reasoningEffort: normalizedReasoningEffort
      )
      if var state = turnStates[threadID] {
        state.turnID = turnID
        turnStates[threadID] = state
        threadIDByTurnID[turnID] = threadID
      }
      return try await waitForTurn(threadID: threadID)
    } catch {
      removeTurn(threadID: threadID)
      throw error
    }
  }

  public func completeText(
    prompt: String,
    model: String? = nil,
    reasoningEffort: String? = nil,
    workingDirectory: URL? = nil
  ) async throws -> String {
    try await complete(
      prompt: prompt,
      model: model,
      reasoningEffort: reasoningEffort,
      workingDirectory: workingDirectory
    ).text
  }

  public func shutdown() async {
    // Invalidate the task before cancelling it. Cancellation is cooperative,
    // so its deferred cleanup can otherwise race a replacement generation.
    startupTaskID = nil
    readerTask?.cancel()
    readerTask = nil
    startupTask?.cancel()
    startupTask = nil
    isInitialized = false
    transportEnded = true
    transportEndError = .endOfStream
    transportGeneration &+= 1
    failAll(with: .endOfStream)
    await transport.terminate()
  }

  private func ensureStarted() async throws {
    if isInitialized {
      return
    }
    if let startupTask {
      try await startupTask.value
      return
    }

    let startupID = UUID()
    let task = Task<Void, Error> { [weak self] in
      guard let self else { throw CodexAppServerError.processExited }
      try await self.startAndHandshake(startupID: startupID)
    }
    startupTask = task
    startupTaskID = startupID
    do {
      try await task.value
      clearStartupTaskIfCurrent(startupID)
    } catch {
      clearStartupTaskIfCurrent(startupID)
      throw Self.mapError(error)
    }
  }

  private func clearStartupTaskIfCurrent(_ startupID: UUID) {
    guard startupTaskID == startupID else { return }
    startupTask = nil
    startupTaskID = nil
  }

  private func startAndHandshake(startupID: UUID) async throws {
    // The task closure itself can start late, after `shutdown()` has already
    // invalidated it and admitted a replacement task.
    guard startupTaskID == startupID else {
      throw CodexAppServerError.endOfStream
    }
    let nextTransport: any CodexAppServerTransport
    if transportGeneration == 0 {
      // The initializer already created the first transport so a factory is
      // invoked exactly once per app-server generation.
      nextTransport = transport
    } else {
      nextTransport = transportFactory()
    }
    transportGeneration &+= 1
    let generation = transportGeneration
    transport = nextTransport
    // Keep request IDs monotonic across transport generations. This prevents
    // a late response from a reused/injected transport from colliding with a
    // request in the newly started generation.
    lineBuffer.removeAll(keepingCapacity: false)

    do {
      transportEnded = false
      transportEndError = .endOfStream
      try await nextTransport.start()
      // `start()` is allowed to suspend and cancellation is cooperative. Do
      // not install an old reader after shutdown has already admitted a new
      // generation.
      guard isCurrentStartup(startupID: startupID, generation: generation) else {
        throw CodexAppServerError.endOfStream
      }
      readerTask = Task { [weak self, nextTransport] in
        await self?.readLoop(transport: nextTransport, generation: generation)
      }
      _ = try await requestWithoutStartup(
        method: "initialize",
        params: .object([
          // Dynamic application tools are an app-server experimental field in
          // the supported 0.142+ protocol. The workbench still validates every
          // returned call against its own allow-list and command registry.
          "capabilities": .object(["experimentalApi": .bool(true)]),
          "clientInfo": .object([
            "name": .string("RepoPress Studio"),
            "title": .string("RepoPress Studio"),
            "version": .string("1.0.1"),
          ]),
        ])
      )
      guard isCurrentStartup(startupID: startupID, generation: generation) else {
        throw CodexAppServerError.endOfStream
      }
      try await sendNotification(
        method: "initialized",
        params: nil,
        to: nextTransport,
        generation: generation
      )
      guard isCurrentStartup(startupID: startupID, generation: generation), !transportEnded else {
        throw CodexAppServerError.endOfStream
      }
      isInitialized = true
    } catch {
      let mappedError = Self.mapError(error)
      // A shutdown/restart may have invalidated this task while it was
      // suspended. Its completion belongs to the old generation and must not
      // clear a replacement reader, startup task, or pending request table.
      guard isCurrentStartup(startupID: startupID, generation: generation) else {
        throw mappedError
      }
      isInitialized = false
      transportEnded = true
      transportEndError = mappedError
      readerTask?.cancel()
      readerTask = nil
      failAll(with: mappedError)
      await nextTransport.terminate()
      throw mappedError
    }
  }

  private func request(
    method: String,
    params: CodexAppServerJSONValue?
  ) async throws -> CodexAppServerJSONValue {
    try await ensureStarted()
    return try await requestWithoutStartup(method: method, params: params)
  }

  private func requestWithoutStartup(
    method: String,
    params: CodexAppServerJSONValue?
  ) async throws -> CodexAppServerJSONValue {
    nextRequestID += 1
    let requestID = nextRequestID
    var requestObject: [String: CodexAppServerJSONValue] = [
      "id": .number(Double(requestID)),
      "method": .string(method),
    ]
    if let params {
      requestObject["params"] = params
    }
    let data: Data
    do {
      data = try encoder.encode(CodexAppServerJSONValue.object(requestObject)) + Data([0x0A])
    } catch {
      throw CodexAppServerError.invalidResponse
    }
    let requestTransport = transport
    let requestGeneration = transportGeneration

    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          pendingRequests[requestID] = continuation
          scheduleRequestTimeout(requestID: requestID)
          Task { [weak self, requestTransport] in
            guard let self else { return }
            do {
              // Bind the request to the transport generation that created it.
              // A delayed send from an ended generation must never land in a
              // newly started app-server process.
              try await self.sendFrame(
                data,
                to: requestTransport,
                generation: requestGeneration
              )
            } catch {
              await self.failPendingRequest(
                requestID: requestID,
                error: Self.mapError(error)
              )
            }
          }
        }
      },
      onCancel: {
        Task { [weak self] in
          await self?.cancelPendingRequest(requestID: requestID)
        }
      })
  }

  private func sendNotification(
    method: String,
    params: CodexAppServerJSONValue?,
    to expectedTransport: (any CodexAppServerTransport)? = nil,
    generation expectedGeneration: Int? = nil
  ) async throws {
    var object: [String: CodexAppServerJSONValue] = ["method": .string(method)]
    if let params {
      object["params"] = params
    }
    do {
      let data = try encoder.encode(CodexAppServerJSONValue.object(object)) + Data([0x0A])
      try await sendFrame(
        data,
        to: expectedTransport ?? transport,
        generation: expectedGeneration ?? transportGeneration
      )
    } catch let error as CodexAppServerError {
      throw error
    } catch {
      throw CodexAppServerError.processExited
    }
  }

  private func isCurrentStartup(startupID: UUID, generation: Int) -> Bool {
    startupTaskID == startupID && transportGeneration == generation
  }

  /// Admits a frame only while its originating process generation is active.
  /// `CodexAppServerProcessTransport` then serializes the full write together
  /// with its handle lifecycle, so a queued request cannot reach a later
  /// process or a handle that shutdown has closed.
  private func sendFrame(
    _ data: Data,
    to expectedTransport: any CodexAppServerTransport,
    generation: Int
  ) async throws {
    guard generation == transportGeneration else {
      throw CodexAppServerError.processNotRunning
    }
    guard !transportEnded else { throw transportEndError }
    try await expectedTransport.send(data)
  }

  private func cancelPendingRequest(requestID: Int) {
    requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
    guard let continuation = pendingRequests.removeValue(forKey: requestID) else { return }
    continuation.resume(throwing: CodexAppServerError.cancelled)
  }

  private func failPendingRequest(requestID: Int, error: CodexAppServerError) {
    requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
    guard let continuation = pendingRequests.removeValue(forKey: requestID) else { return }
    continuation.resume(throwing: error)
  }

  private func scheduleRequestTimeout(requestID: Int) {
    requestTimeoutTasks[requestID]?.cancel()
    let timeout = requestTimeout
    requestTimeoutTasks[requestID] = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.timeoutPendingRequest(requestID: requestID)
    }
  }

  private func timeoutPendingRequest(requestID: Int) {
    guard let continuation = pendingRequests.removeValue(forKey: requestID) else {
      requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
      return
    }
    requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
    continuation.resume(throwing: CodexAppServerError.requestTimedOut)
  }

  private func startThread(
    model: String?,
    workingDirectory: URL?,
    dynamicTools: [AIToolDefinition]
  ) async throws -> (id: String, model: String?) {
    var params: [String: CodexAppServerJSONValue] = [
      "approvalPolicy": .string("never"),
      "developerInstructions": .string(
        dynamicTools.isEmpty
          ? Self.textOnlyThreadDeveloperInstructions
          : Self.dynamicToolThreadDeveloperInstructions
      ),
      "ephemeral": .bool(true),
      "sandbox": .string("read-only"),
    ]
    if !dynamicTools.isEmpty {
      params["dynamicTools"] = .array(
        dynamicTools.map { definition in
          var tool: [String: CodexAppServerJSONValue] = [
            "type": .string("function"),
            "name": .string(definition.function.name),
            "inputSchema": Self.codexJSONValue(definition.function.parameters),
          ]
          if let description = definition.function.description?.trimmedForPublishing.nilIfEmpty {
            tool["description"] = .string(description)
          } else {
            tool["description"] = .string(definition.function.name)
          }
          return .object(tool)
        }
      )
    }
    if let model, !model.isEmpty {
      params["model"] = .string(model)
    }
    if let workingDirectory {
      params["cwd"] = .string(workingDirectory.path)
    }
    let value = try await requestWithoutStartup(method: "thread/start", params: .object(params))
    guard
      let threadID = identifier(in: value, nestedKeys: ["thread", "threadId", "threadID", "id"]),
      !threadID.isEmpty
    else {
      throw CodexAppServerError.invalidResponse
    }
    let responseModel: String?
    if let root = value.objectValue {
      responseModel =
        firstString(in: root, keys: ["model"])
        ?? firstString(in: root["thread"]?.objectValue ?? [:], keys: ["model"])
    } else {
      responseModel = nil
    }
    return (threadID, responseModel ?? model)
  }

  private static func validatedDynamicTools(
    _ definitions: [AIToolDefinition]
  ) throws -> [AIToolDefinition] {
    var names = Set<String>()
    var validated: [AIToolDefinition] = []
    validated.reserveCapacity(definitions.count)
    for definition in definitions {
      let name = definition.function.name.trimmedForPublishing
      guard definition.type == "function", !name.isEmpty, names.insert(name).inserted else {
        throw CodexAppServerError.invalidResponse
      }
      var normalized = definition
      normalized.function.name = name
      validated.append(normalized)
    }
    return validated
  }

  private static func codexJSONValue(
    _ value: AIStructuredOutputJSONValue
  ) -> CodexAppServerJSONValue {
    switch value {
    case .object(let object):
      return .object(object.mapValues(codexJSONValue))
    case .array(let array):
      return .array(array.map(codexJSONValue))
    case .string(let string):
      return .string(string)
    case .number(let number):
      return .number(number)
    case .bool(let bool):
      return .bool(bool)
    case .null:
      return .null
    }
  }

  private func startTurn(
    threadID: String,
    prompt: String,
    reasoningEffort: String?
  ) async throws -> String {
    var params: [String: CodexAppServerJSONValue] = [
      "input": .array([
        .object([
          "text": .string(prompt),
          "type": .string("text"),
        ])
      ]),
      "threadId": .string(threadID),
    ]
    if let reasoningEffort {
      params["effort"] = .string(reasoningEffort)
    }
    let value = try await requestWithoutStartup(method: "turn/start", params: .object(params))
    guard let turnID = identifier(in: value, nestedKeys: ["turn", "turnId", "turnID", "id"]),
      !turnID.isEmpty
    else {
      throw CodexAppServerError.invalidResponse
    }
    return turnID
  }

  private func waitForTurn(threadID: String) async throws -> CodexAppServerCompletion {
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          guard var state = turnStates[threadID] else {
            continuation.resume(
              throwing: Task.isCancelled ? CodexAppServerError.cancelled : .invalidResponse
            )
            return
          }
          if Task.isCancelled {
            removeTurn(threadID: threadID)
            continuation.resume(throwing: CodexAppServerError.cancelled)
            return
          }
          if let failure = state.failure {
            removeTurn(threadID: threadID)
            continuation.resume(throwing: failure)
          } else if let result = state.result {
            removeTurn(threadID: threadID)
            continuation.resume(returning: result)
          } else {
            state.waiter = continuation
            turnStates[threadID] = state
            scheduleTurnTimeout(threadID: threadID)
          }
        }
      },
      onCancel: {
        Task { [weak self] in
          await self?.cancelTurn(threadID: threadID)
        }
      })
  }

  private func cancelTurn(threadID: String) {
    guard let state = turnStates[threadID], let waiter = state.waiter else { return }
    let turnID = state.turnID
    let generation = transportGeneration
    cancelTurnTimeout(threadID: threadID)
    removeTurn(threadID: threadID)
    waiter.resume(throwing: CodexAppServerError.cancelled)
    guard let turnID else { return }
    Task { [weak self] in
      await self?.interruptTurn(
        threadID: threadID,
        turnID: turnID,
        generation: generation
      )
    }
  }

  private func scheduleTurnTimeout(threadID: String) {
    turnTimeoutTasks[threadID]?.cancel()
    let timeout = turnTimeout
    turnTimeoutTasks[threadID] = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.timeoutTurn(threadID: threadID)
    }
  }

  private func cancelTurnTimeout(threadID: String) {
    turnTimeoutTasks.removeValue(forKey: threadID)?.cancel()
  }

  private func timeoutTurn(threadID: String) async {
    guard let state = turnStates[threadID], let waiter = state.waiter else {
      cancelTurnTimeout(threadID: threadID)
      return
    }
    let turnID = state.turnID
    let generation = transportGeneration
    cancelTurnTimeout(threadID: threadID)
    removeTurn(threadID: threadID)
    waiter.resume(throwing: CodexAppServerError.turnTimedOut)
    guard let turnID else { return }
    Task { [weak self] in
      await self?.interruptTurn(
        threadID: threadID,
        turnID: turnID,
        generation: generation
      )
    }
  }

  private func interruptTurn(threadID: String, turnID: String, generation: Int) async {
    guard generation == transportGeneration else { return }
    do {
      _ = try await requestWithoutStartup(
        method: "turn/interrupt",
        params: .object([
          "threadId": .string(threadID),
          "turnId": .string(turnID),
        ])
      )
    } catch {
      // Local cancellation/timeout has already completed; remote interruption
      // is best effort and must never replace the typed local outcome.
    }
  }

  private func readLoop(
    transport: any CodexAppServerTransport,
    generation: Int
  ) async {
    do {
      while !Task.isCancelled {
        guard generation == transportGeneration else { return }
        guard let chunk = try await transport.receive() else {
          guard generation == transportGeneration else { return }
          processEnded(with: .endOfStream, generation: generation)
          return
        }
        guard generation == transportGeneration else { return }
        guard !chunk.isEmpty else { continue }
        try consume(chunk: chunk)
      }
    } catch {
      guard generation == transportGeneration else { return }
      processEnded(with: Self.mapError(error), generation: generation)
    }
  }

  private func consume(chunk: Data) throws {
    var remaining = chunk[...]
    while !remaining.isEmpty {
      if let newline = remaining.firstIndex(of: 0x0A) {
        let framePrefix = remaining[..<newline]
        try appendFrameBytes(framePrefix)
        remaining = remaining[remaining.index(after: newline)...]
        try consumeBufferedFrame()
      } else {
        try appendFrameBytes(remaining)
        return
      }
    }
  }

  private func appendFrameBytes(_ bytes: Data.SubSequence) throws {
    let addition = lineBuffer.count.addingReportingOverflow(bytes.count)
    guard !addition.overflow, addition.partialValue <= Self.maximumFrameByteCount else {
      lineBuffer.removeAll(keepingCapacity: false)
      throw CodexAppServerError.frameTooLarge
    }
    lineBuffer.append(contentsOf: bytes)
  }

  private func consumeBufferedFrame() throws {
    let line = lineBuffer
    lineBuffer.removeAll(keepingCapacity: true)
    guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { return }
    let envelope: CodexAppServerRPCEnvelope
    do {
      envelope = try decoder.decode(CodexAppServerRPCEnvelope.self, from: line)
    } catch {
      throw CodexAppServerError.invalidJSON
    }
    handle(envelope: envelope)
  }

  private func handle(envelope: CodexAppServerRPCEnvelope) {
    if let method = envelope.method {
      if method == "item/tool/call", let requestID = envelope.id {
        handleDynamicToolCall(requestID: requestID, params: envelope.params)
        return
      }
      handleNotification(method: method, params: envelope.params)
      return
    }
    guard let requestID = envelope.id else { return }
    // A cancelled request may still receive a late response. It belongs to an
    // already-consumed request ID and must not tear down the shared process.
    requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
    guard let continuation = pendingRequests.removeValue(forKey: requestID) else { return }
    if let error = envelope.error {
      continuation.resume(
        throwing: CodexAppServerError.rpc(
          code: error.code,
          message: Self.sanitizedMessage(error.message ?? "Codex app-server request failed")
        )
      )
    } else if let result = envelope.result {
      continuation.resume(returning: result)
    } else {
      continuation.resume(throwing: CodexAppServerError.invalidResponse)
    }
  }

  private func handleDynamicToolCall(
    requestID: Int,
    params: CodexAppServerJSONValue?
  ) {
    let object = params?.objectValue ?? [:]
    let threadID = firstString(in: object, keys: ["threadId", "threadID"])
    let turnID = firstString(in: object, keys: ["turnId", "turnID"])
    let toolName = firstString(in: object, keys: ["tool", "name"])?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let callID = firstString(in: object, keys: ["callId", "callID", "id"])?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let namespace = firstString(in: object, keys: ["namespace"])?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedThreadID = resolveThreadID(threadID: threadID, turnID: turnID)

    guard
      namespace?.isEmpty != false,
      let resolvedThreadID,
      var state = turnStates[resolvedThreadID],
      let toolName,
      !toolName.isEmpty,
      state.allowedDynamicToolNames.contains(toolName),
      let callID,
      !callID.isEmpty,
      !state.toolCalls.contains(where: { $0.id == callID }),
      let arguments = object["arguments"],
      let argumentData = try? encoder.encode(arguments),
      let argumentJSON = String(data: argumentData, encoding: .utf8)
    else {
      sendDynamicToolCallResponse(
        requestID: requestID,
        success: false,
        message: "The dynamic tool call was rejected by the host allow-list."
      )
      return
    }

    state.toolCalls.append(
      AIToolCall(
        id: callID,
        function: AIToolFunctionCall(name: toolName, arguments: argumentJSON)
      )
    )
    if let turnID, !turnID.isEmpty {
      state.turnID = turnID
      threadIDByTurnID[turnID] = resolvedThreadID
    }
    turnStates[resolvedThreadID] = state
    sendDynamicToolCallResponse(
      requestID: requestID,
      success: true,
      message:
        "The host recorded this call for validated execution. Do not claim success yet; the actual result will arrive in a later tool-role message."
    )
  }

  private func sendDynamicToolCallResponse(
    requestID: Int,
    success: Bool,
    message: String
  ) {
    let generation = transportGeneration
    let responseTransport = transport
    let result: CodexAppServerJSONValue = .object([
      "success": .bool(success),
      "contentItems": .array([
        .object([
          "type": .string("inputText"),
          "text": .string(message),
        ])
      ]),
    ])
    let response: CodexAppServerJSONValue = .object([
      "id": .number(Double(requestID)),
      "result": result,
    ])
    let data: Data
    do {
      data = try encoder.encode(response) + Data([0x0A])
    } catch {
      processEnded(with: .invalidResponse, generation: generation)
      return
    }
    Task { [weak self, responseTransport] in
      await self?.transmitDynamicToolCallResponse(
        data,
        via: responseTransport,
        generation: generation
      )
    }
  }

  private func transmitDynamicToolCallResponse(
    _ data: Data,
    via responseTransport: any CodexAppServerTransport,
    generation: Int
  ) async {
    do {
      try await sendFrame(data, to: responseTransport, generation: generation)
    } catch {
      processEnded(with: Self.mapError(error), generation: generation)
    }
  }

  private func handleNotification(method: String, params: CodexAppServerJSONValue?) {
    guard let params else { return }
    let object = params.objectValue ?? [:]
    let nestedTurn = object["turn"]?.objectValue ?? [:]
    let threadID =
      firstString(
        in: object,
        keys: ["threadId", "threadID"]
      ) ?? firstString(in: nestedTurn, keys: ["threadId", "threadID"])
    let turnID =
      firstString(
        in: object,
        keys: ["turnId", "turnID", "id"]
      ) ?? firstString(in: nestedTurn, keys: ["id", "turnId", "turnID"])

    switch method {
    case "account/login/completed":
      let loginID = firstString(in: object, keys: ["loginId", "loginID", "id"])
      guard let loginID, !loginID.isEmpty else { return }
      let errorObject = object["error"]?.objectValue ?? [:]
      let errorMessage =
        firstString(in: errorObject, keys: ["message", "reason"])
        ?? firstString(in: object, keys: ["errorMessage", "message", "reason"])
      let succeeded = object["success"]?.boolValue ?? (errorMessage == nil)
      let outcome: LoginOutcome
      if succeeded {
        outcome = .succeeded
      } else {
        outcome = .failed(
          .rpc(
            code: nil,
            message: Self.sanitizedMessage(errorMessage ?? "ChatGPT login failed")
          )
        )
      }
      finishLogin(loginID: loginID, outcome: outcome)

    case "item/agentMessage/delta":
      guard let threadID = resolveThreadID(threadID: threadID, turnID: turnID),
        var state = turnStates[threadID]
      else { return }
      if let delta = firstString(in: object, keys: ["delta", "text"]) {
        state.text.append(delta)
      }
      if let turnID {
        state.turnID = turnID
        threadIDByTurnID[turnID] = threadID
      }
      turnStates[threadID] = state

    case "turn/completed":
      let status =
        firstString(in: nestedTurn, keys: ["status"])
        ?? firstString(in: object, keys: ["status"])
      switch status?.lowercased() {
      case "failed", "error":
        let nestedError = nestedTurn["error"]?.objectValue ?? [:]
        let message =
          firstString(in: nestedError, keys: ["message", "reason"])
          ?? firstString(in: nestedTurn, keys: ["message", "reason"])
          ?? firstString(in: object, keys: ["message", "reason"])
          ?? "Codex turn failed"
        finishTurn(
          threadID: threadID,
          turnID: turnID,
          failure: .turnFailed(Self.sanitizedMessage(message))
        )
      case "interrupted", "aborted", "cancelled", "canceled":
        finishTurn(threadID: threadID, turnID: turnID, failure: .turnInterrupted)
      default:
        finishTurn(threadID: threadID, turnID: turnID, failure: nil)
      }

    case "turn/failed":
      let errorObject = object["error"]?.objectValue
      let message =
        firstString(in: errorObject ?? [:], keys: ["message", "reason"])
        ?? firstString(in: object, keys: ["message", "reason"])
        ?? "Codex turn failed"
      finishTurn(
        threadID: threadID,
        turnID: turnID,
        failure: .turnFailed(Self.sanitizedMessage(message))
      )

    case "turn/interrupted", "turn/aborted":
      finishTurn(threadID: threadID, turnID: turnID, failure: .turnInterrupted)

    default:
      break
    }
  }

  private func finishTurn(
    threadID: String?,
    turnID: String?,
    failure: CodexAppServerError?
  ) {
    guard let resolvedThreadID = resolveThreadID(threadID: threadID, turnID: turnID),
      var state = turnStates[resolvedThreadID]
    else { return }
    if let turnID {
      state.turnID = turnID
      threadIDByTurnID[turnID] = resolvedThreadID
    }
    if let failure {
      state.failure = failure
    } else {
      state.result = CodexAppServerCompletion(
        text: state.text,
        threadID: resolvedThreadID,
        turnID: state.turnID ?? turnID ?? "",
        model: state.model,
        toolCalls: state.toolCalls
      )
    }
    let waiter = state.waiter
    state.waiter = nil
    cancelTurnTimeout(threadID: resolvedThreadID)
    turnStates[resolvedThreadID] = state
    guard let waiter else { return }
    removeTurn(threadID: resolvedThreadID)
    if let failure {
      waiter.resume(throwing: failure)
    } else if let result = state.result {
      waiter.resume(returning: result)
    } else {
      waiter.resume(throwing: CodexAppServerError.invalidResponse)
    }
  }

  private func finishLogin(loginID: String, outcome: LoginOutcome) {
    if ignoredLoginOutcomeIDs.contains(loginID) {
      activeLoginIDs.remove(loginID)
      loginOutcomes.removeValue(forKey: loginID)
      return
    }
    activeLoginIDs.remove(loginID)
    cancelLoginTimeout(loginID: loginID)
    if let waiter = loginWaiters.removeValue(forKey: loginID) {
      resumeLoginWaiter(waiter, with: outcome)
    } else {
      loginOutcomes[loginID] = outcome
    }
  }

  private func registerLogin(loginID: String) {
    clearIgnoredLoginOutcome(loginID)
    // A notification can arrive in the same read loop turn as the start
    // response. In that case the outcome is already buffered and the server
    // has no active login to cancel.
    if loginOutcomes[loginID] == nil {
      activeLoginIDs.insert(loginID)
    }
  }

  private func scheduleLoginTimeout(loginID: String) {
    loginTimeoutTasks[loginID]?.cancel()
    let timeout = loginTimeout
    loginTimeoutTasks[loginID] = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.timeoutLogin(loginID: loginID)
    }
  }

  private func cancelLoginTimeout(loginID: String) {
    loginTimeoutTasks.removeValue(forKey: loginID)?.cancel()
  }

  private func timeoutLogin(loginID: String) async {
    guard let waiter = loginWaiters.removeValue(forKey: loginID) else {
      // Completion or task cancellation won the actor race and already
      // consumed the continuation. In particular, do not cancel remotely a
      // second time from this stale timeout task.
      cancelLoginTimeout(loginID: loginID)
      return
    }
    loginOutcomes.removeValue(forKey: loginID)
    let wasActive = activeLoginIDs.remove(loginID) != nil
    cancelLoginTimeout(loginID: loginID)
    waiter.resume(throwing: CodexAppServerError.loginTimedOut)
    guard wasActive else { return }
    markLoginOutcomeIgnored(loginID)
    await sendLoginCancellation(loginID: loginID)
  }

  private func markLoginOutcomeIgnored(_ loginID: String) {
    guard ignoredLoginOutcomeIDs.insert(loginID).inserted else { return }
    ignoredLoginOutcomeOrder.append(loginID)
    while ignoredLoginOutcomeOrder.count > Self.maximumIgnoredLoginOutcomeCount {
      let evicted = ignoredLoginOutcomeOrder.removeFirst()
      ignoredLoginOutcomeIDs.remove(evicted)
    }
  }

  private func clearIgnoredLoginOutcome(_ loginID: String) {
    guard ignoredLoginOutcomeIDs.remove(loginID) != nil else { return }
    ignoredLoginOutcomeOrder.removeAll { $0 == loginID }
  }

  private func sendLoginCancellation(loginID: String) async {
    do {
      _ = try await request(
        method: "account/login/cancel",
        params: .object(["loginId": .string(loginID)])
      )
    } catch {
      // Local completion has already happened; remote cancellation is best effort.
    }
  }

  private func resumeLoginWaiter(
    _ waiter: CheckedContinuation<Void, Error>,
    with outcome: LoginOutcome
  ) {
    switch outcome {
    case .succeeded:
      waiter.resume()
    case .failed(let error):
      waiter.resume(throwing: error)
    }
  }

  private func resolveThreadID(threadID: String?, turnID: String?) -> String? {
    if let threadID, turnStates[threadID] != nil {
      return threadID
    }
    if let turnID, let threadID = threadIDByTurnID[turnID] {
      return threadID
    }
    return threadID
  }

  private func removeTurn(threadID: String) {
    cancelTurnTimeout(threadID: threadID)
    if let turnID = turnStates[threadID]?.turnID {
      threadIDByTurnID.removeValue(forKey: turnID)
    }
    turnStates.removeValue(forKey: threadID)
  }

  private func processEnded(with error: CodexAppServerError, generation: Int) {
    guard generation == transportGeneration else { return }
    isInitialized = false
    transportEnded = true
    transportEndError = error
    lineBuffer.removeAll(keepingCapacity: false)
    failAll(with: error)
    let endedTransport = transport
    Task {
      await endedTransport.terminate()
    }
  }

  private func failAll(with error: CodexAppServerError) {
    let requests = pendingRequests.values
    pendingRequests.removeAll()
    let requestTimeouts = requestTimeoutTasks.values
    requestTimeoutTasks.removeAll()
    for task in requestTimeouts {
      task.cancel()
    }
    for continuation in requests {
      continuation.resume(throwing: error)
    }

    let states = turnStates.values
    turnStates.removeAll()
    threadIDByTurnID.removeAll()
    let turnTimeouts = turnTimeoutTasks.values
    turnTimeoutTasks.removeAll()
    for task in turnTimeouts {
      task.cancel()
    }
    for state in states {
      state.waiter?.resume(throwing: error)
    }

    let waiters = loginWaiters.values
    loginWaiters.removeAll()
    loginOutcomes.removeAll()
    let timeoutTasks = loginTimeoutTasks.values
    loginTimeoutTasks.removeAll()
    activeLoginIDs.removeAll()
    ignoredLoginOutcomeIDs.removeAll()
    ignoredLoginOutcomeOrder.removeAll()
    for task in timeoutTasks {
      task.cancel()
    }
    for waiter in waiters {
      waiter.resume(throwing: error)
    }
  }

  private func parseAccountStatus(_ value: CodexAppServerJSONValue) -> CodexAppServerAccountStatus {
    let root = value.objectValue ?? [:]
    let accountValue = root["account"]
    let account = accountValue?.objectValue ?? (accountValue == nil ? root : [:])
    let accountID = firstString(in: account, keys: ["id", "accountId", "accountID"])
    let accountType = firstString(in: account, keys: ["type", "accountType"])
    let email = firstString(in: account, keys: ["email", "emailAddress"])
    let planType = firstString(in: account, keys: ["planType", "plan", "subscription"])
    let explicitAuthenticated =
      root["authenticated"]?.boolValue
      ?? root["isAuthenticated"]?.boolValue
      ?? account["authenticated"]?.boolValue
      ?? account["isAuthenticated"]?.boolValue

    let hasAccountData =
      accountID != nil || email != nil || planType != nil
      || (accountType != nil && accountType != "apiKey")
    let isAccountObjectPresent =
      (accountValue?.objectValue != nil) && !(accountValue?.objectValue?.isEmpty ?? true)

    let authenticated: Bool
    if let explicitAuthenticated {
      authenticated = explicitAuthenticated
    } else if isAccountObjectPresent && hasAccountData {
      authenticated = true
    } else if let requiresAuth = root["requiresOpenaiAuth"]?.boolValue
      ?? root["requiresAuth"]?.boolValue
    {
      authenticated = !requiresAuth
    } else {
      authenticated = hasAccountData
    }

    return CodexAppServerAccountStatus(
      isAuthenticated: authenticated,
      accountID: accountID,
      accountType: accountType,
      email: email,
      planType: planType
    )
  }

  private func parseRateLimits(_ value: CodexAppServerJSONValue) -> CodexAppServerRateLimits {
    let root = value.objectValue ?? [:]
    let object = root["rateLimits"]?.objectValue ?? root
    let primary = parseRateLimitWindow(object["primary"] ?? object["primaryWindow"])
    let secondary = parseRateLimitWindow(object["secondary"] ?? object["secondaryWindow"])
    let credits =
      object["creditsRemaining"]?.doubleValue
      ?? object["credits"]?.objectValue?["remaining"]?.doubleValue
    let planType = firstString(in: object, keys: ["planType", "plan"])
    return CodexAppServerRateLimits(
      primary: primary,
      secondary: secondary,
      creditsRemaining: credits,
      planType: planType
    )
  }

  private func parseRateLimitWindow(_ value: CodexAppServerJSONValue?)
    -> CodexAppServerRateLimitWindow?
  {
    guard let object = value?.objectValue else { return nil }
    let usedPercent =
      object["usedPercent"]?.doubleValue
      ?? object["used"]?.doubleValue
    let windowMinutes =
      object["windowMinutes"]?.intValue
      ?? object["windowDurationMinutes"]?.intValue
      ?? object["windowDurationMins"]?.intValue
    let resetValue = object["resetsAt"] ?? object["resetAt"]
    var resetsAt: Date?
    if let seconds = resetValue?.doubleValue {
      resetsAt = Date(timeIntervalSince1970: seconds)
    } else if let string = resetValue?.stringValue {
      resetsAt = ISO8601DateFormatter().date(from: string)
    }
    return CodexAppServerRateLimitWindow(
      usedPercent: usedPercent,
      windowMinutes: windowMinutes,
      resetsAt: resetsAt
    )
  }

  private func identifier(
    in value: CodexAppServerJSONValue,
    nestedKeys: [String]
  ) -> String? {
    guard let root = value.objectValue else { return nil }
    for key in nestedKeys {
      if let string = root[key]?.stringValue {
        return string
      }
      if let nested = root[key]?.objectValue {
        for nestedKey in ["id", "threadId", "threadID", "turnId", "turnID"] {
          if let string = nested[nestedKey]?.stringValue {
            return string
          }
        }
      }
    }
    return nil
  }

  private func firstString(
    in object: [String: CodexAppServerJSONValue],
    keys: [String]
  ) -> String? {
    for key in keys {
      if let value = object[key]?.stringValue {
        return value
      }
    }
    return nil
  }

  private func firstNonEmptyString(
    in object: [String: CodexAppServerJSONValue],
    keys: [String]
  ) -> String? {
    for key in keys {
      guard let value = object[key]?.stringValue else { continue }
      let trimmed = Self.trimmedNonEmpty(value)
      if let trimmed { return trimmed }
    }
    return nil
  }

  private static func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func validatedLoginURL(_ rawValue: String) -> URL? {
    guard let url = URL(string: rawValue),
      url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
      let host = url.host,
      !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      url.user == nil,
      url.password == nil
    else {
      return nil
    }
    return url
  }

  private static func sanitizedMessage(_ message: String) -> String {
    let lowercased = message.lowercased()
    if lowercased.contains("bearer ")
      || lowercased.contains("access_token")
      || lowercased.contains("refresh_token")
      || lowercased.contains("api_key")
      || message.contains("eyJ")
    {
      return "Sensitive authentication details omitted."
    }
    return String(message.prefix(512))
  }

  private static func mapError(_ error: Error) -> CodexAppServerError {
    if let error = error as? CodexAppServerError {
      return error
    }
    if error is CancellationError {
      return .cancelled
    }
    return .processExited
  }
}
