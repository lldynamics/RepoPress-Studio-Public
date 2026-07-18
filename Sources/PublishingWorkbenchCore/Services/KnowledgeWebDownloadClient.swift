import Darwin
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum KnowledgeWebDownloadError: LocalizedError, Hashable, Sendable {
  case invalidURL
  case blockedAddress(String)
  case addressResolutionFailed(String)
  case redirectBlocked(String)
  case invalidResponse
  case httpStatus(Int)
  case unsupportedContentType(String)
  case byteLimitExceeded(Int)

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      "请输入不含账号信息的有效 HTTPS 网页地址。"
    case .blockedAddress(let host):
      "已阻止访问本机、私网或不可公开路由的地址：\(host)。"
    case .addressResolutionFailed(let host):
      "无法安全解析网页地址：\(host)。"
    case .redirectBlocked(let value):
      "网页重定向到不安全地址，已停止下载：\(value)。"
    case .invalidResponse:
      "服务器响应无效。"
    case .httpStatus(let status):
      "HTTP \(status)"
    case .unsupportedContentType(let value):
      "服务器返回了不支持的内容类型：\(value)。"
    case .byteLimitExceeded(let maximumByteCount):
      "网页内容超过 \(ByteCountFormatter.string(fromByteCount: Int64(maximumByteCount), countStyle: .file))，已停止下载。"
    }
  }
}

enum KnowledgeResolvedAddress: Hashable, Sendable {
  case ipv4([UInt8])
  case ipv6([UInt8])

  init?(presentation: String) {
    var ipv4 = in_addr()
    if presentation.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
      self = .ipv4(withUnsafeBytes(of: &ipv4) { Array($0) })
      return
    }

    var ipv6 = in6_addr()
    if presentation.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
      self = .ipv6(withUnsafeBytes(of: &ipv6) { Array($0) })
      return
    }
    return nil
  }

  var isPubliclyRoutable: Bool {
    switch self {
    case .ipv4(let bytes):
      guard bytes.count == 4 else { return false }
      let first = bytes[0]
      let second = bytes[1]
      let third = bytes[2]

      if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
      if first == 100 && (64...127).contains(second) { return false }
      if first == 169 && second == 254 { return false }
      if first == 172 && (16...31).contains(second) { return false }
      if first == 192 && second == 0 && third == 0 { return false }
      if first == 192 && second == 0 && third == 2 { return false }
      if first == 192 && second == 168 { return false }
      if first == 198 && (18...19).contains(second) { return false }
      if first == 198 && second == 51 && third == 100 { return false }
      if first == 203 && second == 0 && third == 113 { return false }
      return true

    case .ipv6(let bytes):
      guard bytes.count == 16 else { return false }
      // Public IPv6 global-unicast addresses currently live in 2000::/3.
      // This intentionally excludes loopback, link-local, unique-local,
      // multicast, documentation and IPv4-mapped destinations.
      guard bytes[0] & 0xe0 == 0x20 else { return false }
      if bytes[0] == 0x20,
         bytes[1] == 0x01,
         bytes[2] == 0x0d,
         bytes[3] == 0xb8 {
        return false
      }
      return true
    }
  }
}

enum KnowledgeWebDownloadPolicy {
  typealias Resolver = (String) throws -> [KnowledgeResolvedAddress]

  static func validatedURL(
    _ url: URL,
    resolver: Resolver = resolveAddresses
  ) throws -> URL {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.lowercased() == "https",
          let host = components.host?.nilIfEmpty,
          components.user == nil,
          components.password == nil,
          let candidate = components.url else {
      throw KnowledgeWebDownloadError.invalidURL
    }

    let normalizedHost = host
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
      .lowercased()
    guard !isLocalHostname(normalizedHost) else {
      throw KnowledgeWebDownloadError.blockedAddress(host)
    }

    let addresses: [KnowledgeResolvedAddress]
    if let literal = KnowledgeResolvedAddress(presentation: normalizedHost) {
      addresses = [literal]
    } else {
      do {
        addresses = try resolver(normalizedHost)
      } catch {
        throw KnowledgeWebDownloadError.addressResolutionFailed(host)
      }
    }
    guard !addresses.isEmpty else {
      throw KnowledgeWebDownloadError.addressResolutionFailed(host)
    }
    guard addresses.allSatisfy(\.isPubliclyRoutable) else {
      throw KnowledgeWebDownloadError.blockedAddress(host)
    }
    return candidate
  }

  static func resolveAddresses(_ host: String) throws -> [KnowledgeResolvedAddress] {
    if let literal = KnowledgeResolvedAddress(presentation: host) {
      return [literal]
    }

    var hints = addrinfo()
    hints.ai_flags = AI_ADDRCONFIG
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP

    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, nil, &hints, &result)
    guard status == 0, let first = result else {
      throw KnowledgeWebDownloadError.addressResolutionFailed(host)
    }
    defer { freeaddrinfo(first) }

