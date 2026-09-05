import Darwin
import Dispatch
import Foundation
import MCP
import PublishingAICore

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

enum PublishingMCPProcessLauncher {
  static func configureSpawnAttributes(_ attributes: inout posix_spawnattr_t?) -> Int32 {
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    let flagsResult = posix_spawnattr_setflags(&attributes, flags)
    guard flagsResult == 0 else { return flagsResult }
    return posix_spawnattr_setpgroup(&attributes, 0)
  }

  fileprivate static func launch(
    executableURL: URL,
    arguments: [String],
    workingDirectoryURL: URL?,
    environment: [String: String],
    standardInput: Int32,
    standardOutput: Int32,
    standardError: Int32
  ) throws -> PublishingMCPSpawnedProcess {
    let argumentVector = try PublishingMCPCStringArray(
      [executableURL.path] + arguments
    )
    let environmentVector = try PublishingMCPCStringArray(
      environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    )

    var fileActions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw PublishingMCPClientError.connectionFailed
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    for (source, destination) in [
      (standardInput, STDIN_FILENO),
      (standardOutput, STDOUT_FILENO),
      (standardError, STDERR_FILENO),
    ] {
      guard posix_spawn_file_actions_adddup2(&fileActions, source, destination) == 0 else {
        throw PublishingMCPClientError.connectionFailed
      }
      if source != destination,
        posix_spawn_file_actions_addclose(&fileActions, source) != 0
      {
        throw PublishingMCPClientError.connectionFailed
      }
    }

    if let workingDirectoryURL {
      let changeDirectoryResult = workingDirectoryURL.path.withCString { path in
        if #available(macOS 26.0, *) {
          posix_spawn_file_actions_addchdir(&fileActions, path)
        } else {
          posix_spawn_file_actions_addchdir_np(&fileActions, path)
        }
      }
      guard changeDirectoryResult == 0 else {
        throw PublishingMCPClientError.connectionFailed
      }
    }

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw PublishingMCPClientError.connectionFailed
    }
    defer { posix_spawnattr_destroy(&attributes) }
    guard configureSpawnAttributes(&attributes) == 0 else {
      throw PublishingMCPClientError.connectionFailed
    }

    var processIdentifier: pid_t = 0
    let spawnResult = executableURL.path.withCString { executablePath in
      posix_spawn(
        &processIdentifier,
        executablePath,
        &fileActions,
        &attributes,
        argumentVector.pointer,
        environmentVector.pointer
      )
    }
    guard spawnResult == 0, processIdentifier > 0 else {
      throw PublishingMCPClientError.connectionFailed
    }
    // POSIX_SPAWN_SETPGROUP with pgroup 0 is the atomic creation contract.
    // A post-spawn getpgid check is inherently racy: a leader may already be
    // an unreaped zombie while ordinary descendants remain in its group.
    return PublishingMCPSpawnedProcess(processIdentifier: processIdentifier)
  }
}

private final class PublishingMCPCStringArray {
  let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
  private let strings: [UnsafeMutablePointer<CChar>]

  init(_ values: [String]) throws {
    var strings: [UnsafeMutablePointer<CChar>] = []
    strings.reserveCapacity(values.count)
    for value in values {
      guard let string = strdup(value) else {
        for allocatedString in strings {
          free(allocatedString)
        }
        throw PublishingMCPClientError.connectionFailed
      }
      strings.append(string)
    }
    let pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
      capacity: strings.count + 1
    )
    pointer.initialize(repeating: nil, count: strings.count + 1)
    for (index, string) in strings.enumerated() {
      pointer[index] = string
    }
    self.pointer = pointer
    self.strings = strings
  }

  deinit {
    for string in strings {
      free(string)
    }
    pointer.deinitialize(count: strings.count + 1)
    pointer.deallocate()
  }
}

private final class PublishingMCPSpawnedProcess {
  let processIdentifier: pid_t
  let processGroupIdentifier: pid_t
  private let terminator: PublishingMCPProcessTerminator

