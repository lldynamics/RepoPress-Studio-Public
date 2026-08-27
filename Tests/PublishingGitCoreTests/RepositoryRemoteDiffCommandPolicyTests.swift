import Testing

@testable import PublishingGitCore

struct RepositoryRemoteDiffCommandPolicyTests {
  @Test(arguments: refNormalizationCases)
  fileprivate func shortRemotesAndFullRefsProduceIdenticalPlans(for scenario: RefNormalizationCase)
  {
    let result = RepositoryRemoteDiffCommandPolicy().plan(
      for: RepositoryRemoteDiffCommandInput(upstreamName: scenario.upstreamName)
    )

    #expect(result?.fullRef == "refs/remotes/origin/main")
    #expect(
      result?.changedFilesArguments
        == expectedChangedFilesArguments(for: "refs/remotes/origin/main"))
  }

  @Test
  func plansExactChangedListAndFileDiffArguments() throws {
    let plan = try #require(
      RepositoryRemoteDiffCommandPolicy().plan(
        for: RepositoryRemoteDiffCommandInput(upstreamName: "origin/release/2026")
      )
    )

    #expect(plan.fullRef == "refs/remotes/origin/release/2026")
    #expect(
      plan.changedFilesArguments
        == expectedChangedFilesArguments(
          for: "refs/remotes/origin/release/2026"
        )
    )
    #expect(
      plan.fileDiffArguments(for: "content/posts/article.md") == [
        "diff",
        "-M",
        "-C",
        "--end-of-options",
        "HEAD...refs/remotes/origin/release/2026",
        "--",
        ":(literal)content/posts/article.md",
      ]
    )
  }

  @Test(arguments: invalidRemoteRefs)
  fileprivate func rejectsInvalidRemoteRef(_ scenario: InvalidRefCase) {
    #expect(
      RepositoryRemoteDiffCommandPolicy().plan(
        for: RepositoryRemoteDiffCommandInput(upstreamName: scenario.ref)
      ) == nil,
      "Rejected ref: \(scenario.name)"
    )
  }

  @Test
  func preservesUnicodeRemoteRef() {
    let result = RepositoryRemoteDiffCommandPolicy().plan(
      for: RepositoryRemoteDiffCommandInput(upstreamName: "远端/发布分支")
    )

    #expect(result?.fullRef == "refs/remotes/远端/发布分支")
  }

  @Test(arguments: literalPathCases)
  fileprivate func usesLiteralArgumentWithoutNormalization(for scenario: LiteralPathCase) throws {
    let plan = try #require(
      RepositoryRemoteDiffCommandPolicy().plan(
        for: RepositoryRemoteDiffCommandInput(upstreamName: "origin/main")
      )
    )

    #expect(
      plan.fileDiffArguments(for: scenario.path)?.last == ":(literal)\(scenario.path)",
      "Literal path: \(scenario.name)"
    )
  }

  @Test
  func rejectsEmptyAndNULContainingPaths() throws {
    let plan = try #require(
      RepositoryRemoteDiffCommandPolicy().plan(
        for: RepositoryRemoteDiffCommandInput(upstreamName: "origin/main")
      )
    )

    #expect(plan.fileDiffArguments(for: "") == nil)
    #expect(plan.fileDiffArguments(for: "content/has\0nul.md") == nil)
  }

  @Test
  func pairFileDiffUsesExactSourceThenDestinationLiteralArguments() throws {
    let plan = try #require(
      RepositoryRemoteDiffCommandPolicy().plan(
        for: RepositoryRemoteDiffCommandInput(upstreamName: "origin/main")
      )
    )
    let source = "content/old -> source \u{00E9}.md"
    let destination = "content/new -> destination \u{00E9}.md"
    let file = RepositoryChangedFile(
      status: "R100",
      sourcePath: source,
      destinationPath: destination,
      kind: .renamed
    )

    #expect(
      plan.fileDiffArguments(for: file) == [
        "diff",
        "-M",
        "-C",
        "--end-of-options",
        "HEAD...refs/remotes/origin/main",
        "--",
        ":(literal)" + source,
        ":(literal)" + destination,
      ]
    )
  }

  @Test(arguments: invalidChangedPathPairs)
  fileprivate func pairFileDiffRejectsInvalidPaths(_ scenario: InvalidChangedPathPair) throws {
    let plan = try #require(
      RepositoryRemoteDiffCommandPolicy().plan(
        for: RepositoryRemoteDiffCommandInput(upstreamName: "origin/main")
      )
    )

    #expect(
      plan.fileDiffArguments(for: scenario.path) == nil,
      "Rejected pair: \(scenario.name)"
    )
  }

  @Test
  func inputAndPlanHaveValueSemantics() throws {
    let input = RepositoryRemoteDiffCommandInput(upstreamName: "origin/main")
    let sameInput = RepositoryRemoteDiffCommandInput(upstreamName: "origin/main")
    #expect(input == sameInput)
    #expect(input.hashValue == sameInput.hashValue)

    let first = try #require(RepositoryRemoteDiffCommandPolicy().plan(for: input))
    let second = try #require(RepositoryRemoteDiffCommandPolicy().plan(for: sameInput))
    #expect(first == second)
    #expect(first.hashValue == second.hashValue)
  }
}

