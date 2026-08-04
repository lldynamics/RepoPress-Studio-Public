import Darwin
import Foundation
import zlib
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum RSSNetworkURLPolicy {
  typealias Resolver = @Sendable (String) throws -> [KnowledgeResolvedAddress]

  struct ValidatedEndpoint: Hashable, Sendable {
    let url: URL
    let addresses: [KnowledgeResolvedAddress]
  }

  static let defaultResolver: Resolver = { host in
    try KnowledgeWebDownloadPolicy.resolveAddresses(host)
  }

  static func validatedURL(
    _ url: URL,
    allowsPrivateNetworkAccess: Bool = false,
    resolver: Resolver = defaultResolver,
    proxySyntheticNetworkIsActive: Bool? = nil
  ) throws -> URL {
    try validatedEndpoint(
      url,
      allowsPrivateNetworkAccess: allowsPrivateNetworkAccess,
      resolver: resolver,
      proxySyntheticNetworkIsActive: proxySyntheticNetworkIsActive
    ).url
  }

  /// Validates the URL and returns the exact addresses that may be used for
  /// the request. Callers should use those addresses for the connection so a
  /// DNS answer cannot change between validation and the actual network I/O.
  static func validatedEndpoint(
    _ url: URL,
    allowsPrivateNetworkAccess: Bool = false,
    resolver: Resolver = defaultResolver,
    proxySyntheticNetworkIsActive: Bool? = nil
  ) throws -> ValidatedEndpoint {
    let candidate = try syntacticallyValidatedURL(
      url,
      allowsPrivateNetworkAccess: allowsPrivateNetworkAccess
    )
    let normalizedHost = try normalizedHost(of: candidate)

    let literalAddress = KnowledgeResolvedAddress(presentation: normalizedHost)
    let addresses: [KnowledgeResolvedAddress]
    if let literalAddress {
      addresses = [literalAddress]
    } else {
      do {
        addresses = try resolver(normalizedHost)
      } catch {
        throw RSSReaderError.network("无法安全解析订阅地址。")
      }
    }
    guard !addresses.isEmpty else {
      throw RSSReaderError.network("无法安全解析订阅地址。")
    }
    // Packet-tunnel proxies such as Shadowrocket commonly synthesize
    // 198.18.0.0/15 DNS answers for otherwise public hostnames. Permit that
    // mapping only when it came from resolving a hostname. A URL whose host
    // is itself an IP literal still has to pass the ordinary public-address
    // check, so this does not turn benchmark/private literals into an SSRF
    // escape hatch.
    let containsProxySyntheticAddress = addresses.contains(
      where: \.isProxySyntheticBenchmarkAddress
    )
    let permitsProxySyntheticAddress = literalAddress == nil
      && containsProxySyntheticAddress
      && (proxySyntheticNetworkIsActive ?? hasActiveProxySyntheticNetwork())
    guard allowsPrivateNetworkAccess || addresses.allSatisfy({ address in
      address.isPubliclyRoutable
        || (permitsProxySyntheticAddress && address.isProxySyntheticBenchmarkAddress)
    }) else {
      throw RSSReaderError.privateNetworkAccessDenied
    }
    return ValidatedEndpoint(
      url: candidate,
      addresses: Array(addresses.sorted { $0.presentation < $1.presentation }.prefix(8))
    )
  }

  /// Validates an address that will only be stored or displayed. Hostnames
  /// are resolved again immediately before every network request; resolving
  /// them here would make adding a subscription depend on current DNS access.
  static func syntacticallyValidatedURL(
    _ url: URL,
    allowsPrivateNetworkAccess: Bool = false
  ) throws -> URL {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased() else {
      throw RSSReaderError.invalidFeedURL
    }
    guard scheme == "http" || scheme == "https" else {
      throw RSSReaderError.unsupportedFeedURL
    }
    guard let host = components.host?.nilIfEmpty,
          components.user == nil,
          components.password == nil,
          components.port.map({ (1...65_535).contains($0) }) ?? true,
          let candidate = components.url else {
      throw RSSReaderError.invalidFeedURL
    }
    if !allowsPrivateNetworkAccess {
      let normalizedHost = host
        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        .lowercased()
      guard !isLocalHostname(normalizedHost),
            KnowledgeResolvedAddress(presentation: normalizedHost)?.isPubliclyRoutable != false else {
        throw RSSReaderError.privateNetworkAccessDenied
      }
    }
    return candidate
  }

  static func isSyntacticallyAllowed(_ url: URL) -> Bool {
    (try? syntacticallyValidatedURL(url, allowsPrivateNetworkAccess: true)) != nil
  }

  private static func normalizedHost(of url: URL) throws -> String {
    guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.nilIfEmpty else {
      throw RSSReaderError.invalidFeedURL
    }
    return host
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
      .lowercased()
  }

  private static func isLocalHostname(_ host: String) -> Bool {
    host == "localhost"
      || host.hasSuffix(".localhost")
      || host.hasSuffix(".local")
      || host.hasSuffix(".internal")
      || host == "home.arpa"
      || host.hasSuffix(".home.arpa")
  }

  private static func hasActiveProxySyntheticNetwork() -> Bool {
    var firstAddress: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&firstAddress) == 0, let firstAddress else { return false }
    defer { freeifaddrs(firstAddress) }

    let requiredFlags = UInt32(IFF_UP | IFF_RUNNING | IFF_POINTOPOINT)
    var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
    while let current = cursor {
      cursor = current.pointee.ifa_next
      let interface = current.pointee
      guard interface.ifa_flags & requiredFlags == requiredFlags,
            let namePointer = interface.ifa_name,
            String(cString: namePointer).hasPrefix("utun"),
            let socketAddress = interface.ifa_addr,
            socketAddress.pointee.sa_family == sa_family_t(AF_INET) else {
        continue
      }

      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(
        socketAddress,
        socklen_t(socketAddress.pointee.sa_len),
        &buffer,
        socklen_t(buffer.count),
        nil,
        0,
        NI_NUMERICHOST
      ) == 0,
      let address = KnowledgeResolvedAddress(presentation: String(cString: buffer)),
      address.isProxySyntheticBenchmarkAddress else {
        continue
      }
      return true
    }
    return false
  }
}

