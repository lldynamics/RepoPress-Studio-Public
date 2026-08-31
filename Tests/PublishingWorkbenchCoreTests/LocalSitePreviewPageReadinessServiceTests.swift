import Foundation
import Network
import XCTest

@testable import PublishingWorkbenchCore

final class LocalSitePreviewPageReadinessServiceTests: XCTestCase {
  func testRejectsNonNumericLoopbackURLWithoutProbing() async {
    let counter = LockedProbeCounter()
    let service = LocalSitePreviewPageReadinessService { request in
      counter.increment()
      return LocalSitePreviewPageProbeResult(statusCode: 200, responseURL: request.url)
    }

    let result = await service.waitUntilReady(
      URL(string: "http://localhost:4321/article")!,
      maxAttempts: 2
    )

    XCTAssertFalse(result)
    XCTAssertEqual(counter.value, 0)
  }

  func testRetriesUntilTheExactPageReturnsSuccess() async {
    let counter = LockedProbeCounter()
    let service = LocalSitePreviewPageReadinessService { request in
      let attempt = counter.increment()
      return LocalSitePreviewPageProbeResult(
        statusCode: attempt < 3 ? 404 : 200,
        responseURL: request.url
      )
    }
    let url = URL(string: "http://127.0.0.1:4321/article")!

    let result = await service.waitUntilReady(url, maxAttempts: 3)

    XCTAssertTrue(result)
    XCTAssertEqual(counter.value, 3)
  }

  func testDoesNotAcceptASuccessfulResponseFromRedirectedURL() async {
    let service = LocalSitePreviewPageReadinessService { _ in
      LocalSitePreviewPageProbeResult(
        statusCode: 200,
        responseURL: URL(string: "http://127.0.0.1:4321/sign-in")
      )
    }

    let result = await service.waitUntilReady(
      URL(string: "http://127.0.0.1:4321/article")!,
      maxAttempts: 1
    )

    XCTAssertFalse(result)
  }

  func testFollowsOnlySameOriginLoopbackRedirectBeforeAcceptingSuccess() async {
    let counter = LockedProbeCounter()
    let redirectedURL = URL(string: "http://127.0.0.1:4321/article/")!
    let service = LocalSitePreviewPageReadinessService { request in
      let attempt = counter.increment()
      if attempt == 1 {
        return LocalSitePreviewPageProbeResult(
          statusCode: 301,
          responseURL: request.url,
          redirectURL: redirectedURL
        )
      }
      return LocalSitePreviewPageProbeResult(statusCode: 200, responseURL: request.url)
    }

    let result = await service.waitUntilReady(
      URL(string: "http://127.0.0.1:4321/article")!,
      maxAttempts: 2
    )

    XCTAssertTrue(result)
    XCTAssertEqual(counter.value, 2)
  }

  func testRejectsRedirectToAnotherOrigin() async {
    let service = LocalSitePreviewPageReadinessService { request in
      LocalSitePreviewPageProbeResult(
        statusCode: 302,
        responseURL: request.url,
        redirectURL: URL(string: "https://example.com/sign-in")
      )
    }

    let result = await service.waitUntilReady(
      URL(string: "http://127.0.0.1:4321/article")!,
      maxAttempts: 1
    )

    XCTAssertFalse(result)
  }

  func testRealProbeReturnsAfterHeadersWithoutWaitingForInfiniteChunkedBody() async throws {
    let server = try await makeStreamingServerOrSkip(
      responseHeaders: ["Transfer-Encoding: chunked"]
    )
    defer { server.cancel() }
    let clock = ContinuousClock()
    let startedAt = clock.now

    let result = await LocalSitePreviewPageReadinessService().waitUntilReady(
      server.url,
      maxAttempts: 1
    )

    XCTAssertTrue(result)
    XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
  }

  func testRealProbeAcceptsHeadersOnlyEmptyResponse() async throws {
    let server = try await makeStreamingServerOrSkip(
      responseHeaders: ["Content-Length: 0"]
    )
    defer { server.cancel() }

    let result = await LocalSitePreviewPageReadinessService().waitUntilReady(
      server.url,
      maxAttempts: 1
    )

    XCTAssertTrue(result)
  }

  func testRealProbeSkipsEarlyHintsBeforeFinalSuccess() async throws {
    let server = try await makeStreamingServerOrSkip(
      responseHeaders: ["Content-Length: 0"],
      interimResponses: [
        "HTTP/1.1 103 Early Hints\r\nLink: </app.css>; rel=preload\r\n\r\n"
      ]
    )
    defer { server.cancel() }

    let result = await LocalSitePreviewPageReadinessService().waitUntilReady(
      server.url,
      maxAttempts: 1
    )

    XCTAssertTrue(result)
  }