  init(processIdentifier: pid_t) {
    self.processIdentifier = processIdentifier
    self.processGroupIdentifier = processIdentifier
    self.terminator = PublishingMCPProcessTerminator(
      processIdentifier: processIdentifier,
      processGroupIdentifier: processIdentifier
    )
    // WNOWAIT observes even an already-exited leader without reaping it. The
    // terminator retains the sole waitpid ownership until the group has first
    // received its final signal, preventing PID/PGID reuse during cleanup.
    DispatchQueue.global(qos: .utility).async { [terminator] in
      var information = siginfo_t()
      while Darwin.waitid(
        P_PID,
        id_t(processIdentifier),
        &information,
        WEXITED | WNOWAIT
      ) == -1, errno == EINTR {}
      terminator.terminateThenKillAfterGracePeriod()
    }
  }

  deinit {
    terminator.terminateThenKillAfterGracePeriod()
  }

  var isRunning: Bool {
    Darwin.kill(processIdentifier, 0) == 0 || errno == EPERM
  }

  func terminateThenKillAfterGracePeriod() {
    terminator.terminateThenKillAfterGracePeriod()
  }
}

protocol PublishingMCPClientSession: AnyObject, Sendable {
  func connect() async throws
  func listTools() async throws -> [PublishingMCPDiscoveredTool]
  func call(
    remoteToolName: String,
    argumentsJSON: String
  ) async throws -> PublishingMCPCallResult
  func close() async
}

typealias PublishingMCPClientSessionFactory =
  @Sendable (PublishingMCPSourceConfiguration) async -> any PublishingMCPClientSession

