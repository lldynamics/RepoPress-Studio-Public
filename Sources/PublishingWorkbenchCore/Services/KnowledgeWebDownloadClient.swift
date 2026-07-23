import Darwin
import Foundation
import Network
import Security
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
  case unsupportedContentEncoding(String)
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
    case .unsupportedContentEncoding(let value):
      "服务器返回了不支持的压缩格式：\(value)。"
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

  var presentation: String {
    switch self {
    case .ipv4(let bytes):
      return bytes.map(String.init).joined(separator: ".")
    case .ipv6(let bytes):
      return stride(from: 0, to: bytes.count, by: 2).map { index in
        let high = UInt16(bytes[index]) << 8
        let low = UInt16(bytes[index + 1])
        return String(high | low, radix: 16)
      }.joined(separator: ":")
    }
  }
}

enum KnowledgeWebDownloadPolicy {
  typealias Resolver = @Sendable (String) throws -> [KnowledgeResolvedAddress]

  static let defaultResolver: Resolver = { host in
    try resolveAddresses(host)
  }

  struct ValidatedEndpoint: Hashable, Sendable {
    var url: URL
    var addresses: [KnowledgeResolvedAddress]
  }

  static func validatedURL(
    _ url: URL,
    resolver: Resolver = defaultResolver
  ) throws -> URL {
    try validatedEndpoint(url, resolver: resolver).url
  }

