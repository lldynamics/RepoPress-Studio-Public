import CryptoKit
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

class RemoteRepositoryPublishServiceTestCase: XCTestCase {
  func githubProfileForDeletion() -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    return profile
  }

  func gitLabProfileForDeletion() -> SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.com"
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    return profile
  }

  func deletionPackage(
    path: String,
    expectedRemoteSHA: String? = nil,
    expectedContentSHA256: String? = nil,
    expectedGitBlobSHA: String? = nil
  ) -> PublishPackage {
    PublishPackage(
      draftID: UUID(),
      title: "Delete article",
      markdownPath: path,
      files: [
        PublishPackageFile(
          kind: .markdown,
          operation: .delete,
          repositoryPath: path,
          expectedRemoteSHA: expectedRemoteSHA,
          expectedContentSHA256: expectedContentSHA256,
          expectedGitBlobSHA: expectedGitBlobSHA
        )
      ],
      commitMessage: "Delete article",
      reviewBranchName: "cleanup/article",
      reviewTitle: "Delete article",
      reviewChecklist: []
    )
  }

  func duplicateNormalizedPathPackage() -> PublishPackage {
    let path = "content/posts/duplicate.md"
    return PublishPackage(
      draftID: UUID(),
      title: "Duplicate path",
      markdownPath: path,
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: path,
          content: "first"
        ),
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: "/./\(path)",
          content: "second"
        ),
      ],
      commitMessage: "Duplicate path",
      reviewBranchName: "publish/duplicate-path",
      reviewTitle: "Duplicate path",
      reviewChecklist: []
    )
  }

  func fixedDate() -> Date {
    Date(timeIntervalSince1970: 1_787_961_600)
  }

  func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    let body = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  func percentEncodedPath(_ url: URL?) -> String? {
    guard let url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
  }
}

struct ThrowingRemoteRequestBody: Encodable {
  struct EncodingFailure: Error {}

  func encode(to encoder: Encoder) throws {
    throw EncodingFailure()
  }
}

actor SequencedRemoteRepositoryTransport: RemoteRepositoryHTTPTransport {
  private var responses: [RemoteRepositoryTransportResponse]
  private var requests: [URLRequest] = []

  init(responses: [RemoteRepositoryTransportResponse]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard !responses.isEmpty else {
      XCTFail("Unexpected remote repository request: \(request.url?.absoluteString ?? "")")
      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
      )
    }

    let response = responses.removeFirst()
    if response.delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: response.delayNanoseconds)
    }
    return (
      response.data,
      HTTPURLResponse(
        url: request.url!, statusCode: response.statusCode, httpVersion: nil,
        headerFields: response.headers)!
    )
  }

  func capturedRequests() -> [URLRequest] {
    requests
  }
}

struct RemoteRepositoryTransportResponse {
  var statusCode: Int
  var data: Data
  var headers: [String: String]
  var delayNanoseconds: UInt64 = 0
}

func response(
  statusCode: Int = 200,
  json: String,
  headers: [String: String] = [:],
  delayNanoseconds: UInt64 = 0
) -> RemoteRepositoryTransportResponse {
  RemoteRepositoryTransportResponse(
    statusCode: statusCode, data: Data(json.utf8), headers: headers,
    delayNanoseconds: delayNanoseconds
  )
}
