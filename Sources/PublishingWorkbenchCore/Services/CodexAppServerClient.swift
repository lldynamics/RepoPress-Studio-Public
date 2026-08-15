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

/// A `Process` backed stdio transport for `codex app-server`.
public final class CodexAppServerProcessTransport: CodexAppServerTransport, @unchecked Sendable {
  public static let defaultArguments = ["app-server", "--listen", "stdio://"]
  public static let maximumReadChunkByteCount = 32 * 1_024
  public static let maximumStderrChunkByteCount = 16 * 1_024

  private let configuredExecutableURL: URL?
  private let arguments: [String]
  private let lock = NSLock()
  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private var stderrDrainTask: Task<Void, Never>?
  private var started = false
  private var terminated = false

  public init(
    executableURL: URL? = nil,
    arguments: [String] = CodexAppServerProcessTransport.defaultArguments
  ) {
    self.configuredExecutableURL = executableURL
    self.arguments = arguments
  }

  public static func discoverExecutableURL() -> URL? {
    let fileManager = FileManager.default
    let preferredPaths = [
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
    ]
    for path in preferredPaths where fileManager.isExecutableFile(atPath: path) {
      return URL(fileURLWithPath: path)
    }

    let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
      .split(separator: ":", omittingEmptySubsequences: true)
      .map(String.init) ?? []
    for entry in pathEntries {
      let candidate = URL(fileURLWithPath: entry).appendingPathComponent("codex")
      if fileManager.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  public func start() async throws {
    try withLock {
      if started {
        return
      }
      guard !terminated else {
        throw CodexAppServerError.processExited
      }

      let executableURL = configuredExecutableURL ?? Self.discoverExecutableURL()
      guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        throw CodexAppServerError.executableNotFound
      }

      let process = Process()
      let inputPipe = Pipe()
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.executableURL = executableURL
      process.arguments = arguments
      process.standardInput = inputPipe
      process.standardOutput = outputPipe
      process.standardError = errorPipe

      do {
        try process.run()
      } catch {
        throw CodexAppServerError.processExited
      }

      self.process = process
      self.input = inputPipe.fileHandleForWriting
      self.output = outputPipe.fileHandleForReading
      self.started = true

      // Drain stderr so a noisy process cannot block on a full pipe.  We intentionally discard it:
      // stderr can contain command-line diagnostics or credentials and must never be surfaced as a
      // client error or written to logs.  The read size is bounded on every iteration.
      let stderr = errorPipe.fileHandleForReading
      self.stderrDrainTask = Task.detached(priority: .utility) {
        while !Task.isCancelled {
          do {
            guard let data = try stderr.read(upToCount: Self.maximumStderrChunkByteCount),
                  !data.isEmpty else {
              return
            }
            _ = data.count
          } catch {
            return
          }
        }
      }
    }
  }

  public func send(_ data: Data) async throws {
    let handle: FileHandle = try withLock {
      guard started, !terminated, let input else {
        throw CodexAppServerError.processNotRunning
      }
      return input
    }

    do {
      try handle.write(contentsOf: data)
    } catch {
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

    do {
      return try await Task.detached(priority: .utility) {
        try handle.read(upToCount: Self.maximumReadChunkByteCount)
      }.value
    } catch is CancellationError {
      throw CodexAppServerError.cancelled
    } catch {
      throw CodexAppServerError.processExited
    }
  }

  public func terminate() async {
    let snapshot: (Process?, [FileHandle]) = withLock {
      if terminated {
        return (nil, [])
      }
      terminated = true
      let process = self.process
      let handles = [input, output].compactMap { $0 }
      self.input = nil
      self.output = nil
      stderrDrainTask?.cancel()
      stderrDrainTask = nil
      return (process, handles)
    }
    let process = snapshot.0
    let handles = snapshot.1

    if let process, process.isRunning {
      process.terminate()
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

  deinit {
    lock.lock()
    let process = self.process
    let handles = [input, output].compactMap { $0 }
    stderrDrainTask?.cancel()
    lock.unlock()
    if let process, process.isRunning {
      process.terminate()
    }
    for handle in handles {
      try? handle.close()
    }
  }
}

/// A small, actor-isolated JSON-RPC client for the Codex app-server protocol.
public actor CodexAppServerClient {
  /// The shared runtime used by the settings/login flow and AI requests.
  public static let shared = CodexAppServerClient()

  private let transport: any CodexAppServerTransport
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  private var nextRequestID = 0
  private var pendingRequests: [Int: CheckedContinuation<CodexAppServerJSONValue, Error>] = [:]
  private var startupTask: Task<Void, Error>?
  private var readerTask: Task<Void, Never>?
  private var isInitialized = false
  private var transportEnded = false
  private var lineBuffer = Data()

  private struct TurnState {
    let threadID: String
    var model: String?
    var turnID: String?
    var text = ""
    var result: CodexAppServerCompletion?
    var failure: CodexAppServerError?
    var waiter: CheckedContinuation<CodexAppServerCompletion, Error>?
  }

  private var turnStates: [String: TurnState] = [:]
  private var threadIDByTurnID: [String: String] = [:]

  private static let threadDeveloperInstructions =
    "Answer only from the supplied text. Never inspect the filesystem, run commands, or use tools."

  public init(
    executableURL: URL? = nil,
    transport: (any CodexAppServerTransport)? = nil
  ) {
    self.transport = transport ?? CodexAppServerProcessTransport(executableURL: executableURL)
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    self.encoder.outputFormatting = [.sortedKeys]
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
      params: .object(["type": .string("chatgpt")])
    )
    guard let object = value.objectValue else {
      throw CodexAppServerError.invalidResponse
    }
    let loginObject = object["login"]?.objectValue ?? object
    let loginID = firstString(in: loginObject, keys: ["loginId", "loginID", "id"])
    let authURLString = firstString(in: loginObject, keys: ["authUrl", "authURL", "url"])
    guard let loginID, !loginID.isEmpty,
          let authURLString, let authURL = URL(string: authURLString) else {
      throw CodexAppServerError.invalidResponse
    }
    return CodexAppServerLoginResult(loginID: loginID, authURL: authURL)
  }

  public func logout() async throws {
    _ = try await request(method: "account/logout", params: .object([:]))
  }

  public func rateLimits() async throws -> CodexAppServerRateLimits {
    let value = try await request(method: "account/rateLimits/read", params: .object([:]))
    return parseRateLimits(value)
  }

  public func complete(
    prompt: String,
    model: String? = nil,
    workingDirectory: URL? = nil
  ) async throws -> CodexAppServerCompletion {
    try await ensureStarted()
    let thread = try await startThread(model: model, workingDirectory: workingDirectory)
    let threadID = thread.id
    turnStates[threadID] = TurnState(threadID: threadID, model: thread.model)

    do {
      let turnID = try await startTurn(threadID: threadID, prompt: prompt)
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
    workingDirectory: URL? = nil
  ) async throws -> String {
    try await complete(
      prompt: prompt,
      model: model,
      workingDirectory: workingDirectory
    ).text
  }

  public func shutdown() async {
    readerTask?.cancel()
    readerTask = nil
    startupTask?.cancel()
    startupTask = nil
    isInitialized = false
    transportEnded = true
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

    let task = Task<Void, Error> { [weak self] in
      guard let self else { throw CodexAppServerError.processExited }
      try await self.startAndHandshake()
    }
    startupTask = task
    do {
      try await task.value
      startupTask = nil
    } catch {
      startupTask = nil
      throw Self.mapError(error)
    }
  }

  private func startAndHandshake() async throws {
    do {
      transportEnded = false
      try await transport.start()
      readerTask = Task { [weak self] in
        await self?.readLoop()
      }
      _ = try await requestWithoutStartup(
        method: "initialize",
        params: .object([
          "capabilities": .object(["experimentalApi": .bool(false)]),
          "clientInfo": .object([
            "name": .string("RepoPress Studio"),
            "title": .string("RepoPress Studio"),
            "version": .string("1.0.1"),
          ]),
        ])
      )
      try await sendNotification(method: "initialized", params: nil)
      guard !transportEnded else {
        throw CodexAppServerError.endOfStream
      }
      isInitialized = true
    } catch {
      isInitialized = false
      readerTask?.cancel()
      readerTask = nil
      failAll(with: Self.mapError(error))
      await transport.terminate()
      throw Self.mapError(error)
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

    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        pendingRequests[requestID] = continuation
        Task { [weak self] in
          guard let self else { return }
          do {
            try await self.transport.send(data)
          } catch {
            await self.failPendingRequest(
              requestID: requestID,
              error: Self.mapError(error)
            )
          }
        }
      }
    }, onCancel: {
      Task { [weak self] in
        await self?.cancelPendingRequest(requestID: requestID)
      }
    })
  }

  private func sendNotification(
    method: String,
    params: CodexAppServerJSONValue?
  ) async throws {
    var object: [String: CodexAppServerJSONValue] = ["method": .string(method)]
    if let params {
      object["params"] = params
    }
    do {
      let data = try encoder.encode(CodexAppServerJSONValue.object(object)) + Data([0x0A])
      try await transport.send(data)
    } catch let error as CodexAppServerError {
      throw error
    } catch {
      throw CodexAppServerError.processExited
    }
  }

  private func cancelPendingRequest(requestID: Int) {
    guard let continuation = pendingRequests.removeValue(forKey: requestID) else { return }
    continuation.resume(throwing: CodexAppServerError.cancelled)
  }

  private func failPendingRequest(requestID: Int, error: CodexAppServerError) {
    guard let continuation = pendingRequests.removeValue(forKey: requestID) else { return }
    continuation.resume(throwing: error)
  }

  private func startThread(
    model: String?,
    workingDirectory: URL?
  ) async throws -> (id: String, model: String?) {
    var params: [String: CodexAppServerJSONValue] = [
      "approvalPolicy": .string("never"),
      "developerInstructions": .string(Self.threadDeveloperInstructions),
      "ephemeral": .bool(true),
      "sandbox": .string("read-only"),
    ]
    if let model, !model.isEmpty {
      params["model"] = .string(model)
    }
    if let workingDirectory {
      params["cwd"] = .string(workingDirectory.path)
    }
    let value = try await requestWithoutStartup(method: "thread/start", params: .object(params))
    guard let threadID = identifier(in: value, nestedKeys: ["thread", "threadId", "threadID", "id"]),
          !threadID.isEmpty else {
      throw CodexAppServerError.invalidResponse
    }
    let responseModel: String?
    if let root = value.objectValue {
      responseModel = firstString(in: root, keys: ["model"])
        ?? firstString(in: root["thread"]?.objectValue ?? [:], keys: ["model"])
    } else {
      responseModel = nil
    }
    return (threadID, responseModel ?? model)
  }

  private func startTurn(threadID: String, prompt: String) async throws -> String {
    let params: [String: CodexAppServerJSONValue] = [
      "input": .array([
        .object([
          "text": .string(prompt),
          "type": .string("text"),
        ])
      ]),
      "threadId": .string(threadID),
    ]
    let value = try await requestWithoutStartup(method: "turn/start", params: .object(params))
    guard let turnID = identifier(in: value, nestedKeys: ["turn", "turnId", "turnID", "id"]),
          !turnID.isEmpty else {
      throw CodexAppServerError.invalidResponse
    }
    return turnID
  }

  private func waitForTurn(threadID: String) async throws -> CodexAppServerCompletion {
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        guard var state = turnStates[threadID] else {
          continuation.resume(throwing: CodexAppServerError.invalidResponse)
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
        }
      }
    }, onCancel: {
      Task { [weak self] in
        await self?.cancelTurn(threadID: threadID)
      }
    })
  }

  private func cancelTurn(threadID: String) {
    guard var state = turnStates[threadID] else { return }
    let waiter = state.waiter
    let turnID = state.turnID
    state.waiter = nil
    state.failure = .cancelled
    turnStates[threadID] = state
    waiter?.resume(throwing: CodexAppServerError.cancelled)
    if waiter != nil {
      removeTurn(threadID: threadID)
    }
    guard let turnID else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.requestWithoutStartup(
          method: "turn/interrupt",
          params: .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID),
          ])
        )
      } catch {
        // Local cancellation has already completed; remote interruption is best effort.
      }
    }
  }

  private func readLoop() async {
    do {
      while !Task.isCancelled {
        guard let chunk = try await transport.receive() else {
          processEnded(with: .endOfStream)
          return
        }
        guard !chunk.isEmpty else { continue }
        try consume(chunk: chunk)
      }
    } catch {
      processEnded(with: Self.mapError(error))
    }
  }

  private func consume(chunk: Data) throws {
    lineBuffer.append(chunk)
    while let newline = lineBuffer.firstIndex(of: 0x0A) {
      let line = Data(lineBuffer[..<newline])
      let end = lineBuffer.index(after: newline)
      lineBuffer.removeSubrange(lineBuffer.startIndex..<end)
      guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { continue }
      let envelope: CodexAppServerRPCEnvelope
      do {
        envelope = try decoder.decode(CodexAppServerRPCEnvelope.self, from: line)
      } catch {
        throw CodexAppServerError.invalidJSON
      }
      handle(envelope: envelope)
    }
  }

  private func handle(envelope: CodexAppServerRPCEnvelope) {
    if let method = envelope.method {
      handleNotification(method: method, params: envelope.params)
      return
    }
    guard let requestID = envelope.id else { return }
    // A cancelled request may still receive a late response. It belongs to an
    // already-consumed request ID and must not tear down the shared process.
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

  private func handleNotification(method: String, params: CodexAppServerJSONValue?) {
    guard let params else { return }
    let object = params.objectValue ?? [:]
    let nestedTurn = object["turn"]?.objectValue ?? [:]
    let threadID = firstString(
      in: object,
      keys: ["threadId", "threadID"]
    ) ?? firstString(in: nestedTurn, keys: ["threadId", "threadID"])
    let turnID = firstString(
      in: object,
      keys: ["turnId", "turnID", "id"]
    ) ?? firstString(in: nestedTurn, keys: ["id", "turnId", "turnID"])

    switch method {
    case "item/agentMessage/delta":
      guard let threadID = resolveThreadID(threadID: threadID, turnID: turnID),
            var state = turnStates[threadID] else { return }
      if let delta = firstString(in: object, keys: ["delta", "text"]) {
        state.text.append(delta)
      }
      if let turnID {
        state.turnID = turnID
        threadIDByTurnID[turnID] = threadID
      }
      turnStates[threadID] = state

    case "turn/completed":
      let status = firstString(in: nestedTurn, keys: ["status"])
        ?? firstString(in: object, keys: ["status"])
      switch status?.lowercased() {
      case "failed", "error":
        let nestedError = nestedTurn["error"]?.objectValue ?? [:]
        let message = firstString(in: nestedError, keys: ["message", "reason"])
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
      let message = firstString(in: errorObject ?? [:], keys: ["message", "reason"])
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
          var state = turnStates[resolvedThreadID] else { return }
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
        model: state.model
      )
    }
    let waiter = state.waiter
    state.waiter = nil
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
    if let turnID = turnStates[threadID]?.turnID {
      threadIDByTurnID.removeValue(forKey: turnID)
    }
    turnStates.removeValue(forKey: threadID)
  }

  private func processEnded(with error: CodexAppServerError) {
    isInitialized = false
    transportEnded = true
    lineBuffer.removeAll(keepingCapacity: false)
    failAll(with: error)
  }

  private func failAll(with error: CodexAppServerError) {
    let requests = pendingRequests.values
    pendingRequests.removeAll()
    for continuation in requests {
      continuation.resume(throwing: error)
    }

    let states = turnStates.values
    turnStates.removeAll()
    threadIDByTurnID.removeAll()
    for state in states {
      state.waiter?.resume(throwing: error)
    }
  }

  private func parseAccountStatus(_ value: CodexAppServerJSONValue) -> CodexAppServerAccountStatus {
    let root = value.objectValue ?? [:]
    let account = root["account"]?.objectValue ?? root
    let accountID = firstString(in: account, keys: ["id", "accountId", "accountID"])
    let accountType = firstString(in: account, keys: ["type", "accountType"])
    let email = firstString(in: account, keys: ["email", "emailAddress"])
    let planType = firstString(in: account, keys: ["planType", "plan", "subscription"])
    let requiresAuth = root["requiresOpenaiAuth"]?.boolValue
      ?? root["requiresAuth"]?.boolValue
    let authenticated = root["authenticated"]?.boolValue
      ?? root["isAuthenticated"]?.boolValue
      ?? (requiresAuth.map { !$0 })
      ?? (!account.isEmpty)
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
    let credits = object["creditsRemaining"]?.doubleValue
      ?? object["credits"]?.objectValue?["remaining"]?.doubleValue
    let planType = firstString(in: object, keys: ["planType", "plan"])
    return CodexAppServerRateLimits(
      primary: primary,
      secondary: secondary,
      creditsRemaining: credits,
      planType: planType
    )
  }

  private func parseRateLimitWindow(_ value: CodexAppServerJSONValue?) -> CodexAppServerRateLimitWindow? {
    guard let object = value?.objectValue else { return nil }
    let usedPercent = object["usedPercent"]?.doubleValue
      ?? object["used"]?.doubleValue
    let windowMinutes = object["windowMinutes"]?.intValue
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

  private static func sanitizedMessage(_ message: String) -> String {
    let lowercased = message.lowercased()
    if lowercased.contains("bearer ")
      || lowercased.contains("access_token")
      || lowercased.contains("refresh_token")
      || lowercased.contains("api_key")
      || message.contains("eyJ") {
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
