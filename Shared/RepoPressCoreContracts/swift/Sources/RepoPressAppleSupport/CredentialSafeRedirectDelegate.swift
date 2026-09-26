import Foundation
import RepoPressCore

/// Task-level adapter for credentialed data and streaming requests, including injected sessions.
public final class CredentialSafeRedirectDelegate: NSObject, URLSessionTaskDelegate {
  public static func redirectedRequest(
    originalRequest: URLRequest?, responseURL: URL?, proposedRequest: URLRequest
  ) -> URLRequest? {
    CredentialSafeRedirectPolicy.redirectedRequest(
      originalRequest: originalRequest, responseURL: responseURL, proposedRequest: proposedRequest
    )
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(Self.redirectedRequest(
      originalRequest: task.originalRequest, responseURL: response.url, proposedRequest: request
    ))
  }
}