    var addresses = Set<KnowledgeResolvedAddress>()
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let info = cursor?.pointee {
      if info.ai_family == AF_INET || info.ai_family == AF_INET6,
         let socketAddress = info.ai_addr {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(
          socketAddress,
          info.ai_addrlen,
          &buffer,
          socklen_t(buffer.count),
          nil,
          0,
          NI_NUMERICHOST
        ) == 0,
           let address = KnowledgeResolvedAddress(presentation: String(cString: buffer)) {
          addresses.insert(address)
        }
      }
      cursor = info.ai_next
    }
    return Array(addresses)
  }

  private static func isLocalHostname(_ host: String) -> Bool {
    host == "localhost"
      || host.hasSuffix(".localhost")
      || host.hasSuffix(".local")
      || host.hasSuffix(".internal")
      || host == "home.arpa"
      || host.hasSuffix(".home.arpa")
  }
}

final class KnowledgeWebDownloadSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let resolver: KnowledgeWebDownloadPolicy.Resolver
  private let lock = NSLock()
  private var rejection: KnowledgeWebDownloadError?

  init(resolver: @escaping KnowledgeWebDownloadPolicy.Resolver = KnowledgeWebDownloadPolicy.resolveAddresses) {
    self.resolver = resolver
  }

  var redirectRejection: KnowledgeWebDownloadError? {
    lock.lock()
    defer { lock.unlock() }
    return rejection
  }

  static func redirectedRequest(
    proposedRequest: URLRequest,
    resolver: KnowledgeWebDownloadPolicy.Resolver
  ) -> URLRequest? {
    guard let url = proposedRequest.url,
          (try? KnowledgeWebDownloadPolicy.validatedURL(url, resolver: resolver)) != nil else {
      return nil
    }
    return proposedRequest
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let destinationURL = request.url else {
      record(.redirectBlocked("未知地址"))
      completionHandler(nil)
      return
    }
    do {
      _ = try KnowledgeWebDownloadPolicy.validatedURL(destinationURL, resolver: resolver)
      completionHandler(request)
    } catch {
      record(.redirectBlocked(destinationURL.absoluteString))
      completionHandler(nil)
    }
  }

  private func record(_ error: KnowledgeWebDownloadError) {
    lock.lock()
    rejection = error
    lock.unlock()
  }
}

struct KnowledgeWebDownloadBuffer: Sendable {
  let maximumByteCount: Int
  private(set) var data = Data()

  init(maximumByteCount: Int, expectedByteCount: Int64 = NSURLSessionTransferSizeUnknown) throws {
    self.maximumByteCount = max(1, maximumByteCount)
    if expectedByteCount > Int64(self.maximumByteCount) {
      throw KnowledgeWebDownloadError.byteLimitExceeded(self.maximumByteCount)
    }
    if expectedByteCount > 0 {
      data.reserveCapacity(min(self.maximumByteCount, Int(expectedByteCount)))
    }
  }

  mutating func append(_ byte: UInt8) throws {
    guard data.count < maximumByteCount else {
      throw KnowledgeWebDownloadError.byteLimitExceeded(maximumByteCount)
    }
    data.append(byte)
  }
}

struct KnowledgeWebDownloadResponse: Sendable {
  var data: Data
  var response: HTTPURLResponse
}

struct KnowledgeWebDownloadClient: Sendable {
  static let allowedMIMETypes: Set<String> = [
    "text/html",
    "application/xhtml+xml",
    "text/plain",
  ]

  func download(
    request originalRequest: URLRequest,
    maximumByteCount: Int
  ) async throws -> KnowledgeWebDownloadResponse {
    guard let originalURL = originalRequest.url else {
      throw KnowledgeWebDownloadError.invalidURL
    }
    let safeURL = try KnowledgeWebDownloadPolicy.validatedURL(originalURL)
    var request = originalRequest
    request.url = safeURL

    let delegate = KnowledgeWebDownloadSessionDelegate()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.timeoutIntervalForRequest = 25
    configuration.timeoutIntervalForResource = 30
    let session = URLSession(
      configuration: configuration,
      delegate: delegate,
      delegateQueue: nil
    )
    defer { session.invalidateAndCancel() }

    do {
      let (bytes, response) = try await session.bytes(for: request)
      if let rejection = delegate.redirectRejection { throw rejection }
      guard let httpResponse = response as? HTTPURLResponse else {
        throw KnowledgeWebDownloadError.invalidResponse
      }
      guard (200..<300).contains(httpResponse.statusCode) else {
        throw KnowledgeWebDownloadError.httpStatus(httpResponse.statusCode)
      }
      let mimeType = httpResponse.mimeType?.lowercased() ?? ""
      guard Self.allowedMIMETypes.contains(mimeType) else {
        throw KnowledgeWebDownloadError.unsupportedContentType(
          mimeType.nilIfEmpty ?? "未知"
        )
      }

      var buffer = try KnowledgeWebDownloadBuffer(
        maximumByteCount: maximumByteCount,
        expectedByteCount: response.expectedContentLength
      )
      for try await byte in bytes {
        try Task.checkCancellation()
        try buffer.append(byte)
      }
      return KnowledgeWebDownloadResponse(data: buffer.data, response: httpResponse)
    } catch {
      if let rejection = delegate.redirectRejection { throw rejection }
      throw error
    }
  }
}
