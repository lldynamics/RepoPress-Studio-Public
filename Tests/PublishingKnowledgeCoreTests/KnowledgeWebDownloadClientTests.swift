import Foundation
import Network
import XCTest
@testable import PublishingKnowledgeCore

final class KnowledgeWebDownloadClientTests: XCTestCase {
  private final class TransportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var transportedHosts: [String] = []
    private(set) var transportedAddresses: [[KnowledgeResolvedAddress]] = []

    func record(request: URLRequest, addresses: [KnowledgeResolvedAddress]) {
      lock.lock()
      transportedHosts.append(request.url?.host ?? "")
      transportedAddresses.append(addresses)
      lock.unlock()
    }

    var callCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return transportedHosts.count
    }

    var lastAddresses: [KnowledgeResolvedAddress]? {
      lock.lock()
      defer { lock.unlock() }
      return transportedAddresses.last
    }
  }

  func testPolicyRejectsLoopbackPrivateLinkLocalAndDocumentationAddresses() throws {
    let blockedHosts = [
      "127.0.0.1",
      "10.0.0.8",
      "169.254.1.2",
      "172.20.0.1",
      "192.168.1.10",
      "192.0.2.3",
      "198.51.100.7",
      "203.0.113.9",
      "::1",
      "fe80::1",
      "fd00::1",
      "2001:db8::1",
    ]

    for host in blockedHosts {
      let renderedHost = host.contains(":") ? "[\(host)]" : host
      let url = try XCTUnwrap(URL(string: "https://\(renderedHost)/article"))
      XCTAssertThrowsError(
        try KnowledgeWebDownloadPolicy.validatedURL(url) { _ in
          XCTFail("数字地址不应触发 DNS 解析")
          return []
        },
        "Expected blocked address: \(host)"
      ) { error in
        guard case KnowledgeWebDownloadError.blockedAddress = error else {
          return XCTFail("应报告被阻止的地址，实际为：\(error)")
        }
      }
    }
  }

  func testPolicyRequiresEveryResolvedAddressToBePublic() throws {
    let url = try XCTUnwrap(URL(string: "https://reader.example/article"))
    let publicIPv4 = try XCTUnwrap(KnowledgeResolvedAddress(presentation: "8.8.8.8"))
    let publicIPv6 = try XCTUnwrap(KnowledgeResolvedAddress(presentation: "2606:4700:4700::1111"))
    let privateIPv4 = try XCTUnwrap(KnowledgeResolvedAddress(presentation: "10.0.0.4"))

    XCTAssertEqual(
      try KnowledgeWebDownloadPolicy.validatedURL(url) { _ in [publicIPv4, publicIPv6] },
      url
    )
    XCTAssertThrowsError(
      try KnowledgeWebDownloadPolicy.validatedURL(url) { _ in [publicIPv4, privateIPv4] }
    ) { error in
      guard case KnowledgeWebDownloadError.blockedAddress = error else {
        return XCTFail("公私地址混合解析必须整体拒绝，实际为：\(error)")
      }
    }
  }

  func testEveryRedirectDestinationIsValidatedBeforeTransport() async throws {
    let publicAddress = try XCTUnwrap(KnowledgeResolvedAddress(presentation: "1.1.1.1"))
    let privateAddress = try XCTUnwrap(KnowledgeResolvedAddress(presentation: "192.168.0.5"))
    let probe = TransportProbe()
    let client = KnowledgeWebDownloadClient(
      resolver: { host in
        host == "router.example" ? [privateAddress] : [publicAddress]
      },
      transport: { request, addresses, _ in
        probe.record(request: request, addresses: addresses)
        return KnowledgePinnedHTTPResponse(
          data: Data(),
          statusCode: 302,
          headerFields: ["location": "https://router.example/admin"]
        )
      }
    )

    do {
      _ = try await client.download(
        request: URLRequest(
          url: try XCTUnwrap(URL(string: "https://cdn.example/article"))
        ),
        maximumByteCount: 1_024
      )
      XCTFail("解析到私网的重定向不应进入第二次传输")
    } catch {
      guard case KnowledgeWebDownloadError.blockedAddress(let host) = error else {
        return XCTFail("应拒绝重定向的私网地址，实际为：\(error)")
      }
      XCTAssertEqual(host, "router.example")
    }
    XCTAssertEqual(probe.callCount, 1)
  }

  func testTransportReceivesExactlyThePrevalidatedAddress() async throws {
    let approvedAddress = try XCTUnwrap(
      KnowledgeResolvedAddress(presentation: "93.184.216.34")
    )
    let probe = TransportProbe()
    let client = KnowledgeWebDownloadClient(
      resolver: { _ in [approvedAddress] },
      transport: { request, addresses, _ in
        probe.record(request: request, addresses: addresses)
        return KnowledgePinnedHTTPResponse(
          data: Data("safe".utf8),
          statusCode: 200,
          headerFields: ["content-type": "text/html; charset=utf-8"]
        )
      }
    )

    let response = try await client.download(
      request: URLRequest(
        url: try XCTUnwrap(URL(string: "https://reader.example/article"))
      ),
      maximumByteCount: 1_024
    )
    XCTAssertEqual(String(decoding: response.data, as: UTF8.self), "safe")
    XCTAssertEqual(probe.lastAddresses, [approvedAddress])
  }

  func testPinnedHTTPParserEnforcesFramingAndBodyLimit() throws {
    let fixedResponse = Data(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 4\r\n\r\nsafe".utf8
    )
    let fixed = try XCTUnwrap(KnowledgeHTTP1ResponseParser.response(
      from: fixedResponse,
      maximumBodyByteCount: 4,
      connectionIsComplete: false
    ))
    XCTAssertEqual(String(decoding: fixed.data, as: UTF8.self), "safe")

    let chunkedResponse = Data(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nsafe\r\n0\r\n\r\n".utf8
    )
    let chunked = try XCTUnwrap(KnowledgeHTTP1ResponseParser.response(
      from: chunkedResponse,
      maximumBodyByteCount: 4,
      connectionIsComplete: false
    ))
    XCTAssertEqual(String(decoding: chunked.data, as: UTF8.self), "safe")

    XCTAssertThrowsError(try KnowledgeHTTP1ResponseParser.response(
      from: fixedResponse,
      maximumBodyByteCount: 3,
      connectionIsComplete: false
    )) { error in
      guard case KnowledgeWebDownloadError.byteLimitExceeded(let limit) = error else {
        return XCTFail("应在读取正文前拒绝超限 Content-Length，实际为：\(error)")
      }
      XCTAssertEqual(limit, 3)
    }
  }

  func testUnexpectedContentEncodingIsRejected() async throws {
    let publicAddress = try XCTUnwrap(
      KnowledgeResolvedAddress(presentation: "93.184.216.34")
    )
    let client = KnowledgeWebDownloadClient(
      resolver: { _ in [publicAddress] },
      transport: { _, _, _ in
        KnowledgePinnedHTTPResponse(
          data: Data("compressed".utf8),
          statusCode: 200,
          headerFields: [
            "content-type": "text/html",
            "content-encoding": "gzip",
          ]
        )
      }
    )

    do {
      _ = try await client.download(
        request: URLRequest(
          url: try XCTUnwrap(URL(string: "https://reader.example/article"))
        ),
        maximumByteCount: 1_024
      )
      XCTFail("钦定传输不应接受未解码的压缩正文")
    } catch {
      guard case KnowledgeWebDownloadError.unsupportedContentEncoding("gzip") = error else {
        return XCTFail("应报告不支持的内容编码，实际为：\(error)")
      }
    }
  }

  func testCancelledBeforePinnedOperationStartDoesNotSendRequest() async throws {
    let listenerQueue = DispatchQueue(label: "KnowledgeWebDownloadClientTests.listener")
    let listener = try NWListener(using: .tcp)
    defer { listener.cancel() }
    let (readyStream, readyContinuation) = AsyncStream<Void>.makeStream()
    let (requestStream, requestContinuation) = AsyncStream<Void>.makeStream()
    listener.stateUpdateHandler = { state in
      if case .ready = state {
        readyContinuation.yield(())
        readyContinuation.finish()
      }
    }
    listener.newConnectionHandler = { connection in
      requestContinuation.yield(())
      connection.cancel()
    }
    listener.start(queue: listenerQueue)
    for await _ in readyStream {
      break
    }
    let port = try XCTUnwrap(listener.port?.rawValue)
    let address = try XCTUnwrap(
      KnowledgeResolvedAddress(presentation: "127.0.0.1")
    )
    let request = URLRequest(
      url: try XCTUnwrap(URL(string: "http://reader.example:\(port)/article"))
    )
    let operationEntered = DispatchSemaphore(value: 0)
    let releaseOperation = DispatchSemaphore(value: 0)
    let task = Task {
      try await KnowledgePinnedHTTPSClient.fetch(
        request: request,
        addresses: [address],
        maximumByteCount: 1_024,
        testingBeforeOperationStart: {
          operationEntered.signal()
          releaseOperation.wait()
        }
      )
    }

    await waitForSemaphore(operationEntered)
    task.cancel()
    releaseOperation.signal()

    do {
      _ = try await task.value
      XCTFail("已取消的传输不应返回响应")
    } catch is CancellationError {
      // Expected cancellation path.
    } catch {
      XCTFail("应报告取消，实际为：\(error)")
    }
    listenerQueue.sync {}
    requestContinuation.finish()
    var requestWasAccepted = false
    for await _ in requestStream {
      requestWasAccepted = true
    }
    XCTAssertFalse(requestWasAccepted)
  }

}

private func waitForSemaphore(_ semaphore: DispatchSemaphore) async {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      semaphore.wait()
      continuation.resume()
    }
  }
}