private extension KnowledgeResolvedAddress {
  /// RFC 2544 benchmarking addresses are used as synthetic DNS answers by
  /// common macOS packet-tunnel proxies. This includes the IPv4-mapped IPv6
  /// representation returned by some resolvers.
  var isProxySyntheticBenchmarkAddress: Bool {
    switch self {
    case .ipv4(let bytes):
      return bytes.count == 4
        && bytes[0] == 198
        && (18...19).contains(bytes[1])
    case .ipv6(let bytes):
      guard bytes.count == 16,
            bytes.prefix(10).allSatisfy({ $0 == 0 }),
            bytes[10] == 0xff,
            bytes[11] == 0xff else {
        return false
      }
      return bytes[12] == 198 && (18...19).contains(bytes[13])
    }
  }
}

enum RSSHTTPContentDecoder {
  private enum InflateError: Error {
    case initializationFailed
    case malformedOrIncomplete
  }

  static func decodedData(
    _ data: Data,
    contentEncoding: String?,
    maximumByteCount: Int
  ) throws -> Data {
    guard maximumByteCount > 0 else {
      throw HTTPResponseLimitError.invalidLimit
    }
    guard data.count <= maximumByteCount else {
      throw HTTPResponseLimitError.responseTooLarge(maximumByteCount: maximumByteCount)
    }
    guard !data.isEmpty else { return data }

    let encoding = contentEncoding?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    switch encoding {
    case nil, "", "identity":
      return data
    case "gzip", "x-gzip":
      do {
        return try inflate(
          data,
          windowBits: MAX_WBITS + 16,
          maximumByteCount: maximumByteCount
        )
      } catch is InflateError {
        throw RSSReaderError.network("订阅响应的 gzip 压缩内容已损坏或不完整。")
      }
    case "deflate":
      do {
        return try inflate(
          data,
          windowBits: MAX_WBITS,
          maximumByteCount: maximumByteCount
        )
      } catch is InflateError {
        // A number of HTTP servers historically sent raw DEFLATE despite the
        // specification requiring a zlib wrapper. Retry from the beginning
        // with raw framing while retaining the same decoded-size limit.
        do {
          return try inflate(
            data,
            windowBits: -MAX_WBITS,
            maximumByteCount: maximumByteCount
          )
        } catch is InflateError {
          throw RSSReaderError.network("订阅响应的 deflate 压缩内容已损坏或不完整。")
        }
      }
    default:
      throw RSSReaderError.network("订阅响应使用了不支持的压缩格式。")
    }
  }

