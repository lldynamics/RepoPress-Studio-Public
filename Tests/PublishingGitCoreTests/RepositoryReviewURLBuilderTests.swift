import XCTest
@testable import PublishingGitCore

final class RepositoryReviewURLBuilderTests: XCTestCase {
  func testGitHubAPIHostBecomesWebHost() throws {
    let url = try XCTUnwrap(
      RepositoryReviewURLBuilder().buildURL(
        for: input(
          provider: .github,
          baseURL: "https://api.github.com",
          owner: "owner",
          repositoryName: "site"
        )
      )
    )

    XCTAssertEqual(url.host, "github.com")
    XCTAssertEqual(url.path, "/owner/site/compare/main...publish/article")
  }

  func testGitHubCustomHostIsPreserved() throws {
    let url = try XCTUnwrap(
      RepositoryReviewURLBuilder().buildURL(
        for: input(
          provider: .github,
          baseURL: "https://github.example.test/api/v3",
          owner: "team",
          repositoryName: "site"
        )
      )
    )

    XCTAssertEqual(url.host, "github.example.test")
    XCTAssertEqual(url.path, "/team/site/compare/main...publish/article")
  }

  func testGitLabHostAndMergeRequestQueryAreBuilt() throws {
    let input = input(
      provider: .gitlab,
      baseURL: "https://gitlab.example.test",
      owner: "group/subgroup",
      repositoryName: "site"
    )
    let url = try XCTUnwrap(RepositoryReviewURLBuilder().buildURL(for: input))

    XCTAssertEqual(url.host, "gitlab.example.test")
    XCTAssertEqual(url.path, "/group/subgroup/site/-/merge_requests/new")
    let queryItems = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(
      queryItems.first(where: { $0.name == "merge_request[source_branch]" })?.value,
      "publish/article"
    )
    XCTAssertEqual(
      queryItems.first(where: { $0.name == "merge_request[target_branch]" })?.value,
      "main"
    )
  }

  func testMissingOwnerOrRepositoryReturnsNil() {
    let builder = RepositoryReviewURLBuilder()
    XCTAssertNil(builder.buildURL(for: input(owner: "", repositoryName: "site")))
    XCTAssertNil(builder.buildURL(for: input(owner: "owner", repositoryName: "  \n")))
  }

  func testTitleAndBodyQueryValuesAreEncodedAndRoundTrip() throws {
    let reviewInput = input(
      title: "Review & approve = now?",
      body: "第一行\n第二行 & status=ready?"
    )
    let url = try XCTUnwrap(RepositoryReviewURLBuilder().buildURL(for: reviewInput))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = try XCTUnwrap(components.queryItems)

    XCTAssertEqual(queryItems.first(where: { $0.name == "title" })?.value, reviewInput.title)
    XCTAssertEqual(queryItems.first(where: { $0.name == "body" })?.value, reviewInput.body)
    XCTAssertTrue(url.absoluteString.contains("%26"))
    XCTAssertTrue(url.absoluteString.contains("%3D"))
    XCTAssertTrue(url.absoluteString.contains("%0A"))
  }

  private func input(
    provider: RepositoryProvider = .github,
    baseURL: String = "https://api.github.com",
    owner: String = "owner",
    repositoryName: String = "site",
    title: String = "Publish article",
    body: String = "Please review"
  ) -> RepositoryReviewURLInput {
    RepositoryReviewURLInput(
      provider: provider,
      repositoryBaseURL: baseURL,
      owner: owner,
      repositoryName: repositoryName,
      sourceBranch: "publish/article",
      targetBranch: "main",
      title: title,
      body: body
    )
  }
}
