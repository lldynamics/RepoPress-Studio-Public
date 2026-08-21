import XCTest
import CoreFoundation
@testable import PublishingWorkbenchCore

final class CredentialSafeURLSessionTests: XCTestCase {
  private var publicResolver: RSSNetworkURLPolicy.Resolver {
    { _ in [try XCTUnwrap(KnowledgeResolvedAddress(presentation: "8.8.8.8"))] }
  }

  func testCredentialRedirectAllowsSameHTTPSOrigin() throws {
    var original = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example.com/v1/chat")))
    original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    let proposed = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example.com/v2/chat")))

    XCTAssertNotNil(
      CredentialSafeURLSessionDelegate.redirectedRequest(
        originalRequest: original,
        responseURL: original.url,
        proposedRequest: proposed
      )
    )
  }

  func testCredentialRedirectRejectsDifferentHostPortAndHTTPSDowngrade() throws {
    var original = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example.com/v1/chat")))
    original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    let destinations = [
      "https://other.example/v1/chat",
      "https://api.example.com:8443/v1/chat",
      "http://api.example.com/v1/chat",
    ]

    for value in destinations {
      let proposed = URLRequest(url: try XCTUnwrap(URL(string: value)))
      XCTAssertNil(
        CredentialSafeURLSessionDelegate.redirectedRequest(
          originalRequest: original,
          responseURL: original.url,
          proposedRequest: proposed
        ),
        "Expected credential redirect rejection for \(value)"
      )
    }
  }

  func testPublicRedirectRemainsAvailableWithoutCredentialHeaders() throws {
    let original = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/start")))
    let proposed = URLRequest(url: try XCTUnwrap(URL(string: "https://cdn.example.net/result")))

    XCTAssertNotNil(
      CredentialSafeURLSessionDelegate.redirectedRequest(
        originalRequest: original,
        responseURL: original.url,
        proposedRequest: proposed
      )
    )
  }

  func testPrivateRequestBodyCannotRedirectToAnotherOriginWithoutAPIKey() throws {
    var original = URLRequest(url: try XCTUnwrap(URL(string: "https://ai.example.com/v1/chat")))
    original.httpMethod = "POST"
    original.httpBody = Data("private article body".utf8)
    let proposed = URLRequest(url: try XCTUnwrap(URL(string: "https://collector.example.net/chat")))

    XCTAssertNil(
      CredentialSafeURLSessionDelegate.redirectedRequest(
        originalRequest: original,
        responseURL: original.url,
        proposedRequest: proposed
      )
    )
  }

  func testLoopbackPrivateRequestBodyCanRedirectWithinSameOrigin() throws {
    var original = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:11434/v1/chat")))
    original.httpMethod = "POST"
    original.httpBody = Data("local private article body".utf8)
    let proposed = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:11434/v2/chat")))

    XCTAssertNotNil(
      CredentialSafeURLSessionDelegate.redirectedRequest(
        originalRequest: original,
        responseURL: original.url,
        proposedRequest: proposed
      )
    )
  }

  func testLoopbackRedirectWithoutCredentialsRemainsAvailable() throws {
    let original = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:11434/start")))
    let proposed = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:11434/result")))

    XCTAssertNotNil(
      CredentialSafeURLSessionDelegate.redirectedRequest(
        originalRequest: original,
        responseURL: original.url,
        proposedRequest: proposed
      )
    )
  }

  func testPrivateLiteralFeedAddressRequiresExplicitOptIn() throws {
    let privateURL = try XCTUnwrap(URL(string: "http://192.168.1.10/feed.xml"))

    XCTAssertThrowsError(
      try RSSNetworkURLPolicy.validatedURL(privateURL)
    ) { error in
      guard case RSSReaderError.privateNetworkAccessDenied = error else {
        return XCTFail("Expected private-network rejection, got \(error)")
      }
    }
    XCTAssertNoThrow(
      try RSSNetworkURLPolicy.validatedURL(
        privateURL,
        allowsPrivateNetworkAccess: true
      )
    )
  }

  func testOutOfRangePortIsRejectedBeforePinnedTransport() throws {
    let url = try XCTUnwrap(URL(string: "http://example.com:99999/feed.xml"))

    XCTAssertThrowsError(try RSSNetworkURLPolicy.syntacticallyValidatedURL(url)) { error in
      XCTAssertEqual(error as? RSSReaderError, .invalidFeedURL)
    }
  }

  func testValidatedEndpointReturnsTheAddressesUsedForPinnedConnection() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/feed.xml"))

    let endpoint = try RSSNetworkURLPolicy.validatedEndpoint(
      url,
      resolver: publicResolver
    )