  static func validatedEndpoint(
    _ url: URL,
    resolver: Resolver = defaultResolver
  ) throws -> ValidatedEndpoint {
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
    return ValidatedEndpoint(
      url: candidate,
      addresses: Array(
        addresses.sorted { $0.presentation < $1.presentation }.prefix(8)
      )
    )
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

struct KnowledgeWebDownloadResponse: Sendable {
  var data: Data
  var response: HTTPURLResponse
}

struct KnowledgePinnedHTTPResponse: Sendable {
  var data: Data
  var statusCode: Int
  var headerFields: [String: String]

  func header(_ name: String) -> String? {
    headerFields[name.lowercased()]
  }
}

enum KnowledgeHTTP1ResponseParser {
  private static let headerDelimiter = Data("\r\n\r\n".utf8)
  private static let lineDelimiter = Data("\r\n".utf8)
  private static let maximumHeaderByteCount = 64 * 1_024

  static func response(
    from wireData: Data,
    maximumBodyByteCount: Int,
    connectionIsComplete: Bool
  ) throws -> KnowledgePinnedHTTPResponse? {
    guard let headerRange = wireData.range(of: headerDelimiter) else {
      if wireData.count > maximumHeaderByteCount || connectionIsComplete {
        throw KnowledgeWebDownloadError.invalidResponse
      }
      return nil
    }
    guard headerRange.lowerBound <= maximumHeaderByteCount,
          let headerText = String(
            data: wireData[..<headerRange.lowerBound],
            encoding: .isoLatin1
          ) else {
      throw KnowledgeWebDownloadError.invalidResponse
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let statusLine = lines.first else {
      throw KnowledgeWebDownloadError.invalidResponse
    }
    let statusParts = statusLine.split(separator: " ", maxSplits: 2)
    guard statusParts.count >= 2,
          statusParts[0].hasPrefix("HTTP/1."),
          let statusCode = Int(statusParts[1]),
          (100...599).contains(statusCode) else {
      throw KnowledgeWebDownloadError.invalidResponse
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
            let separator = line.firstIndex(of: ":") else {
        throw KnowledgeWebDownloadError.invalidResponse
      }
      let name = line[..<separator]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      let value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty,
            name.unicodeScalars.allSatisfy({ scalar in
              scalar.value > 0x20 && scalar.value < 0x7f && scalar.value != 0x3a
            }),
            !value.contains("\0") else {
        throw KnowledgeWebDownloadError.invalidResponse
      }
      headers[name] = headers[name].map { "\($0), \(value)" } ?? value
    }

    if [301, 302, 303, 307, 308].contains(statusCode) || !(200..<300).contains(statusCode) {
      return KnowledgePinnedHTTPResponse(
        data: Data(),
        statusCode: statusCode,
        headerFields: headers
      )
    }

    let body = Data(wireData[headerRange.upperBound...])
    if let transferEncoding = headers["transfer-encoding"]?.lowercased() {
      guard transferEncoding
        .split(separator: ",")
        .map({ $0.trimmingCharacters(in: .whitespaces) }) == ["chunked"] else {
        throw KnowledgeWebDownloadError.invalidResponse
      }
      guard let decodedBody = try decodeChunkedBody(
        body,
        maximumByteCount: maximumBodyByteCount,
        connectionIsComplete: connectionIsComplete
      ) else {
        return nil
      }
      return KnowledgePinnedHTTPResponse(
        data: decodedBody,
        statusCode: statusCode,
        headerFields: headers
      )
    }

    if let rawLength = headers["content-length"] {
      guard rawLength.allSatisfy(\.isNumber),
            let contentLength = Int(rawLength),
            contentLength >= 0 else {
        throw KnowledgeWebDownloadError.invalidResponse
      }
      guard contentLength <= maximumBodyByteCount else {
        throw KnowledgeWebDownloadError.byteLimitExceeded(maximumBodyByteCount)
      }
      guard body.count >= contentLength else {
        if connectionIsComplete { throw KnowledgeWebDownloadError.invalidResponse }
        return nil
      }
      return KnowledgePinnedHTTPResponse(
        data: Data(body.prefix(contentLength)),
        statusCode: statusCode,
        headerFields: headers
      )
    }

    guard body.count <= maximumBodyByteCount else {
      throw KnowledgeWebDownloadError.byteLimitExceeded(maximumBodyByteCount)
    }
    guard connectionIsComplete else { return nil }
    return KnowledgePinnedHTTPResponse(
      data: body,
      statusCode: statusCode,
      headerFields: headers
    )
  }

  private static func decodeChunkedBody(
    _ body: Data,
    maximumByteCount: Int,
    connectionIsComplete: Bool
  ) throws -> Data? {
    var cursor = body.startIndex
    var decoded = Data()
    while true {
      guard let lineRange = body.range(of: lineDelimiter, in: cursor..<body.endIndex) else {
        if connectionIsComplete { throw KnowledgeWebDownloadError.invalidResponse }
        return nil
      }
      guard let sizeLine = String(
        data: body[cursor..<lineRange.lowerBound],
        encoding: .ascii
      ),
      let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first,
      !sizeToken.isEmpty,
      sizeToken.allSatisfy({ $0.isHexDigit }),
      let chunkSize = Int(sizeToken, radix: 16),
      chunkSize >= 0 else {
        throw KnowledgeWebDownloadError.invalidResponse
      }
      cursor = lineRange.upperBound

      if chunkSize == 0 {
        if body.distance(from: cursor, to: body.endIndex) >= 2,
           body[cursor] == 0x0d,
           body[body.index(after: cursor)] == 0x0a {
          return decoded
        }
        guard body.range(of: headerDelimiter, in: cursor..<body.endIndex) != nil else {
          if connectionIsComplete { throw KnowledgeWebDownloadError.invalidResponse }
          return nil
        }
        return decoded
      }

      let addition = decoded.count.addingReportingOverflow(chunkSize)
      guard !addition.overflow, addition.partialValue <= maximumByteCount else {
        throw KnowledgeWebDownloadError.byteLimitExceeded(maximumByteCount)
      }
      guard body.distance(from: cursor, to: body.endIndex) >= chunkSize + 2 else {
        if connectionIsComplete { throw KnowledgeWebDownloadError.invalidResponse }
        return nil
      }
      let chunkEnd = body.index(cursor, offsetBy: chunkSize)
      let suffixEnd = body.index(chunkEnd, offsetBy: 2)
      guard body[chunkEnd] == 0x0d,
            body[body.index(after: chunkEnd)] == 0x0a else {
        throw KnowledgeWebDownloadError.invalidResponse
      }
      decoded.append(body[cursor..<chunkEnd])
      cursor = suffixEnd
    }
  }
}

private final class KnowledgePinnedHTTPSOperation: @unchecked Sendable {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "com.jinfang.knowledge-web-download.pinned")
  private let requestData: Data
  private let maximumBodyByteCount: Int
  private let maximumWireByteCount: Int
  private let timeout: TimeInterval
  private var wireData = Data()
  private var continuation: CheckedContinuation<KnowledgePinnedHTTPResponse, Error>?
  private var didSendRequest = false

  init(
    url: URL,
    address: KnowledgeResolvedAddress,
    requestData: Data,
    maximumBodyByteCount: Int,
    timeout: TimeInterval
  ) throws {
    guard let host = url.host,
          let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) else {
      throw KnowledgeWebDownloadError.invalidURL
    }
    let tlsOptions = NWProtocolTLS.Options()
    host.withCString {
      sec_protocol_options_set_tls_server_name(
        tlsOptions.securityProtocolOptions,
        $0
      )
    }
    "http/1.1".withCString {
      sec_protocol_options_add_tls_application_protocol(
        tlsOptions.securityProtocolOptions,
        $0
      )
    }
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
    parameters.allowLocalEndpointReuse = false
    connection = NWConnection(
      host: NWEndpoint.Host(address.presentation),
      port: port,
      using: parameters
    )
    self.requestData = requestData
    self.maximumBodyByteCount = maximumBodyByteCount
    let wireLimit = maximumBodyByteCount.addingReportingOverflow(512 * 1_024)
    guard !wireLimit.overflow else {
      throw KnowledgeWebDownloadError.byteLimitExceeded(maximumBodyByteCount)
    }
    self.maximumWireByteCount = wireLimit.partialValue
    self.timeout = min(30, max(1, timeout))
  }

  func execute() async throws -> KnowledgePinnedHTTPResponse {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        connection.stateUpdateHandler = { [weak self] state in
          self?.handle(state)
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
          self?.finish(.failure(URLError(.timedOut)))
        }
      }
    } onCancel: {
      queue.async { [weak self] in
        self?.finish(.failure(CancellationError()))
      }
    }
  }

  private func handle(_ state: NWConnection.State) {
    switch state {
    case .ready where !didSendRequest:
      didSendRequest = true
      connection.send(content: requestData, completion: .contentProcessed { [weak self] error in
        if let error {
          self?.finish(.failure(error))
        } else {
          self?.receive()
        }
      })
    case .failed(let error):
      finish(.failure(error))
    case .cancelled where continuation != nil:
      finish(.failure(URLError(.cancelled)))
    default:
      break
    }
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let error {
        finish(.failure(error))
        return
      }
      if let data { wireData.append(data) }
      guard wireData.count <= maximumWireByteCount else {
        finish(.failure(KnowledgeWebDownloadError.byteLimitExceeded(maximumBodyByteCount)))
        return
      }
      do {
        if let response = try KnowledgeHTTP1ResponseParser.response(
          from: wireData,
          maximumBodyByteCount: maximumBodyByteCount,
          connectionIsComplete: isComplete
        ) {
          finish(.success(response))
        } else if isComplete {
          finish(.failure(KnowledgeWebDownloadError.invalidResponse))
        } else {
          receive()
        }
      } catch {
        finish(.failure(error))
      }
    }
  }

  private func finish(_ result: Result<KnowledgePinnedHTTPResponse, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    connection.stateUpdateHandler = nil
    connection.cancel()
    continuation.resume(with: result)
  }
}

