import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class KnowledgeWebDownloadClientTests: XCTestCase {
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

  func testEveryRedirectDestinationIsValidated() throws {
    let publicAddress = try XCTUnwrap(KnowledgeResolvedAddress(presentation: "1.1.1.1"))
    let privateAddress = try XCTUnwrap(KnowledgeResolvedAddress(presentation: "192.168.0.5"))
    let publicRedirect = URLRequest(
      url: try XCTUnwrap(URL(string: "https://cdn.example/article"))
    )
    let privateRedirect = URLRequest(
      url: try XCTUnwrap(URL(string: "https://router.example/admin"))
    )
    let downgradeRedirect = URLRequest(
      url: try XCTUnwrap(URL(string: "http://cdn.example/article"))
    )

    XCTAssertNotNil(KnowledgeWebDownloadSessionDelegate.redirectedRequest(
      proposedRequest: publicRedirect,
      resolver: { _ in [publicAddress] }
    ))
    XCTAssertNil(KnowledgeWebDownloadSessionDelegate.redirectedRequest(
      proposedRequest: privateRedirect,
      resolver: { _ in [privateAddress] }
    ))
    XCTAssertNil(KnowledgeWebDownloadSessionDelegate.redirectedRequest(
      proposedRequest: downgradeRedirect,
      resolver: { _ in [publicAddress] }
    ))
  }

  func testStreamingBufferStopsBeforeAppendingPastLimit() throws {
    var buffer = try KnowledgeWebDownloadBuffer(maximumByteCount: 4)
    for byte in Data("safe".utf8) {
      try buffer.append(byte)
    }
    XCTAssertEqual(String(decoding: buffer.data, as: UTF8.self), "safe")

    XCTAssertThrowsError(try buffer.append(UInt8(ascii: "!"))) { error in
      guard case KnowledgeWebDownloadError.byteLimitExceeded(let limit) = error else {
        return XCTFail("应在流式接收阶段报告大小上限，实际为：\(error)")
      }
      XCTAssertEqual(limit, 4)
    }
    XCTAssertEqual(buffer.data.count, 4)
  }

  func testContentLengthOverLimitIsRejectedBeforeStreaming() {
    XCTAssertThrowsError(
      try KnowledgeWebDownloadBuffer(maximumByteCount: 4, expectedByteCount: 5)
    ) { error in
      guard case KnowledgeWebDownloadError.byteLimitExceeded(let limit) = error else {
        return XCTFail("应根据 Content-Length 提前拒绝，实际为：\(error)")
      }
      XCTAssertEqual(limit, 4)
    }
  }
}
