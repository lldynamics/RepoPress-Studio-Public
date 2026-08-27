import Foundation
import Testing

@testable import PublishingGitCore

struct RepositoryReviewURLBuilderTests {
  @Test(arguments: reviewURLCases)
  fileprivate func buildsProviderSpecificReviewURL(for scenario: ReviewURLCase) throws {
    let url = try #require(RepositoryReviewURLBuilder().buildURL(for: scenario.input))

    #expect(url.host == scenario.expectedHost)
    #expect(url.path == scenario.expectedPath)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = components.queryItems ?? []
    let query = Dictionary(
      uniqueKeysWithValues: queryItems.compactMap { item in
        item.value.map { (item.name, $0) }
      })
    #expect(query == scenario.expectedQuery)
  }

  @Test(arguments: incompleteReviewInputs)
  fileprivate func missingOwnerOrRepositoryReturnsNil(for scenario: IncompleteReviewInput) {
    #expect(RepositoryReviewURLBuilder().buildURL(for: scenario.input) == nil)
  }

  @Test
  func titleAndBodyQueryValuesAreEncodedAndRoundTrip() throws {
    let reviewInput = input(
      title: "Review & approve = now?",
      body: "第一行\n第二行 & status=ready?"
    )
    let url = try #require(RepositoryReviewURLBuilder().buildURL(for: reviewInput))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = try #require(components.queryItems)

    #expect(queryItems.first(where: { $0.name == "title" })?.value == reviewInput.title)
    #expect(queryItems.first(where: { $0.name == "body" })?.value == reviewInput.body)
    #expect(url.absoluteString.contains("%26"))
    #expect(url.absoluteString.contains("%3D"))
    #expect(url.absoluteString.contains("%0A"))
  }
}

private struct ReviewURLCase: Sendable, CustomStringConvertible {
  let name: String
  let input: RepositoryReviewURLInput
  let expectedHost: String
  let expectedPath: String
  let expectedQuery: [String: String]

  var description: String { name }
}

private let reviewURLCases = [
  ReviewURLCase(
    name: "GitHub api host becomes web host",
    input: input(
      provider: .github,
      baseURL: "https://api.github.com",
      owner: "owner",
      repositoryName: "site"
    ),
    expectedHost: "github.com",
    expectedPath: "/owner/site/compare/main...publish/article",
    expectedQuery: [
      "quick_pull": "1",
      "title": "Publish article",
      "body": "Please review",
    ]
  ),
  ReviewURLCase(
    name: "GitHub Enterprise custom host",
    input: input(
      provider: .github,
      baseURL: "https://github.example.test/api/v3",
      owner: "team",
      repositoryName: "site"
    ),
    expectedHost: "github.example.test",
    expectedPath: "/team/site/compare/main...publish/article",
    expectedQuery: [
      "quick_pull": "1",
      "title": "Publish article",
      "body": "Please review",
    ]
  ),
  ReviewURLCase(
    name: "GitLab subgroup merge request",
    input: input(
      provider: .gitlab,
      baseURL: "https://gitlab.example.test",
      owner: "group/subgroup",
      repositoryName: "site"
    ),
    expectedHost: "gitlab.example.test",
    expectedPath: "/group/subgroup/site/-/merge_requests/new",
    expectedQuery: [
      "merge_request[source_branch]": "publish/article",
      "merge_request[target_branch]": "main",
      "merge_request[title]": "Publish article",
      "merge_request[description]": "Please review",
    ]
  ),
]

private struct IncompleteReviewInput: Sendable, CustomStringConvertible {
  let name: String
  let input: RepositoryReviewURLInput

  var description: String { name }
}

private let incompleteReviewInputs = [
  IncompleteReviewInput(
    name: "missing owner",
    input: input(owner: "", repositoryName: "site")
  ),
  IncompleteReviewInput(
    name: "blank repository",
    input: input(owner: "owner", repositoryName: "  \n")
  ),
]

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
