import Darwin
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class CodexAppServerTransportConcurrencyTests: XCTestCase {
  func testProcessTransportSerializesConcurrentJSONLFrameWrites() async throws {
    let transport = CodexAppServerProcessTransport(
      testExecutableURL: URL(fileURLWithPath: "/bin/cat"),
      arguments: []
    )
    try await transport.start()
    defer { Task { await transport.terminate() } }

    let frames = (0..<48).map { index in
      Data("{\"id\":\(index),\"payload\":\"\(String(repeating: "x", count: 1_024))\"}\n".utf8)
    }
    let expectedByteCount = frames.reduce(into: 0) { $0 += $1.count }
    let readTask = Task { [transport] in
      var output = Data()
      while output.count < expectedByteCount {
        guard let chunk = try await transport.receive() else {
          throw CodexAppServerError.endOfStream
        }
        output.append(chunk)
      }
      return output
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for frame in frames {
        group.addTask {
          try await transport.send(frame)
        }
      }
      try await group.waitForAll()
    }

    let output = try await readTask.value
    XCTAssertEqual(output.count, expectedByteCount)
    let lines = output.split(separator: 0x0A, omittingEmptySubsequences: true)
    XCTAssertEqual(lines.count, frames.count)
    let decodedIDs = try lines.map { line -> Int in
      let value = try JSONDecoder().decode(CodexAppServerJSONValue.self, from: Data(line))
      return try XCTUnwrap(value["id"]?.intValue)
    }
    XCTAssertEqual(Set(decodedIDs), Set(0..<frames.count))
  }

  func testUnterminatedOversizedFrameFailsClosedAndTerminatesGeneration() async throws {
    let transport = OversizedFrameTransport()
    let client = CodexAppServerClient(transport: transport)

    do {
      try await client.start()
      _ = try await client.accountStatus()
      XCTFail("Expected the oversized response frame to end the client generation")
    } catch {
      XCTAssertEqual(error as? CodexAppServerError, .frameTooLarge)
    }
    let didTerminate = await waitUntilTerminated(transport)
    let terminationCount = await transport.terminationCount
    XCTAssertTrue(didTerminate)
    XCTAssertEqual(terminationCount, 1)
  }

  func testProcessTransportTerminationReapsProcessGroupDescendant() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexAppServerTransport-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let childPID = root.appendingPathComponent("child.pid")
    let executable = root.appendingPathComponent("codex")
    let script = """
      #!/bin/sh
      (trap '' TERM; while :; do :; done) &
      printf '%s' "$!" > '\(childPID.path)'
      trap 'exit 0' TERM
      while :; do :; done
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let transport = CodexAppServerProcessTransport(
      testExecutableURL: executable,
      arguments: []
    )
    try await transport.start()
    let pid = try await waitForPID(at: childPID)

    await transport.terminate()

    for _ in 0..<100 {
      errno = 0
      if Darwin.kill(pid, 0) == -1, errno == ESRCH { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("app-server descendant was not reaped")
  }

  private func waitForPID(at url: URL) async throws -> pid_t {
    for _ in 0..<100 {
      if let text = try? String(contentsOf: url, encoding: .utf8),
        let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw NSError(domain: "CodexAppServerTransportTests", code: 1)
  }

  func testShutdownDuringHandshakeCannotTearDownReplacementGeneration() async throws {
    let firstTransport = HandshakeReplacementTransport(holdsInitializedNotification: true)
    let replacementTransport = HandshakeReplacementTransport(holdsInitializedNotification: false)
    let factory = HandshakeReplacementTransportFactory(
      first: firstTransport,
      replacement: replacementTransport
    )
    let client = CodexAppServerClient(transportFactory: { factory.make() })

    let firstStart = Task { try await client.start() }
    await firstTransport.waitForInitializedNotification()

    await client.shutdown()

    try await client.start()
    let accountTask = Task { try await client.accountStatus() }
    await replacementTransport.waitForAccountRequest()

    // The original startup task now completes after its replacement is serving
    // a request. Its cleanup must be a no-op for the replacement generation.
    await firstTransport.releaseInitializedNotification()
    do {
      try await firstStart.value
      XCTFail("The invalidated startup task should not succeed")
    } catch {
      XCTAssertEqual(error as? CodexAppServerError, .endOfStream)
    }
    try await replacementTransport.replyToAccountRequest()

    let account = try await accountTask.value
    XCTAssertTrue(account.isAuthenticated)
  }

  private func waitUntilTerminated(
    _ transport: OversizedFrameTransport,
    timeout: Duration = .seconds(1)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await transport.terminationCount > 0 {
        return true
      }
      try? await clock.sleep(for: .milliseconds(1))
    }
    return false
  }
}

private final class HandshakeReplacementTransportFactory: @unchecked Sendable {
  private let lock = NSLock()
  private let first: HandshakeReplacementTransport
  private let replacement: HandshakeReplacementTransport
  private var hasMadeInitialTransport = false

  init(first: HandshakeReplacementTransport, replacement: HandshakeReplacementTransport) {
    self.first = first
    self.replacement = replacement
  }

  func make() -> any CodexAppServerTransport {
    lock.lock()
    defer { lock.unlock() }
    if hasMadeInitialTransport {
      return replacement
    }
    hasMadeInitialTransport = true
    return first
  }
}

private actor HandshakeReplacementTransport: CodexAppServerTransport {
  private let holdsInitializedNotification: Bool
  private var queuedChunks: [Data] = []
  private var waitingReceiver: CheckedContinuation<Data?, Error>?
  private var initializedNotificationWaiter: CheckedContinuation<Void, Never>?
  private var accountRequestID: Int?
  private var initializedNotificationWasSent = false
  private var isTerminated = false

  init(holdsInitializedNotification: Bool) {
    self.holdsInitializedNotification = holdsInitializedNotification
  }

  func start() async throws {}

  func send(_ data: Data) async throws {
    let value = try JSONDecoder().decode(CodexAppServerJSONValue.self, from: data)
    let method = value["method"]?.stringValue
    switch method {
    case "initialize":
      let requestID = try XCTUnwrap(value["id"]?.intValue)
      enqueue(Data("{\"id\":\(requestID),\"result\":{}}\n".utf8))
    case "initialized":
      initializedNotificationWasSent = true
      guard holdsInitializedNotification else { return }
      await withCheckedContinuation { continuation in
        initializedNotificationWaiter = continuation
      }
    case "account/read":
      accountRequestID = try XCTUnwrap(value["id"]?.intValue)
    default:
      return
    }
  }

  func receive() async throws -> Data? {
    if !queuedChunks.isEmpty {
      return queuedChunks.removeFirst()
    }
    if isTerminated {
      return nil
    }
    return try await withCheckedThrowingContinuation { continuation in
      waitingReceiver = continuation
    }
  }

  func terminate() async {
    isTerminated = true
    let receiver = waitingReceiver
    waitingReceiver = nil
    receiver?.resume(returning: nil)
  }

  func waitForInitializedNotification() async {
    while !initializedNotificationWasSent {
      await Task.yield()
    }
  }

  func waitForAccountRequest() async {
    while accountRequestID == nil {
      await Task.yield()
    }
  }

  func releaseInitializedNotification() {
    let waiter = initializedNotificationWaiter
    initializedNotificationWaiter = nil
    waiter?.resume()
  }

  func replyToAccountRequest() throws {
    let requestID = try XCTUnwrap(accountRequestID)
    enqueue(Data("{\"id\":\(requestID),\"result\":{\"authenticated\":true}}\n".utf8))
  }

  private func enqueue(_ data: Data) {
    if let receiver = waitingReceiver {
      waitingReceiver = nil
      receiver.resume(returning: data)
    } else {
      queuedChunks.append(data)
    }
  }
}

private actor OversizedFrameTransport: CodexAppServerTransport {
  private var queuedChunks: [Data] = []
  private var waitingReceiver: CheckedContinuation<Data?, Error>?
  private var terminated = false
  private(set) var terminationCount = 0

  func start() async throws {}

  func send(_ data: Data) async throws {
    let value = try JSONDecoder().decode(CodexAppServerJSONValue.self, from: data)
    switch value["method"]?.stringValue {
    case "initialize":
      let requestID = try XCTUnwrap(value["id"]?.intValue)
      enqueue(
        Data(
          "{\"id\":\(requestID),\"result\":{\"serverInfo\":{\"version\":\"1\"}}}\n".utf8
        ))
    case "account/read":
      enqueue(Data(repeating: 0x61, count: CodexAppServerClient.maximumFrameByteCount + 1))
    default:
      return
    }
  }

  func receive() async throws -> Data? {
    if !queuedChunks.isEmpty {
      return queuedChunks.removeFirst()
    }
    return try await withCheckedThrowingContinuation { continuation in
      waitingReceiver = continuation
    }
  }

  func terminate() async {
    guard !terminated else { return }
    terminated = true
    terminationCount += 1
    let receiver = waitingReceiver
    waitingReceiver = nil
    receiver?.resume(returning: nil)
  }

  private func enqueue(_ data: Data) {
    if let receiver = waitingReceiver {
      waitingReceiver = nil
      receiver.resume(returning: data)
    } else {
      queuedChunks.append(data)
    }
  }
}