/// Owns the local Process, pipes, MCP transport, and SDK client for a single
/// connection. It is deliberately internal so MCP session concepts do not
/// escape into the Agent core.
actor PublishingMCPStdioSession: PublishingMCPClientSession {
  private let configuration: PublishingMCPSourceConfiguration
  private var process: PublishingMCPSpawnedProcess?
  private var client: Client?
  private var transport: StdioTransport?
  private var stdinPipe: Pipe?
  private var stdoutPipe: Pipe?
  private var stdoutRelay: PublishingMCPFrameRelay?
  private var stderrDrainer: PublishingMCPStderrDrainer?
  private var hasExceededFrameLimit = false
  private var activeTimedOperationCount = 0
  private var retiredSDKHandles: [FileHandle] = []

  init(configuration: PublishingMCPSourceConfiguration) {
    self.configuration = configuration
  }

  func connect() async throws {
    guard client == nil else { return }
    hasExceededFrameLimit = false
    guard configuration.hasCurrentFilesystemIdentity(),
      FileManager.default.isExecutableFile(atPath: configuration.executableURL.path)
    else {
      throw PublishingMCPClientError.connectionFailed
    }

    let stdinPipe = Pipe()
    let rawStdoutPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdoutRelay = PublishingMCPFrameRelay(
      input: rawStdoutPipe.fileHandleForReading,
      output: stdoutPipe.fileHandleForWriting,
      maximumFrameByteCount: configuration.maximumRawMessageByteCount
    )

    let stderrDrainer = PublishingMCPStderrDrainer(
      handle: stderrPipe.fileHandleForReading,
      maximumDiscardedBytes: 64 * 1_024
    )
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.stdoutRelay = stdoutRelay
    self.stderrDrainer = stderrDrainer
    stdoutRelay.start()
    stderrDrainer.start()

    do {
      let process = try PublishingMCPProcessLauncher.launch(
        executableURL: configuration.executableURL,
        arguments: configuration.arguments,
        workingDirectoryURL: configuration.workingDirectoryURL,
        environment: Self.launchEnvironment(overrides: configuration.environmentOverrides),
        standardInput: stdinPipe.fileHandleForReading.fileDescriptor,
        standardOutput: rawStdoutPipe.fileHandleForWriting.fileDescriptor,
        standardError: stderrPipe.fileHandleForWriting.fileDescriptor
      )
      self.process = process
      stdinPipe.fileHandleForReading.closeFile()
      rawStdoutPipe.fileHandleForWriting.closeFile()
      stderrPipe.fileHandleForWriting.closeFile()
      let transport = StdioTransport(
        input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
        output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
      )
      let client = Client(
        name: "PersonalSitePublisherMac",
        version: "1",
        capabilities: .init(),
        configuration: .strict
      )
      self.transport = transport
      self.client = client
      _ = try await withTimeout(milliseconds: configuration.connectionTimeoutMilliseconds) {
        try await client.connect(transport: transport)
      }
    } catch {
      let mappedError = mappedTransportError(error)
      await close()
      throw mappedError is PublishingMCPClientError
        ? mappedError : PublishingMCPClientError.connectionFailed
    }
  }

  func listTools() async throws -> [PublishingMCPDiscoveredTool] {
    try assertRunning()
    guard let client else { throw PublishingMCPClientError.connectionFailed }
    var cursor: String?
    var pages = 0
    var tools: [PublishingMCPDiscoveredTool] = []
    var remoteNames = Set<String>()

    repeat {
      pages += 1
      guard pages <= configuration.maximumToolPageCount else {
        throw PublishingMCPClientError.discoveryLimitExceeded
      }
      let pageCursor = cursor
      let page: (tools: [Tool], nextCursor: String?)
      do {
        page = try await withTimeout(milliseconds: configuration.connectionTimeoutMilliseconds) {
          try await client.listTools(cursor: pageCursor)
        }
      } catch {
        throw mappedTransportError(error)
      }
      for tool in page.tools {
        let checked = try Self.checkedTool(tool, configuration: configuration)
        guard remoteNames.insert(checked.remoteName).inserted else {
          throw PublishingMCPClientError.invalidRemoteTool
        }
        tools.append(checked)
        guard tools.count <= configuration.maximumToolCount else {
          throw PublishingMCPClientError.discoveryLimitExceeded
        }
      }
      cursor = page.nextCursor
    } while cursor != nil

    return tools.sorted { $0.remoteName < $1.remoteName }
  }

  func call(remoteToolName: String, argumentsJSON: String) async throws
    -> PublishingMCPCallResult
  {
    try assertRunning()
    guard let client else { throw PublishingMCPClientError.connectionFailed }
    guard argumentsJSON.utf8.count <= configuration.maximumInputByteCount,
      let arguments = Self.decodeArguments(argumentsJSON)
    else {
      throw PublishingMCPClientError.invocationMismatch
    }

    let response: CallTool.Result
    do {
      response = try await withTimeout(milliseconds: configuration.commandTimeoutMilliseconds) {
        let request: RequestContext<CallTool.Result> = try await client.callTool(
          name: remoteToolName,
          arguments: arguments
        )
        return try await request.value
      }
    } catch {
      throw mappedTransportError(error)
    }
    guard response.structuredContent == nil else {
      return PublishingMCPCallResult(
        content: "External MCP tool returned unsupported structured content.",
        isError: true
      )
    }
    guard response.content.count <= configuration.maximumContentBlockCount else {
      return PublishingMCPCallResult(
        content: "External MCP tool returned too many content blocks.",
        isError: true
      )
    }
    var textBlocks: [String] = []
    var byteCount = 0
    for content in response.content {
      guard case .text(let text, _, _) = content else {
        return PublishingMCPCallResult(
          content: "External MCP tool returned unsupported content.",
          isError: true
        )
      }
      if !textBlocks.isEmpty {
        byteCount = byteCount.saturatingAdd(1)
      }
      byteCount = byteCount.saturatingAdd(text.utf8.count)
      guard byteCount <= configuration.maximumOutputByteCount else {
        return PublishingMCPCallResult(
          content: "External MCP tool returned more content than allowed.",
          isError: true
        )
      }
      textBlocks.append(text)
    }
    let content = textBlocks.joined(separator: "\n")
    return PublishingMCPCallResult(content: content, isError: response.isError == true)
  }

  func close() async {
    await tearDownTransport()
  }

  private func assertRunning() throws {
    guard process?.isRunning == true else { throw PublishingMCPClientError.processExited }
  }

  private func withTimeout<T: Sendable>(
    milliseconds: UInt64,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    activeTimedOperationCount += 1
    defer {
      activeTimedOperationCount -= 1
      closeRetiredSDKHandlesIfPossible()
    }
    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask(operation: operation)
      group.addTask {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        throw PublishingMCPClientError.requestTimedOut
      }
      defer { group.cancelAll() }
      do {
        guard let value = try await group.next() else {
          throw PublishingMCPClientError.connectionFailed
        }
        return value
      } catch let error as PublishingMCPClientError where error == .requestTimedOut {
        // Disconnect after the timer wins. This unblocks the pending SDK
        // continuation before the task group leaves scope, while preserving a
        // deterministic timeout error for callers.
        await forceCloseForTimeout()
        throw error
      } catch is CancellationError {
        await forceCloseForTimeout()
        throw CancellationError()
      } catch {
        throw error
      }
    }
  }

  private func forceCloseForTimeout() async {
    await tearDownTransport()
  }

  /// Stops peer I/O before awaiting SDK actor cleanup, then retires the SDK
  /// handles only after every timed operation has left its task-group scope.
  /// This keeps teardown bounded without exposing reused descriptor numbers to
  /// late SDK reads or writes.
  private func tearDownTransport() async {
    let clientToDisconnect = client
    let transportToDisconnect = clientToDisconnect == nil ? transport : nil
    let processToTerminate = process
    let stdinPipeToClose = stdinPipe
    let stdoutPipeToClose = stdoutPipe
    let stdoutRelayToStop = stdoutRelay
    let stderrDrainerToStop = stderrDrainer

    if stdoutRelayToStop?.didExceedFrameLimit == true {
      hasExceededFrameLimit = true
    }
    client = nil
    transport = nil
    process = nil
    stdinPipe = nil
    stdoutPipe = nil
    stdoutRelay = nil
    stderrDrainer = nil

    // Close the relay's writer and terminate the child first. These peer-side
    // closures make SDK reads/writes finite without closing a descriptor that
    // an in-flight SDK task may still reference by its reusable integer value.
    stdoutRelayToStop?.stop()
    processToTerminate?.terminateThenKillAfterGracePeriod()
    stderrDrainerToStop?.stop()

    if let clientToDisconnect {
      await clientToDisconnect.disconnect()
    } else if let transportToDisconnect {
      await transportToDisconnect.disconnect()
    }

    if let handle = stdinPipeToClose?.fileHandleForWriting {
      retiredSDKHandles.append(handle)
    }
    if let handle = stdoutPipeToClose?.fileHandleForReading {
      retiredSDKHandles.append(handle)
    }
    closeRetiredSDKHandlesIfPossible()
  }

  private func closeRetiredSDKHandlesIfPossible() {
    guard activeTimedOperationCount == 0, !retiredSDKHandles.isEmpty else { return }
    let handles = retiredSDKHandles
    retiredSDKHandles.removeAll(keepingCapacity: true)
    for handle in handles {
      handle.closeFile()
    }
  }

  private func mappedTransportError(_ error: Error) -> Error {
    hasExceededFrameLimit || stdoutRelay?.didExceedFrameLimit == true
      ? PublishingMCPClientError.outputLimitExceeded : error
  }

  private static func launchEnvironment(overrides: [String: String]) -> [String: String] {
    let inherited = ProcessInfo.processInfo.environment
    let permittedInheritedKeys: Set<String> = [
      "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "TMPDIR", "USER",
    ]
    var environment = inherited.filter { permittedInheritedKeys.contains($0.key) }
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["NO_COLOR"] = "1"
    for (key, value) in overrides {
      environment[key] = value
    }
    return environment
  }

  private static func checkedTool(
    _ tool: Tool,
    configuration: PublishingMCPSourceConfiguration
  ) throws -> PublishingMCPDiscoveredTool {
    guard isValidRemoteToolName(tool.name) else { throw PublishingMCPClientError.invalidRemoteTool }
    let schemaData = try JSONEncoder().encode(tool.inputSchema)
    guard schemaData.count <= configuration.maximumInputByteCount,
      (tool.description?.utf8.count ?? 0) <= configuration.maximumToolDescriptionByteCount,
      let schema = try? JSONDecoder().decode(AIStructuredOutputJSONValue.self, from: schemaData),
      case .object(let object) = schema,
      case .string(let type)? = object["type"], type == "object",
      PublishingMCPJSONSchemaValidator.isSupportedRootSchema(schema)
    else {
      throw PublishingMCPClientError.invalidRemoteTool
    }
    return PublishingMCPDiscoveredTool(
      remoteName: tool.name,
      description: tool.description,
      inputSchema: schema
    )
  }

  private static func decodeArguments(_ json: String) -> [String: Value]? {
    guard let data = json.data(using: .utf8),
      let value = try? JSONDecoder().decode(Value.self, from: data),
      case .object(let object) = value
    else { return nil }
    return object
  }

  private static func isValidRemoteToolName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 128
      && name.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 48 && scalar.value <= 57)
          || (scalar.value >= 65 && scalar.value <= 90)
          || (scalar.value >= 97 && scalar.value <= 122)
          || scalar == "-" || scalar == "_" || scalar == "."
      }
  }
}