  private static func inflate(
    _ compressed: Data,
    windowBits: Int32,
    maximumByteCount: Int
  ) throws -> Data {
    guard compressed.count <= Int(uInt.max) else {
      throw HTTPResponseLimitError.responseTooLarge(maximumByteCount: maximumByteCount)
    }

    var stream = z_stream()
    let initializationStatus = inflateInit2_(
      &stream,
      windowBits,
      ZLIB_VERSION,
      Int32(MemoryLayout<z_stream>.size)
    )
    guard initializationStatus == Z_OK else {
      throw InflateError.initializationFailed
    }
    defer { inflateEnd(&stream) }

    return try compressed.withUnsafeBytes { inputBytes in
      let input = inputBytes.bindMemory(to: Bytef.self)
      guard let inputBaseAddress = input.baseAddress else { return Data() }
      stream.next_in = UnsafeMutablePointer(mutating: inputBaseAddress)
      stream.avail_in = uInt(input.count)

      var output = Data()
      var status = Z_OK
      repeat {
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        status = chunk.withUnsafeMutableBytes { outputBytes in
          let destination = outputBytes.bindMemory(to: Bytef.self)
          stream.next_out = destination.baseAddress
          stream.avail_out = uInt(destination.count)
          return zlib.inflate(&stream, Z_NO_FLUSH)
        }

        let produced = chunk.count - Int(stream.avail_out)
        let nextSize = output.count.addingReportingOverflow(produced)
        guard !nextSize.overflow, nextSize.partialValue <= maximumByteCount else {
          throw HTTPResponseLimitError.responseTooLarge(maximumByteCount: maximumByteCount)
        }
        if produced > 0 {
          output.append(contentsOf: chunk.prefix(produced))
        }

        guard status == Z_OK || status == Z_STREAM_END else {
          throw InflateError.malformedOrIncomplete
        }
        if status == Z_OK, produced == 0, stream.avail_in == 0 {
          throw InflateError.malformedOrIncomplete
        }
      } while status != Z_STREAM_END
      return output
    }
  }
}

/// A redirect-aware, DNS-pinned GET client for RSS and article resources.
/// It deliberately forwards only the safe request-header allowlist owned by
/// `KnowledgePinnedHTTPSClient`; cookies, credentials and Referer never cross
/// the RSS network boundary.
enum RSSNetworkHTTPClient {
  static let maximumRedirectCount = 5