  func testRealProbeRejectsOversizedResponseHeaders() async throws {
    let server = try await makeStreamingServerOrSkip(
      responseHeaders: ["X-Oversized: \(String(repeating: "a", count: 66 * 1_024))"]
    )
    defer { server.cancel() }

    let result = await LocalSitePreviewPageReadinessService().waitUntilReady(
      server.url,
      maxAttempts: 1
    )

    XCTAssertFalse(result)
  }

  func testRealProbeReturnsAfterHeadersWithoutWaitingForHugeDeclaredBody() async throws {
    let server = try await makeStreamingServerOrSkip(
      responseHeaders: ["Content-Length: 922337203685477580"]
    )
    defer { server.cancel() }
    let clock = ContinuousClock()
    let startedAt = clock.now

    let result = await LocalSitePreviewPageReadinessService().waitUntilReady(
      server.url,
      maxAttempts: 1
    )

    XCTAssertTrue(result)
    XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
  }

  func testRealProbeAcceptsHeaderBelowLimitWhenSameSegmentIncludesBody() async throws {
    let body = Data(repeating: 0x78, count: 16 * 1_024)
    let server = try await makeStreamingServerOrSkip(
      responseHeaders: [
        "Content-Length: \(body.count)",
        "X-Near-Limit: \(String(repeating: "a", count: 63 * 1_024))",
      ],
      responseBody: body,
      firstChunkByteCount: 60_000
    )
    defer { server.cancel() }

    let result = await LocalSitePreviewPageReadinessService().waitUntilReady(
      server.url,
      maxAttempts: 1
    )

    XCTAssertTrue(result)
  }

  func testRealProbeParsesHeaderBoundarySplitAcrossNetworkWrites() async throws {
    let server = try await makeStreamingServerOrSkip(
      responseHeaders: ["Content-Length: 0"],
      splitBeforeFinalHeaderTerminator: true
    )
    defer { server.cancel() }

    let result = await LocalSitePreviewPageReadinessService().waitUntilReady(
      server.url,
      maxAttempts: 1
    )

    XCTAssertTrue(result)
  }