enum KnowledgePinnedHTTPSClient {
  static func fetch(
    request: URLRequest,
    addresses: [KnowledgeResolvedAddress],
    maximumByteCount: Int
  ) async throws -> KnowledgePinnedHTTPResponse {
    guard let url = request.url,
          (request.httpMethod?.uppercased() ?? "GET") == "GET",
          request.httpBody == nil,
          request.httpBodyStream == nil else {
      throw KnowledgeWebDownloadError.invalidURL
    }
    let requestData = try encodedRequest(request, url: url)
    var lastError: Error = KnowledgeWebDownloadError.addressResolutionFailed(
      url.host ?? url.absoluteString
    )
    for address in addresses {
      try Task.checkCancellation()
      do {
        return try await KnowledgePinnedHTTPSOperation(
          url: url,
          address: address,
          requestData: requestData,
          maximumBodyByteCount: maximumByteCount,
          timeout: request.timeoutInterval
        ).execute()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  private static func encodedRequest(_ request: URLRequest, url: URL) throws -> Data {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let host = components.host else {
      throw KnowledgeWebDownloadError.invalidURL
    }
    var target = components.percentEncodedPath
    if target.isEmpty { target = "/" }
    if let query = components.percentEncodedQuery { target += "?\(query)" }
    guard !target.contains("\r"), !target.contains("\n") else {
      throw KnowledgeWebDownloadError.invalidURL
    }

    let renderedHost = host.contains(":") ? "[\(host)]" : host
    let hostHeader: String
    if let port = components.port, port != 443 {
      hostHeader = "\(renderedHost):\(port)"
    } else {
      hostHeader = renderedHost
    }
    var lines = [
      "GET \(target) HTTP/1.1",
      "Host: \(hostHeader)",
      "Connection: close",
      "Accept-Encoding: identity",
    ]
    for name in ["Accept", "Accept-Language", "User-Agent"] {
      guard let value = request.value(forHTTPHeaderField: name) else { continue }
      guard !value.contains("\r"), !value.contains("\n") else {
        throw KnowledgeWebDownloadError.invalidURL
      }
      lines.append("\(name): \(value)")
    }
    lines.append("")
    lines.append("")
    return Data(lines.joined(separator: "\r\n").utf8)
  }
}

struct KnowledgeWebDownloadClient: Sendable {
  typealias Transport = @Sendable (
    URLRequest,
    [KnowledgeResolvedAddress],
    Int
  ) async throws -> KnowledgePinnedHTTPResponse

  static let allowedMIMETypes: Set<String> = [
    "text/html",
    "application/xhtml+xml",
    "text/plain",
  ]

  private let resolver: KnowledgeWebDownloadPolicy.Resolver
  private let transport: Transport

  private static let defaultTransport: Transport = { request, addresses, limit in
    try await KnowledgePinnedHTTPSClient.fetch(
      request: request,
      addresses: addresses,
      maximumByteCount: limit
    )
  }

  init(
    resolver: @escaping KnowledgeWebDownloadPolicy.Resolver = KnowledgeWebDownloadPolicy.defaultResolver,
    transport: @escaping Transport = KnowledgeWebDownloadClient.defaultTransport
  ) {
    self.resolver = resolver
    self.transport = transport
  }

  func download(
    request originalRequest: URLRequest,
    maximumByteCount: Int
  ) async throws -> KnowledgeWebDownloadResponse {
    guard let originalURL = originalRequest.url else {
      throw KnowledgeWebDownloadError.invalidURL
    }
    var request = originalRequest
    var currentURL = originalURL
    let maximumRedirectCount = 5
    for redirectCount in 0...maximumRedirectCount {
      try Task.checkCancellation()
      let endpoint = try KnowledgeWebDownloadPolicy.validatedEndpoint(
        currentURL,
        resolver: resolver
      )
      request.url = endpoint.url
      let received = try await transport(
        request,
        endpoint.addresses,
        maximumByteCount
      )

      if [301, 302, 303, 307, 308].contains(received.statusCode) {
        guard redirectCount < maximumRedirectCount,
              let location = received.header("location"),
              let destination = URL(string: location, relativeTo: endpoint.url)?.absoluteURL else {
          throw KnowledgeWebDownloadError.redirectBlocked(
            received.header("location") ?? "未知地址"
          )
        }
        currentURL = destination
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        continue
      }
      guard (200..<300).contains(received.statusCode) else {
        throw KnowledgeWebDownloadError.httpStatus(received.statusCode)
      }
      if let encoding = received.header("content-encoding")?.lowercased(),
         !encoding.isEmpty,
         encoding != "identity" {
        throw KnowledgeWebDownloadError.unsupportedContentEncoding(encoding)
      }
      guard let httpResponse = HTTPURLResponse(
        url: endpoint.url,
        statusCode: received.statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: received.headerFields
      ) else {
        throw KnowledgeWebDownloadError.invalidResponse
      }
      let mimeType = httpResponse.mimeType?.lowercased() ?? ""
      guard Self.allowedMIMETypes.contains(mimeType) else {
        throw KnowledgeWebDownloadError.unsupportedContentType(
          mimeType.nilIfEmpty ?? "未知"
        )
      }
      return KnowledgeWebDownloadResponse(
        data: received.data,
        response: httpResponse
      )
    }
    throw KnowledgeWebDownloadError.redirectBlocked(currentURL.absoluteString)
  }
}