private final class PublishingMCPStderrDrainer: @unchecked Sendable {
  private let handle: FileHandle
  private let lock = NSLock()
  private var discardedByteCount = 0
  private var isStopped = false
  private let maximumDiscardedBytes: Int

  init(handle: FileHandle, maximumDiscardedBytes: Int) {
    self.handle = handle
    self.maximumDiscardedBytes = maximumDiscardedBytes
  }

  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard !isStopped else { return }
    handle.readabilityHandler = { [weak self] _ in
      self?.discardReadableData()
    }
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }
    guard !isStopped else { return }
    isStopped = true
    handle.readabilityHandler = nil
    handle.closeFile()
  }

  private func discardReadableData() {
    lock.lock()
    defer { lock.unlock() }
    guard !isStopped else { return }
    let data = handle.availableData
    guard !data.isEmpty else { return }
    discardedByteCount = min(
      maximumDiscardedBytes,
      discardedByteCount.saturatingAdd(data.count)
    )
  }
}

private final class PublishingMCPProcessTerminator: @unchecked Sendable {
  private let processIdentifier: pid_t
  private let processGroupIdentifier: pid_t
  private let lock = NSLock()
  private var terminationRequested = false

  init(processIdentifier: pid_t, processGroupIdentifier: pid_t) {
    self.processIdentifier = processIdentifier
    self.processGroupIdentifier = processGroupIdentifier
  }

  func terminateThenKillAfterGracePeriod() {
    lock.lock()
    guard !terminationRequested else {
      lock.unlock()
      return
    }
    terminationRequested = true
    signal(SIGTERM)
    lock.unlock()
    Task { [self] in
      do {
        try await Task.sleep(nanoseconds: 250_000_000)
      } catch {
        return
      }
      killIfStillRunning()
    }
  }

  private func killIfStillRunning() {
    lock.lock()
    defer { lock.unlock() }
    signal(SIGKILL)
    _ = Darwin.kill(processIdentifier, SIGKILL)
    reapLeader()
  }

  private func signal(_ value: Int32) {
    _ = Darwin.kill(-processGroupIdentifier, value)
  }

  private func reapLeader() {
    var status: Int32 = 0
    while true {
      let result = Darwin.waitpid(processIdentifier, &status, 0)
      if result == processIdentifier || (result == -1 && errno == ECHILD) {
        return
      }
      if result == -1, errno == EINTR {
        continue
      }
      return
    }
  }
}

extension Int {
  func saturatingAdd(_ other: Int) -> Int {
    let (value, overflow) = addingReportingOverflow(other)
    return overflow ? Int.max : value
  }
}
