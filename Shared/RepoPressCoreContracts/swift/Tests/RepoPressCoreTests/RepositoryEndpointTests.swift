import Foundation
import RepoPressCore
import XCTest

final class RepositoryEndpointTests: XCTestCase {
  func testEnterpriseBasePathAndEncodedRequestPathArePreserved() throws {
    let endpoint = try RepositoryEndpoint.validated(
      baseURL: "https://github.example.test/api/v3"
    )

    let url = try endpoint.url(
      path: "/repos/owner/repo/contents/docs%2Findex.md",
      queryItems: [URLQueryItem(name: "ref", value: "main")]
    )

    XCTAssertEqual(
      url.absoluteString,
      "https://github.example.test/api/v3/repos/owner/repo/contents/docs%2Findex.md?ref=main"
    )
  }

  func testEndpointRejectsCredentialsAndInsecureTransport() {
    XCTAssertThrowsError(try RepositoryEndpoint.validated(baseURL: "http://example.test/api"))
    XCTAssertThrowsError(try RepositoryEndpoint.validated(baseURL: "https://user@example.test/api"))
  }

  func testAuthenticationAppliesProviderSpecificHeaders() throws {
    var githubRequest = URLRequest(url: URL(string: "https://api.github.com/user")!)
    RepositoryAuthentication.githubBearer("secret").apply(to: &githubRequest)
    XCTAssertEqual(githubRequest.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    XCTAssertEqual(githubRequest.value(forHTTPHeaderField: "User-Agent"), "RepoPress")

    var gitLabRequest = URLRequest(url: URL(string: "https://gitlab.example.test/api/v4/user")!)
    RepositoryAuthentication.gitLabPrivateToken("secret").apply(to: &gitLabRequest)
    XCTAssertEqual(gitLabRequest.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "secret")
    XCTAssertNil(gitLabRequest.value(forHTTPHeaderField: "Authorization"))
  }
}
