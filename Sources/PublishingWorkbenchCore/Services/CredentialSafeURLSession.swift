import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
    guard containsCredential || containsSensitiveBody else {
      return proposedRequest
    }
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
  static func make() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    return URLSession(
      configuration: configuration,
      delegate: CredentialSafeURLSessionDelegate(),
      delegateQueue: nil
    )
  }
}
