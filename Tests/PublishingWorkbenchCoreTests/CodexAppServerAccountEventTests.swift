import Foundation
import XCTest

@testable import PublishingAICore

final class CodexAppServerAccountEventTests: XCTestCase {
  func testSubscriptionDoesNotStartProcessAndCancellationRemovesSubscriber() async {
    let transport = AccountEventTransport()
    let client = CodexAppServerClient(transport: transport)
    let stream = await client.accountEvents()
    let consumer = Task { for await _ in stream {} }
    let count = await client.accountEventSubscriberCount
    let starts = await transport.startCount
    XCTAssertEqual(count, 1)
    XCTAssertEqual(starts, 0)
    consumer.cancel()
    await consumer.value
    let removed = await waitUntil { await client.accountEventSubscriberCount == 0 }
    XCTAssertTrue(removed)
  }

  func testAccountAndQuotaNotificationsUseTypedPayloadAndMonotonicRevision() async throws {
    let transport = AccountEventTransport()
    let client = CodexAppServerClient(transport: transport)
    let recorder = AccountEventRecorder()
    let stream = await client.accountEvents()
    let consumer = record(stream, in: recorder)
    defer { consumer.cancel() }
    try await client.start()
    await transport.emit("account/rateLimits/updated", params: .object(["rateLimits": .null]))
    await transport.emit("account/updated", params: .null)
    await transport.emit("account/updated", params: .object(["authMode": .string("chatgpt")]))
    await transport.emit(
      "account/rateLimits/updated",
      params: .object([
        "rateLimits": .object([
          "primary": .object([
            "usedPercent": .number(37), "windowDurationMins": .number(300),
            "resetsAt": .number(1_900_000_000),
          ]),
          "secondary": .object(["usedPercent": .number(11), "windowMinutes": .number(10_080)]),
          "credits": .object(["remaining": .number(9)]), "planType": .string("plus"),
        ])
      ]))
    let received = await waitUntil { await recorder.events.count == 2 }
    XCTAssertTrue(received)
    let events = await recorder.events
    XCTAssertEqual(events.map(\.accountRevision), [1, 1])
    XCTAssertEqual(events.map(\.sequence), [1, 2])
    XCTAssertEqual(events.map(\.generation), [1, 1])
    XCTAssertEqual(events.first?.kind, .accountChanged)
    guard case .rateLimitsUpdated(let quota) = events.last?.kind else {
      XCTFail("Expected a parsed quota notification")
      await client.shutdown()
      return
    }
    XCTAssertEqual(quota.primary?.usedPercent, 37)
    XCTAssertEqual(quota.primary?.windowMinutes, 300)
    XCTAssertEqual(quota.primary?.resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
    XCTAssertEqual(quota.secondary?.windowMinutes, 10_080)
    XCTAssertEqual(quota.creditsRemaining, 9)
    XCTAssertEqual(quota.planType, "plus")
    await client.shutdown()
  }

  func testBoundedNewestBufferPreservesRevisionAfterDroppingAccountChange() async throws {
    let transport = AccountEventTransport()
    let client = CodexAppServerClient(transport: transport)
    let stream = await client.accountEvents()
    try await client.start()
    await transport.emit("account/updated", params: .object(["authMode": .null]))
    for value in 0..<100 {
      await transport.emitQuota(Double(value))
    }
    let processed = await waitUntil { await client.accountEventState.sequence == 101 }
    XCTAssertTrue(processed)
    var iterator = stream.makeAsyncIterator()
    var events: [CodexAppServerAccountEvent] = []
    for _ in 0..<16 {
      if let event = await iterator.next() { events.append(event) }
    }
    XCTAssertEqual(events.count, 16)
    XCTAssertEqual(events.first?.sequence, 86)
    XCTAssertEqual(events.last?.sequence, 101)
    XCTAssertTrue(events.allSatisfy { $0.accountRevision == 1 })
    XCTAssertTrue(
      events.allSatisfy {
        if case .rateLimitsUpdated = $0.kind { return true }
        return false
      })
    await client.shutdown()
  }

  func testEOFAndShutdownInvalidateWithoutRestartAndOldGenerationEventsAreIgnored() async throws {
    let oldTransport = AccountEventTransport(keepsReceiveAfterTermination: true)
    let replacement = AccountEventTransport()
    let factory = AccountEventTransportFactory([oldTransport, replacement])
    let client = CodexAppServerClient(transportFactory: { factory.next() })
    let recorder = AccountEventRecorder()
    let stream = await client.accountEvents()
    let consumer = record(stream, in: recorder)
    defer { consumer.cancel() }
    try await client.start()
    await client.shutdown()
    try await client.start()
    await oldTransport.emit("account/updated", params: .object(["authMode": .null]))
    await replacement.emitQuota(12)
    let updated = await waitUntil { await recorder.events.count == 2 }
    XCTAssertTrue(updated)
    var events = await recorder.events
    XCTAssertEqual(events.map(\.generation), [2, 3])
    XCTAssertEqual(events.map(\.accountRevision), [1, 1])
    XCTAssertEqual(events.first?.kind, .connectionClosed)
    await replacement.endStream()
    let closed = await waitUntil { await recorder.events.count == 3 }
    XCTAssertTrue(closed)
    events = await recorder.events
    XCTAssertEqual(events.last?.kind, .connectionClosed)
    XCTAssertEqual(events.last?.accountRevision, 2)
    XCTAssertEqual(factory.createdCount, 2)
    let starts = await replacement.startCount
    XCTAssertEqual(starts, 1)
  }

  func testSuccessfulLogoutInvalidatesEvenWithoutServerNotification() async throws {
    let transport = AccountEventTransport()
    let client = CodexAppServerClient(transport: transport)
    let stream = await client.accountEvents()
    let recorder = AccountEventRecorder()
    let consumer = record(stream, in: recorder)
    defer { consumer.cancel() }
    try await client.logout()
    let received = await waitUntil { await recorder.events.count == 1 }
    XCTAssertTrue(received)
    let events = await recorder.events
    XCTAssertEqual(events.first?.kind, .accountChanged)
    XCTAssertEqual(events.first?.accountRevision, 1)
    await client.shutdown()
  }

  func testUnusedClientDeinitFinishesSubscribersWithoutRetainCycle() async {
    var client: CodexAppServerClient? = CodexAppServerClient(transport: AccountEventTransport())
    weak let weakClient = client
    let stream = await client!.accountEvents()
    let consumer = Task {
      var count = 0
      for await _ in stream { count += 1 }
      return count
    }
    client = nil
    XCTAssertNil(weakClient)
    let count = await consumer.value
    XCTAssertEqual(count, 0)
  }

  private func record(
    _ stream: AsyncStream<CodexAppServerAccountEvent>, in recorder: AccountEventRecorder
  ) -> Task<Void, Never> {
    Task { for await event in stream { await recorder.append(event) } }
  }

  private func waitUntil(_ predicate: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !(await predicate()) {
      guard clock.now < deadline else { return false }
      try? await clock.sleep(for: .milliseconds(1))
    }
    return true
  }
}

private actor AccountEventRecorder {
  private(set) var events: [CodexAppServerAccountEvent] = []
  func append(_ event: CodexAppServerAccountEvent) { events.append(event) }
}

private actor AccountEventTransport: CodexAppServerTransport {
  private let keepsReceiveAfterTermination: Bool
  private var chunks: [Data] = []
  private var receiver: CheckedContinuation<Data?, Error>?
  private var ended = false
  private(set) var startCount = 0

  init(keepsReceiveAfterTermination: Bool = false) {
    self.keepsReceiveAfterTermination = keepsReceiveAfterTermination
  }

  func start() async throws { startCount += 1 }

  func send(_ data: Data) async throws {
    let message = try JSONDecoder().decode(CodexAppServerJSONValue.self, from: data)
    guard let id = message["id"] else { return }
    deliver(.object(["id": id, "result": .object([:])]))
  }

  func receive() async throws -> Data? {
    if !chunks.isEmpty { return chunks.removeFirst() }
    if ended { return nil }
    return try await withCheckedThrowingContinuation { receiver = $0 }
  }

  func terminate() async {
    if !keepsReceiveAfterTermination { endStream() }
  }

  func endStream() {
    ended = true
    receiver?.resume(returning: nil)
    receiver = nil
  }

  func emit(_ method: String, params: CodexAppServerJSONValue) {
    deliver(.object(["method": .string(method), "params": params]))
  }

  func emitQuota(_ used: Double) {
    emit(
      "account/rateLimits/updated",
      params: .object([
        "rateLimits": .object(["primary": .object(["usedPercent": .number(used)])])
      ]))
  }

  private func deliver(_ value: CodexAppServerJSONValue) {
    do {
      var data = try JSONEncoder().encode(value)
      data.append(0x0A)
      if let receiver {
        self.receiver = nil
        receiver.resume(returning: data)
      } else {
        chunks.append(data)
      }
    } catch {
      XCTFail("Could not encode fixture: \(error)")
    }
  }
}

private final class AccountEventTransportFactory: @unchecked Sendable {
  private let lock = NSLock()
  private var transports: [AccountEventTransport]
  private var count = 0
  init(_ transports: [AccountEventTransport]) { self.transports = transports }
  var createdCount: Int { lock.withLock { count } }
  func next() -> AccountEventTransport {
    lock.withLock {
      count += 1
      return transports.removeFirst()
    }
  }
}