private struct RefNormalizationCase: Sendable, CustomStringConvertible {
  let name: String
  let upstreamName: String

  var description: String { name }
}

private let refNormalizationCases = [
  RefNormalizationCase(name: "short ref", upstreamName: "origin/main"),
  RefNormalizationCase(name: "remotes ref", upstreamName: "remotes/origin/main"),
  RefNormalizationCase(name: "complete ref", upstreamName: "refs/remotes/origin/main"),
]

private struct InvalidRefCase: Sendable, CustomStringConvertible {
  let name: String
  let ref: String

  var description: String { name }
}

private let invalidRemoteRefs = [
  InvalidRefCase(name: "empty", ref: ""),
  InvalidRefCase(name: "space", ref: " "),
  InvalidRefCase(name: "leading dash", ref: "-origin/main"),
  InvalidRefCase(name: "missing slash", ref: "origin"),
  InvalidRefCase(name: "trailing slash", ref: "origin/"),
  InvalidRefCase(name: "repeated slash", ref: "origin//main"),
  InvalidRefCase(name: "double dot", ref: "origin/feature..name"),
  InvalidRefCase(name: "reflog syntax", ref: "origin/feature@{1}"),
  InvalidRefCase(name: "tilde syntax", ref: "origin/feature~1"),
  InvalidRefCase(name: "caret syntax", ref: "origin/feature^1"),
  InvalidRefCase(name: "colon syntax", ref: "origin/feature:name"),
  InvalidRefCase(name: "question mark", ref: "origin/feature?name"),
  InvalidRefCase(name: "glob star", ref: "origin/feature*name"),
  InvalidRefCase(name: "glob bracket", ref: "origin/feature[name"),
  InvalidRefCase(name: "backslash", ref: "origin/feature\\name"),
  InvalidRefCase(name: "at sign", ref: "@"),
  InvalidRefCase(name: "hidden component", ref: "origin/.hidden"),
  InvalidRefCase(name: "trailing dot", ref: "origin/feature."),
  InvalidRefCase(name: "lock suffix", ref: "origin/feature.lock"),
  InvalidRefCase(name: "heads ref", ref: "refs/heads/main"),
  InvalidRefCase(name: "tags ref", ref: "refs/tags/v1"),
  InvalidRefCase(name: "remote ref missing branch", ref: "refs/remotes/origin"),
  InvalidRefCase(name: "remote ref trailing slash", ref: "refs/remotes/origin/"),
  InvalidRefCase(name: "remote ref repeated slash", ref: "refs/remotes//main"),
  InvalidRefCase(name: "remotes prefix missing origin", ref: "remotes/origin"),
  InvalidRefCase(name: "tab component", ref: "origin/feature\u{0009}name"),
]

private struct LiteralPathCase: Sendable, CustomStringConvertible {
  let name: String
  let path: String

  var description: String { name }
}

private let literalPathCases = [
  LiteralPathCase(name: "unicode spaces quotes globs colon", path: "内容/空 格/引号\" *?[]: 文件.md"),
  LiteralPathCase(name: "embedded newline", path: "内容/换\n行.md"),
  LiteralPathCase(name: "backslash absolute-looking", path: "\\absolute-looking\\file.md"),
  LiteralPathCase(name: "leading dash", path: "-leading.md"),
  LiteralPathCase(name: "leading colon", path: ":magic-looking.md"),
  LiteralPathCase(name: "dot segments remain literal", path: "./dot/../literal.md"),
]

private struct InvalidChangedPathPair: Sendable, CustomStringConvertible {
  let name: String
  let path: RepositoryChangedPath

  var description: String { name }
}

private let invalidChangedPathPairs = [
  InvalidChangedPathPair(
    name: "empty source",
    path: .sourceAndDestination(source: "", destination: "content/new.md")
  ),
  InvalidChangedPathPair(
    name: "NUL destination",
    path: .sourceAndDestination(source: "content/old.md", destination: "content/new\0.md")
  ),
]

private func expectedChangedFilesArguments(for fullRef: String) -> [String] {
  [
    "diff",
    "-M",
    "-C",
    "--name-status",
    "-z",
    "--end-of-options",
    "HEAD...\(fullRef)",
    "--",
  ]
}