  static func data(
    for originalRequest: URLRequest,
    maximumByteCount: Int,
    allowsPrivateNetworkAccess: Bool,
    resolver: @escaping RSSNetworkURLPolicy.Resolver = RSSNetworkURLPolicy.defaultResolver
  ) async throws -> (Data, HTTPURLResponse) {
    guard maximumByteCount > 0,
          let originalURL = originalRequest.url,
          (originalRequest.httpMethod?.uppercased() ?? "GET") == "GET",
          originalRequest.httpBody == nil,
          originalRequest.httpBodyStream == nil else {
      throw RSSReaderError.invalidFeedURL
    }

    var request = originalRequest
    var currentURL = originalURL
    for redirectCount in 0...Self.maximumRedirectCount {
      try Task.checkCancellation()
      let endpoint = try RSSNetworkURLPolicy.validatedEndpoint(
        currentURL,
        allowsPrivateNetworkAccess: allowsPrivateNetworkAccess,
        resolver: resolver
      )
      request.url = endpoint.url
      let received: KnowledgePinnedHTTPResponse
      do {
        received = try await KnowledgePinnedHTTPSClient.fetch(
          request: request,
          addresses: endpoint.addresses,
          maximumByteCount: maximumByteCount
        )
      } catch KnowledgeWebDownloadError.byteLimitExceeded {
        throw HTTPResponseLimitError.responseTooLarge(maximumByteCount: maximumByteCount)
      }
      guard [301, 302, 303, 307, 308].contains(received.statusCode) else {
        let decodedData = try RSSHTTPContentDecoder.decodedData(
          received.data,
          contentEncoding: received.header("content-encoding"),
          maximumByteCount: maximumByteCount
        )
        var responseHeaders = received.headerFields
        if received.header("content-encoding")?.lowercased() != nil {
          responseHeaders.removeValue(forKey: "content-encoding")
          responseHeaders["content-length"] = String(decodedData.count)
        }
        guard let response = HTTPURLResponse(
          url: endpoint.url,
          statusCode: received.statusCode,
          httpVersion: "HTTP/1.1",
          headerFields: responseHeaders
        ) else {
          throw RSSReaderError.invalidHTTPResponse
        }
        return (decodedData, response)
      }
      guard redirectCount < Self.maximumRedirectCount,
            let location = received.header("location"),
            let destination = URL(string: location, relativeTo: endpoint.url)?.absoluteURL else {
        throw RSSReaderError.network("网页重定向地址无法安全验证。")
      }

      currentURL = destination
      request = originalRequest
      request.url = destination
      // Conditional validators belong to the original origin. Do not carry
      // them across a redirect, and never carry stateful headers at all.
      request.setValue(nil, forHTTPHeaderField: "If-None-Match")
      request.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
      request.setValue(nil, forHTTPHeaderField: "Referer")
      request.setValue(nil, forHTTPHeaderField: "Cookie")
      request.setValue(nil, forHTTPHeaderField: "Authorization")
    }
    throw RSSReaderError.network("网页重定向次数过多。")
  }
}

final class CredentialSafeURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private static let credentialHeaders = ["Authorization", "PRIVATE-TOKEN", "X-API-Key"]

  static func redirectedRequest(
    originalRequest: URLRequest?,
    responseURL: URL?,
    proposedRequest: URLRequest
  ) -> URLRequest? {
    let containsCredential = credentialHeaders.contains { header in
      originalRequest?.value(forHTTPHeaderField: header)?.isEmpty == false
    }
    let method = originalRequest?.httpMethod?.uppercased() ?? "GET"
    let containsSensitiveBody = method != "GET" && method != "HEAD"
      && (originalRequest?.httpBody != nil || originalRequest?.httpBodyStream != nil)
    guard containsCredential || containsSensitiveBody else { return proposedRequest }
    guard let sourceURL = responseURL ?? originalRequest?.url,
          let destinationURL = proposedRequest.url else {
      return nil
    }
    let isAllowed = containsCredential
      ? CredentialedEndpointPolicy.isAllowedCredentialRedirect(from: sourceURL, to: destinationURL)
      : CredentialedEndpointPolicy.isAllowedSensitiveBodyRedirect(from: sourceURL, to: destinationURL)
    guard isAllowed else { return nil }
    return proposedRequest
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(
      Self.redirectedRequest(
        originalRequest: task.originalRequest,
        responseURL: response.url,
        proposedRequest: request
      )
    )
  }
}

enum CredentialSafeURLSession {
  static func make(
    timeoutIntervalForRequest: TimeInterval = 60,
    timeoutIntervalForResource: TimeInterval = 7 * 24 * 60 * 60
  ) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.timeoutIntervalForRequest = timeoutIntervalForRequest
    configuration.timeoutIntervalForResource = timeoutIntervalForResource
    return URLSession(
      configuration: configuration,
      delegate: CredentialSafeURLSessionDelegate(),
      delegateQueue: nil
    )
  }
}