  func testRealProbeTimesOutWhenServerNeverSendsHeaders() async throws {
    let server = try await makeStreamingServerOrSkip(
      responseHeaders: [],
      sendsResponse: false
    )
    defer { server.cancel() }
    var request = URLRequest(url: server.url)
    request.httpMethod = "GET"
    request.timeoutInterval = 0.1

    do {
      _ = try await LocalSitePreviewHTTPMetadataProbe.perform(request)
      XCTFail("Expected a timed-out metadata probe")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .timedOut)
    } catch {
      XCTFail("Expected URLError.timedOut, got \(error)")
    }
  }

  func testCancellingRealProbeFinishesPromptly() async throws {
    let server = try await makeStreamingServerOrSkip(
      responseHeaders: [],
      sendsResponse: false
    )
    defer { server.cancel() }
    var request = URLRequest(url: server.url)
    request.httpMethod = "GET"
    request.timeoutInterval = 5
    let probe = Task {
      try await LocalSitePreviewHTTPMetadataProbe.perform(request)
    }
    try await Task.sleep(for: .milliseconds(50))
    let clock = ContinuousClock()
    let cancelledAt = clock.now

    probe.cancel()

    do {
      _ = try await probe.value
      XCTFail("Expected a cancelled metadata probe")
    } catch is CancellationError {
      XCTAssertLessThan(cancelledAt.duration(to: clock.now), .seconds(1))
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  private func makeStreamingServerOrSkip(
    responseHeaders: [String],
    interimResponses: [String] = [],
    responseBody: Data = Data(),
    firstChunkByteCount: Int? = nil,
    splitBeforeFinalHeaderTerminator: Bool = false,
    sendsResponse: Bool = true
  ) async throws -> LocalSitePreviewStreamingHTTPServer {
    do {
      return try await LocalSitePreviewStreamingHTTPServer.start(
        responseHeaders: responseHeaders,
        interimResponses: interimResponses,
        responseBody: responseBody,
        firstChunkByteCount: firstChunkByteCount,
        splitBeforeFinalHeaderTerminator: splitBeforeFinalHeaderTerminator,
        sendsResponse: sendsResponse
      )
    } catch let error as LocalSitePreviewStreamingHTTPServer.StartupError {
      switch error {
      case .listenerFailed(.posix(let code)) where code == .EPERM || code == .EACCES:
        throw XCTSkip("Loopback listener is unavailable in this test environment: \(error)")
      default:
        throw error
      }
    }
  }
}

private final class LockedProbeCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  @discardableResult
  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

private final class LocalSitePreviewStreamingHTTPServer: @unchecked Sendable {
  enum StartupError: Error {
    case listenerFailed(NWError)
    case listenerTimedOut
  }

  private let listener: NWListener
  private let queue = DispatchQueue(label: "LocalSitePreviewStreamingHTTPServer")
  private let lock = NSLock()
  private var boundPort: UInt16?
  private var isStopped = false
  private var connections: [NWConnection] = []

  var url: URL {
    let port = lock.withLock { boundPort }
    guard let port else {
      preconditionFailure("The streaming HTTP server must be ready before its URL is used")
    }
    return URL(string: "http://127.0.0.1:\(port)/preview")!
  }

  private init(
    listener: NWListener,
    responseHeaders: [String],
    interimResponses: [String],
    responseBody: Data,
    firstChunkByteCount: Int?,
    splitBeforeFinalHeaderTerminator: Bool,
    sendsResponse: Bool
  ) {
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(
        connection,
        responseHeaders: responseHeaders,
        interimResponses: interimResponses,
        responseBody: responseBody,
        firstChunkByteCount: firstChunkByteCount,
        splitBeforeFinalHeaderTerminator: splitBeforeFinalHeaderTerminator,
        sendsResponse: sendsResponse
      )
    }
  }

  static func start(
    responseHeaders: [String],
    interimResponses: [String],
    responseBody: Data,
    firstChunkByteCount: Int?,
    splitBeforeFinalHeaderTerminator: Bool,
    sendsResponse: Bool
  ) async throws -> Self {
    let listener = try NWListener(using: .tcp)
    let server = Self(
      listener: listener,
      responseHeaders: responseHeaders,
      interimResponses: interimResponses,
      responseBody: responseBody,
      firstChunkByteCount: firstChunkByteCount,
      splitBeforeFinalHeaderTerminator: splitBeforeFinalHeaderTerminator,
      sendsResponse: sendsResponse
    )
    let startup = LocalSitePreviewListenerStartupState()
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        if let port = listener.port?.rawValue {
          startup.markReady(port: port)
        }
      case .failed(let error):
        startup.markFailed(error)
      default:
        break
      }
    }
    let queue = DispatchQueue(label: "LocalSitePreviewStreamingHTTPServer.start")
    listener.start(queue: queue)

    for _ in 0..<100 {
      if let failure = startup.failure {
        listener.cancel()
        throw StartupError.listenerFailed(failure)
      }
      if let port = startup.port {
        server.lock.withLock { server.boundPort = port }
        return server
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    listener.cancel()
    throw StartupError.listenerTimedOut
  }

  func cancel() {
    listener.cancel()
    let connections = lock.withLock {
      isStopped = true
      let current = self.connections
      self.connections.removeAll()
      return current
    }
    for connection in connections { connection.cancel() }
  }

  private func accept(
    _ connection: NWConnection,
    responseHeaders: [String],
    interimResponses: [String],
    responseBody: Data,
    firstChunkByteCount: Int?,
    splitBeforeFinalHeaderTerminator: Bool,
    sendsResponse: Bool
  ) {
    let shouldAccept = lock.withLock {
      guard !isStopped else { return false }
      connections.append(connection)
      return true
    }
    guard shouldAccept else {
      connection.cancel()
      return
    }
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 4, maximumLength: 8_192) {
      [weak self, weak connection] data, _, _, error in
      guard let self, let connection, let data, data.starts(with: Data("GET ".utf8)),
        error == nil
      else { return }
      guard sendsResponse else { return }
      let finalResponse =
        ([
          "HTTP/1.1 200 OK",
          "Content-Type: text/html; charset=utf-8",
          "Connection: keep-alive",
        ] + responseHeaders + ["", ""]).joined(separator: "\r\n")
      var response = Data((interimResponses.joined() + finalResponse).utf8)
      let finalHeaderEnd = response.count
      response.append(responseBody)
      let requestedSplit =
        splitBeforeFinalHeaderTerminator
        ? finalHeaderEnd - 1
        : firstChunkByteCount
      guard let requestedSplit, requestedSplit > 0, requestedSplit < response.count else {
        self.send(response, over: connection)
        return
      }
      let splitIndex = response.index(response.startIndex, offsetBy: requestedSplit)
      let firstChunk = Data(response[..<splitIndex])
      let remaining = Data(response[splitIndex...])
      connection.send(
        content: firstChunk,
        completion: .contentProcessed { [weak self, weak connection] error in
          guard error == nil, let self, let connection else { return }
          self.queue.asyncAfter(deadline: .now() + .milliseconds(20)) {
            self.send(remaining, over: connection)
          }
        })
    }
  }

  private func send(_ response: Data, over connection: NWConnection) {
    connection.send(
      content: response,
      completion: .contentProcessed { _ in
        // Keep the connection and any deliberately unfinished body open. The
        // client must return after headers and cancel the request itself.
        _ = self
      })
  }
}

private final class LocalSitePreviewListenerStartupState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedPort: UInt16?
  private var storedFailure: NWError?

  var port: UInt16? { lock.withLock { storedPort } }
  var failure: NWError? { lock.withLock { storedFailure } }

  func markReady(port: UInt16) {
    lock.withLock { storedPort = port }
  }

  func markFailed(_ error: NWError) {
    lock.withLock { storedFailure = error }
  }
}