    XCTAssertEqual(endpoint.url, url)
    XCTAssertEqual(endpoint.addresses.map(\.presentation), ["8.8.8.8"])
  }

  func testValidatedEndpointRejectsPrivateDNSAnswerBeforeNetworkIO() throws {
    let privateResolver: RSSNetworkURLPolicy.Resolver = { _ in
      [try XCTUnwrap(KnowledgeResolvedAddress(presentation: "192.168.1.20"))]
    }
    let url = try XCTUnwrap(URL(string: "https://attacker.example/feed.xml"))

    XCTAssertThrowsError(
      try RSSNetworkURLPolicy.validatedEndpoint(url, resolver: privateResolver)
    ) { error in
      guard case RSSReaderError.privateNetworkAccessDenied = error else {
        return XCTFail("Expected private DNS answer to be rejected, got \(error)")
      }
    }
  }

  func testValidatedHTTPProxyIsInstalledInEphemeralSession() throws {
    let session = try CredentialSafeURLSession.makeValidated(
      proxyURL: "http://Proxy.Example:8080"
    )
    let dictionary = try XCTUnwrap(session.configuration.connectionProxyDictionary)

    XCTAssertEqual(
      dictionary[kCFNetworkProxiesHTTPProxy as String] as? String,
      "proxy.example"
    )
    XCTAssertEqual(
      dictionary[kCFNetworkProxiesHTTPPort as String] as? Int,
      8080
    )
    XCTAssertEqual(
      dictionary[kCFNetworkProxiesHTTPSProxy as String] as? String,
      "proxy.example"
    )
  }

  func testValidatedHTTPSProxyUsesTheExplicitHTTPSPort() throws {
    let session = try CredentialSafeURLSession.makeValidated(
      proxyURL: "https://proxy.example:9443/"
    )
    let dictionary = try XCTUnwrap(session.configuration.connectionProxyDictionary)

    XCTAssertEqual(
      dictionary[kCFNetworkProxiesHTTPSPort as String] as? Int,
      9443
    )
  }

  func testValidatedSOCKSProxySelectsTheRequestedVersion() throws {
    let session = try CredentialSafeURLSession.makeValidated(
      proxyURL: "socks4://127.0.0.1:1080"
    )
    let dictionary = try XCTUnwrap(session.configuration.connectionProxyDictionary)

    XCTAssertEqual(
      dictionary[kCFStreamPropertySOCKSProxyHost as String] as? String,
      "127.0.0.1"
    )
    XCTAssertEqual(
      dictionary[kCFStreamPropertySOCKSVersion as String] as? String,
      kCFStreamSocketSOCKSVersion4 as String
    )
  }

  func testInvalidProxyConfigurationFailsClosedBeforeSessionCreation() {
    let invalidValues = [
      "ftp://proxy.example:8080",
      "http://:8080",
      "http://proxy.example:0",
      "http://proxy.example:65536",
      "http://proxy.example:70000",
      "http://user:password@proxy.example:8080",
      "http://proxy.example/path",
    ]

    for value in invalidValues {
      XCTAssertThrowsError(
        try CredentialSafeURLSession.makeValidated(proxyURL: value),
        "Expected strict proxy validation to reject \(value)"
      ) { error in
        XCTAssertTrue(error is CredentialSafeProxyError)
      }
    }
  }

  func testValidatedEndpointAllowsProxySyntheticDNSAnswersForHostname() throws {
    let proxyResolver: RSSNetworkURLPolicy.Resolver = { _ in
      [
        try XCTUnwrap(KnowledgeResolvedAddress(presentation: "198.18.0.42")),
        try XCTUnwrap(KnowledgeResolvedAddress(presentation: "::ffff:198.18.0.42")),
      ]
    }
    let url = try XCTUnwrap(URL(string: "https://public.example/feed.xml"))

    let endpoint = try RSSNetworkURLPolicy.validatedEndpoint(
      url,
      resolver: proxyResolver,
      proxySyntheticNetworkIsActive: true
    )

    XCTAssertEqual(endpoint.url, url)
    XCTAssertEqual(endpoint.addresses.count, 2)
  }

  func testProxySyntheticDNSAnswerIsRejectedWithoutActiveTunnelMapping() throws {
    let proxyResolver: RSSNetworkURLPolicy.Resolver = { _ in
      [try XCTUnwrap(KnowledgeResolvedAddress(presentation: "198.18.0.42"))]
    }
    let url = try XCTUnwrap(URL(string: "https://public.example/feed.xml"))

    XCTAssertThrowsError(
      try RSSNetworkURLPolicy.validatedEndpoint(
        url,
        resolver: proxyResolver,
        proxySyntheticNetworkIsActive: false
      )
    ) { error in
      guard case RSSReaderError.privateNetworkAccessDenied = error else {
        return XCTFail("Expected inactive synthetic mapping rejection, got \(error)")
      }
    }
  }

  func testProxySyntheticLiteralStillRequiresExplicitPrivateNetworkOptIn() throws {
    let literalURL = try XCTUnwrap(URL(string: "http://198.18.0.42/feed.xml"))

    XCTAssertThrowsError(try RSSNetworkURLPolicy.validatedEndpoint(literalURL)) { error in
      guard case RSSReaderError.privateNetworkAccessDenied = error else {
        return XCTFail("Expected synthetic literal rejection, got \(error)")
      }
    }
  }

  func testProxySyntheticAndPrivateMixedDNSAnswerIsRejected() throws {
    let mixedResolver: RSSNetworkURLPolicy.Resolver = { _ in
      [
        try XCTUnwrap(KnowledgeResolvedAddress(presentation: "198.18.0.42")),
        try XCTUnwrap(KnowledgeResolvedAddress(presentation: "192.168.1.20")),
      ]
    }
    let url = try XCTUnwrap(URL(string: "https://mixed.example/feed.xml"))

    XCTAssertThrowsError(
      try RSSNetworkURLPolicy.validatedEndpoint(
        url,
        resolver: mixedResolver,
        proxySyntheticNetworkIsActive: true
      )
    ) { error in
      guard case RSSReaderError.privateNetworkAccessDenied = error else {
        return XCTFail("Expected mixed private DNS answer rejection, got \(error)")
      }
    }
  }

  func testGzipResponseDecodingHonorsDecodedSizeLimit() throws {
    let compressed = try XCTUnwrap(
      Data(
        base64Encoded: "H4sIALV7cWoAA7MpKi62s0nOSMzLS82xs0lJLU4uyiwoyczPs3McBSMa2OgjpwYbfXgi0QelGQCl7RPqOQIAAA=="
      )
    )
    let expected = "<rss><channel><description>"
      + String(repeating: "A", count: 512)
      + "</description></channel></rss>"

    let exactSize = Data(expected.utf8).count
    let decoded = try RSSHTTPContentDecoder.decodedData(
      compressed,
      contentEncoding: "gzip",
      maximumByteCount: exactSize
    )

    XCTAssertEqual(String(data: decoded, encoding: .utf8), expected)
    XCTAssertThrowsError(
      try RSSHTTPContentDecoder.decodedData(
        compressed,
        contentEncoding: "gzip",
        maximumByteCount: exactSize - 1
      )
    ) { error in
      XCTAssertEqual(
        error as? HTTPResponseLimitError,
        .responseTooLarge(maximumByteCount: exactSize - 1)
      )
    }
  }

  func testGzipDecoderRejectsTruncatedAndMalformedBodies() throws {
    let compressed = try XCTUnwrap(
      Data(
        base64Encoded: "H4sIANh2cWoAA7MpKi62s0nOSMzLS82xsynJLMlJtXva1/18z8oX6xa9nNFqow8Rs9GHK9IH6QEA+QZ/yTkAAAA="
      )
    )

    for invalid in [Data(compressed.dropLast()), Data([0x1f, 0x8b, 0x08, 0x00])] {
      XCTAssertThrowsError(
        try RSSHTTPContentDecoder.decodedData(
          invalid,
          contentEncoding: "gzip",
          maximumByteCount: 1_024
        )
      )
    }
  }

  func testDeflateDecoderAcceptsZlibAndLegacyRawFraming() throws {
    let expected = "<rss><channel><title>deflate</title></channel></rss>"
    let fixtures = [
      "eJyzKSoutrNJzkjMy0vNsbMpySzJSbVLSU3LSSxJtdGHcG304fL6IOUA+1gS5Q==",
      "sykqLrazSc5IzMtLzbGzKcksyUm1S0lNy0ksSbXRh3Bt9OHy+iDlAA==",
    ]

    for fixture in fixtures {
      let compressed = try XCTUnwrap(Data(base64Encoded: fixture))
      let decoded = try RSSHTTPContentDecoder.decodedData(
        compressed,
        contentEncoding: "deflate",
        maximumByteCount: 1_024
      )
      XCTAssertEqual(String(data: decoded, encoding: .utf8), expected)
    }
  }

  func testPinnedRequestUsesSchemeDefaultPortAndSingleIPv6Brackets() throws {
    let http443 = try XCTUnwrap(URL(string: "http://example.com:443/feed.xml"))
    let ipv6 = try XCTUnwrap(URL(string: "https://[2001:db8::1]:8443/feed.xml"))

    let httpRequest = try KnowledgePinnedHTTPSClient.encodedRequest(
      URLRequest(url: http443),
      url: http443
    )
    let ipv6Request = try KnowledgePinnedHTTPSClient.encodedRequest(
      URLRequest(url: ipv6),
      url: ipv6
    )
    let httpText = try XCTUnwrap(String(data: httpRequest, encoding: .utf8))
    let ipv6Text = try XCTUnwrap(String(data: ipv6Request, encoding: .utf8))

    XCTAssertTrue(httpText.contains("\r\nHost: example.com:443\r\n"))
    XCTAssertTrue(ipv6Text.contains("\r\nHost: [2001:db8::1]:8443\r\n"))
    XCTAssertFalse(ipv6Text.contains("[[2001:db8::1]]"))
  }
}
