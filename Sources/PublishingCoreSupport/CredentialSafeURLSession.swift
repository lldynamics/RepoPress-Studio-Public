import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

package final class CredentialSafeURLSessionDelegate: NSObject, URLSessionTaskDelegate {
  private static let credentialHeaders = ["Authorization", "PRIVATE-TOKEN", "X-API-Key"]

  package static func redirectedRequest(
    originalRequest: URLRequest?,
    responseURL: URL?,
    proposedRequest: URLRequest
  ) -> URLRequest? {
    let containsCredential = credentialHeaders.contains { header in
      originalRequest?.value(forHTTPHeaderField: header)?.isEmpty == false
    }
    let method = originalRequest?.httpMethod?.uppercased() ?? "GET"
    let containsSensitiveBody =
      method != "GET" && method != "HEAD"
      && (originalRequest?.httpBody != nil || originalRequest?.httpBodyStream != nil)
    guard containsCredential || containsSensitiveBody else { return proposedRequest }
    guard let sourceURL = responseURL ?? originalRequest?.url,
      let destinationURL = proposedRequest.url
    else {
      return nil
    }
    let isAllowed =
      containsCredential
      ? CredentialedEndpointPolicy.isAllowedCredentialRedirect(from: sourceURL, to: destinationURL)
      : CredentialedEndpointPolicy.isAllowedSensitiveBodyRedirect(
        from: sourceURL, to: destinationURL)
    guard isAllowed else { return nil }
    return proposedRequest
  }

  package func urlSession(
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

package struct CredentialSafeProxyConfiguration: Equatable, Sendable {
  package let scheme: String
  package let host: String
  package let port: Int

  package var isSOCKS: Bool {
    scheme == "socks" || scheme == "socks4" || scheme == "socks5"
  }
}

package enum CredentialSafeProxyError: Error, Equatable, LocalizedError, Sendable {
  case invalidURL
  case unsupportedScheme
  case missingHost
  case credentialsNotAllowed
  case invalidPort
  case invalidPath

  package var errorDescription: String? {
    switch self {
    case .invalidURL, .missingHost, .invalidPort, .invalidPath:
      return "AI 代理地址无效。"
    case .unsupportedScheme:
      return "AI 代理协议不受支持。"
    case .credentialsNotAllowed:
      return "AI 代理地址不能包含用户名或密码。"
    }
  }
}

package enum CredentialSafeURLSession {
  package static func make(
    timeoutIntervalForRequest: TimeInterval = 60,
    timeoutIntervalForResource: TimeInterval = 7 * 24 * 60 * 60,
    proxyURL: String? = nil
  ) -> URLSession {
    let proxyConfiguration =
      proxyURL
      .flatMap { value -> CredentialSafeProxyConfiguration? in
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? validatedProxyConfiguration(trimmed)
      }
    return makeSession(
      timeoutIntervalForRequest: timeoutIntervalForRequest,
      timeoutIntervalForResource: timeoutIntervalForResource,
      proxyConfiguration: proxyConfiguration
    )
  }

  /// Builds a session only after validating the optional proxy. Chat requests
  /// use this strict entry point so malformed proxy input cannot silently fall
  /// back to a direct connection. The historical `make` entry point remains
  /// permissive for unrelated callers that do not yet surface configuration
  /// errors.
  package static func makeValidated(
    timeoutIntervalForRequest: TimeInterval = 60,
    timeoutIntervalForResource: TimeInterval = 7 * 24 * 60 * 60,
    proxyURL: String? = nil
  ) throws -> URLSession {
    let proxyConfiguration: CredentialSafeProxyConfiguration?
    if let proxyURL {
      let trimmed = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
      proxyConfiguration = trimmed.isEmpty ? nil : try validatedProxyConfiguration(trimmed)
    } else {
      proxyConfiguration = nil
    }
    return makeSession(
      timeoutIntervalForRequest: timeoutIntervalForRequest,
      timeoutIntervalForResource: timeoutIntervalForResource,
      proxyConfiguration: proxyConfiguration
    )
  }

  package static func validatedProxyConfiguration(
    _ proxyURL: String
  ) throws -> CredentialSafeProxyConfiguration {
    let trimmed = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let components = URLComponents(string: trimmed),
      let schemeValue = components.scheme?.lowercased()
    else {
      throw CredentialSafeProxyError.invalidURL
    }
    guard ["http", "https", "socks", "socks4", "socks5"].contains(schemeValue) else {
      throw CredentialSafeProxyError.unsupportedScheme
    }
    guard let hostValue = components.host?.nilIfEmpty else {
      throw CredentialSafeProxyError.missingHost
    }
    guard components.user == nil, components.password == nil else {
      throw CredentialSafeProxyError.credentialsNotAllowed
    }
    guard components.query == nil, components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else {
      throw CredentialSafeProxyError.invalidPath
    }

    let host =
      hostValue
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !host.isEmpty,
      !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
    else {
      throw CredentialSafeProxyError.missingHost
    }

    let explicitPort = try explicitPort(in: trimmed)
    let defaultPort =
      schemeValue == "http"
      ? 80
      : (schemeValue == "https" ? 443 : 1080)
    let port = explicitPort ?? components.port ?? defaultPort
    guard (1...65_535).contains(port)
    else {
      throw CredentialSafeProxyError.invalidPort
    }
    return CredentialSafeProxyConfiguration(
      scheme: schemeValue,
      host: host,
      port: port
    )
  }

  private static func explicitPort(
    in value: String
  ) throws -> Int? {
    guard let schemeRange = value.range(of: "://") else {
      throw CredentialSafeProxyError.invalidURL
    }
    let authorityStart = schemeRange.upperBound
    let remainder = value[authorityStart...]
    let authorityEnd =
      remainder.firstIndex(where: { "/?#".contains($0) })
      ?? remainder.endIndex
    let authority = remainder[..<authorityEnd]
    guard !authority.contains("@") else {
      throw CredentialSafeProxyError.credentialsNotAllowed
    }

    let portText: Substring?
    if authority.first == "[" {
      guard let closingBracket = authority.firstIndex(of: "]") else {
        throw CredentialSafeProxyError.invalidURL
      }
      let suffix = authority[authority.index(after: closingBracket)...]
      if suffix.isEmpty {
        portText = nil
      } else {
        guard suffix.first == ":" else {
          throw CredentialSafeProxyError.invalidPort
        }
        portText = suffix.dropFirst()
      }
    } else {
      let colonCount = authority.reduce(into: 0) { count, character in
        if character == ":" { count += 1 }
      }
      if colonCount == 0 {
        portText = nil
      } else {
        guard colonCount == 1, let colon = authority.lastIndex(of: ":") else {
          throw CredentialSafeProxyError.invalidURL
        }
        portText = authority[authority.index(after: colon)...]
      }
    }

    guard let portText else { return nil }
    guard !portText.isEmpty, let port = Int(portText) else {
      throw CredentialSafeProxyError.invalidPort
    }
    guard (1...65_535).contains(port) else {
      throw CredentialSafeProxyError.invalidPort
    }
    return port
  }

  private static func makeSession(
    timeoutIntervalForRequest: TimeInterval,
    timeoutIntervalForResource: TimeInterval,
    proxyConfiguration: CredentialSafeProxyConfiguration?
  ) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.timeoutIntervalForRequest = timeoutIntervalForRequest
    configuration.timeoutIntervalForResource = timeoutIntervalForResource

    if let proxyConfiguration {
      if proxyConfiguration.isSOCKS {
        let version: String =
          proxyConfiguration.scheme == "socks4"
          ? (kCFStreamSocketSOCKSVersion4 as String)
          : (kCFStreamSocketSOCKSVersion5 as String)
        configuration.connectionProxyDictionary = [
          kCFStreamPropertySOCKSProxyHost as String: proxyConfiguration.host,
          kCFStreamPropertySOCKSProxyPort as String: proxyConfiguration.port,
          kCFStreamPropertySOCKSVersion as String: version,
        ]
      } else {
        configuration.connectionProxyDictionary = [
          kCFNetworkProxiesHTTPEnable as String: 1,
          kCFNetworkProxiesHTTPProxy as String: proxyConfiguration.host,
          kCFNetworkProxiesHTTPPort as String: proxyConfiguration.port,
          kCFNetworkProxiesHTTPSEnable as String: 1,
          kCFNetworkProxiesHTTPSProxy as String: proxyConfiguration.host,
          kCFNetworkProxiesHTTPSPort as String: proxyConfiguration.port,
        ]
      }
    }

    return URLSession(
      configuration: configuration,
      delegate: CredentialSafeURLSessionDelegate(),
      delegateQueue: nil
    )
  }
}
