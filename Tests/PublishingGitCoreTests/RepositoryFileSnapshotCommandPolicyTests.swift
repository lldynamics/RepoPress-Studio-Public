import Testing

@testable import PublishingGitCore

struct RepositoryFileSnapshotCommandPolicyTests {
  @Test(arguments: snapshotCommandCases)
  fileprivate func plansExactProviderArguments(for scenario: SnapshotCommandCase) {
    let result = plan(
      provider: scenario.provider,
      upstreamName: scenario.upstreamName,
      repositoryPath: scenario.repositoryPath
    )

    #expect(result?.repositoryPath == scenario.repositoryPath)
    #expect(result?.contentArguments == scenario.contentArguments)
    #expect(result?.versionArguments == scenario.versionArguments)
  }

  @Test
  func normalizesTrimmedRepeatedSlashesDotsAndRenameTarget() {
    let result = plan(
      provider: .github,
      upstreamName: "origin/main",
      repositoryPath: " old/path.md ->  ./content//posts/./hello.md  "
    )

    #expect(result?.repositoryPath == "content/posts/hello.md")
    #expect(result?.contentArguments.last == "refs/remotes/origin/main:content/posts/hello.md")
  }

  @Test
  func exactAndStructuredInputsPreserveArrowInsideLiteralDestination() throws {
    let policy = RepositoryFileSnapshotCommandPolicy()
    let destination = "content/posts/new -> literal 标题.md"
    let exactInput = RepositoryFileSnapshotCommandInput(
      provider: .github,
      upstreamName: "origin/main",
      exactRepositoryPath: destination
    )
    let structuredInput = RepositoryFileSnapshotCommandInput(
      provider: .github,
      upstreamName: "origin/main",
      changedPath: .sourceAndDestination(
        source: "content/posts/old -> literal 标题.md",
        destination: destination
      )
    )

    for input in [exactInput, structuredInput] {
      let result = try #require(policy.plan(for: input))
      #expect(result.repositoryPath == destination)
      #expect(result.contentArguments.last == "refs/remotes/origin/main:\(destination)")
    }

    let legacyInput = RepositoryFileSnapshotCommandInput(
      provider: .github,
      upstreamName: "origin/main",
      repositoryPath: "content/posts/old.md -> \(destination)"
    )
    #expect(exactInput != legacyInput)
    #expect(policy.plan(for: legacyInput)?.repositoryPath == destination)
  }

  @Test
  func preservesUnicodeSpacesQuotesGlobsColonsAndNormalizationForm() {
    let nfc = "café/标题 \"draft\" *?[]: final.md"
    let nfd = "cafe\u{301}/标题 \"draft\" *?[]: final.md"

    #expect(
      plan(provider: .github, upstreamName: "origin/main", repositoryPath: nfc)?.repositoryPath
        == nfc)
    #expect(
      plan(provider: .github, upstreamName: "origin/main", repositoryPath: nfd)?.repositoryPath
        == nfd)
    #expect(Array(nfc.unicodeScalars) != Array(nfd.unicodeScalars))

    let gitLabGlob = "content/posts/*?[]: draft.md"
    #expect(
      plan(provider: .gitlab, upstreamName: "origin/main", repositoryPath: gitLabGlob)?
        .versionArguments.last
        == ":(literal)\(gitLabGlob)"
    )
  }

  @Test
  func preservesPathMiddleColon() {
    #expect(
      plan(provider: .github, upstreamName: "origin/main", repositoryPath: "docs/v1:notes.md")?
        .repositoryPath
        == "docs/v1:notes.md"
    )
    #expect(
      plan(provider: .github, upstreamName: "origin/main", repositoryPath: "a:b.md")?.repositoryPath
        == "a:b.md"
    )
  }

  @Test(arguments: invalidRepositoryPaths)
  fileprivate func rejectsInvalidRepositoryPath(_ path: String) {
    #expect(
      plan(provider: .github, upstreamName: "origin/main", repositoryPath: path) == nil,
      "Rejected path: \(path.debugDescription)"
    )
  }

  @Test(arguments: invalidRemoteTrackingRefs)
  fileprivate func rejectsInvalidRemoteTrackingRef(_ ref: String) {
    #expect(
      plan(provider: .github, upstreamName: ref, repositoryPath: "content/file.md") == nil,
      "Rejected ref: \(ref.debugDescription)"
    )
  }

  @Test
  func acceptsUnicodeRemoteTrackingRefs() {
    let result = plan(
      provider: .github,
      upstreamName: "远端/发布分支",
      repositoryPath: "内容/文章.md"
    )

    #expect(
      result?.contentArguments == [
        "show",
        "--end-of-options",
        "refs/remotes/远端/发布分支:内容/文章.md",
      ]
    )
  }

  @Test
  func planHasValueSemantics() {
    let input = RepositoryFileSnapshotCommandInput(
      provider: .gitlab,
      upstreamName: "origin/main",
      repositoryPath: "content/file.md"
    )
    let sameInput = RepositoryFileSnapshotCommandInput(
      provider: .gitlab,
      upstreamName: "origin/main",
      repositoryPath: "content/file.md"
    )

    #expect(input == sameInput)
    #expect(input.hashValue == sameInput.hashValue)

    let policy = RepositoryFileSnapshotCommandPolicy()
    let first = policy.plan(for: input)
    let second = policy.plan(for: sameInput)
    #expect(first == second)
    #expect(first?.hashValue == second?.hashValue)
  }
}

private struct SnapshotCommandCase: Sendable {
  let provider: RepositoryProvider
  let upstreamName: String
  let repositoryPath: String
  let contentArguments: [String]
  let versionArguments: [String]
}

private let snapshotCommandCases: [SnapshotCommandCase] = [
  SnapshotCommandCase(
    provider: .github,
    upstreamName: "origin/main",
    repositoryPath: "content/post.md",
    contentArguments: ["show", "--end-of-options", "refs/remotes/origin/main:content/post.md"],
    versionArguments: [
      "rev-parse", "--verify", "--end-of-options", "refs/remotes/origin/main:content/post.md",
    ]
  ),
  SnapshotCommandCase(
    provider: .gitlab,
    upstreamName: "refs/remotes/upstream/release/2026",
    repositoryPath: "content/post.md",
    contentArguments: [
      "show",
      "--end-of-options",
      "refs/remotes/upstream/release/2026:content/post.md",
    ],
    versionArguments: [
      "log",
      "-n",
      "1",
      "--format=%H",
      "--end-of-options",
      "refs/remotes/upstream/release/2026",
      "--",
      ":(literal)content/post.md",
    ]
  ),
]

private let invalidRepositoryPaths = [
  "",
  "   ",
  "/absolute/file.md",
  "\\absolute\\file.md",
  "content://remote/file.md",
  "content/../file.md",
  "content/./../file.md",
  "\u{0000}content/file.md",
  "\u{0009}content/file.md",
  "\u{000A}content/file.md",
  "content/file.md\u{000D}",
  "content/\u{0001}file.md",
  "content/file.md\u{007F}",
  "file:/content/file.md",
  "C:/content/file.md",
  ":/content/file.md",
  ":notes.md",
  "file:/tmp/notes.md",
  "http://example.test/notes.md",
  "C:/notes.md",
  "./",
]

private let invalidRemoteTrackingRefs = [
  "",
  " ",
  "-origin/main",
  "origin/",
  "origin//main",
  "origin",
  "origin/..",
  "origin/feature..name",
  "origin/feature@{1}",
  "origin/feature~1",
  "origin/feature^1",
  "origin/feature:name",
  "origin/feature?name",
  "origin/feature*name",
  "origin/feature[name",
  "origin/feature\\name",
  "@",
  "origin/.hidden",
  "origin/feature.",
  "origin/feature.lock",
  "refs/heads/main",
  "refs/tags/v1",
  "refs/remotes/origin",
  "refs/remotes/origin/",
  "refs/remotes//main",
  "refs/remotes/origin/.hidden",
  "refs/remotes/origin/feature.lock",
  "refs/remotes/origin/feature\u{0009}name",
]

private func plan(
  provider: RepositoryProvider,
  upstreamName: String,
  repositoryPath: String
) -> RepositoryFileSnapshotCommandPlan? {
  RepositoryFileSnapshotCommandPolicy().plan(
    for: RepositoryFileSnapshotCommandInput(
      provider: provider,
      upstreamName: upstreamName,
      repositoryPath: repositoryPath
    )
  )
}
