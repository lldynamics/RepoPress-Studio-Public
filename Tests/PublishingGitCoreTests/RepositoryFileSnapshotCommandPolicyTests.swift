import XCTest

@testable import PublishingGitCore

final class RepositoryFileSnapshotCommandPolicyTests: XCTestCase {
  func testPlansExactGitHubArgumentsForShortRef() {
    let result = plan(
      provider: .github,
      upstreamName: "origin/main",
      repositoryPath: "content/post.md"
    )

    XCTAssertEqual(result?.repositoryPath, "content/post.md")
    XCTAssertEqual(
      result?.contentArguments,
      ["show", "--end-of-options", "refs/remotes/origin/main:content/post.md"]
    )
    XCTAssertEqual(
      result?.versionArguments,
      [
        "rev-parse",
        "--verify",
        "--end-of-options",
        "refs/remotes/origin/main:content/post.md",
      ]
    )
  }

  func testPlansExactGitLabArgumentsForCompleteRef() {
    let result = plan(
      provider: .gitlab,
      upstreamName: "refs/remotes/upstream/release/2026",
      repositoryPath: "content/post.md"
    )

    XCTAssertEqual(result?.repositoryPath, "content/post.md")
    XCTAssertEqual(
      result?.contentArguments,
      [
        "show",
        "--end-of-options",
        "refs/remotes/upstream/release/2026:content/post.md",
      ]
    )
    XCTAssertEqual(
      result?.versionArguments,
      [
        "log",
        "-n",
        "1",
        "--format=%H",
        "--end-of-options",
        "refs/remotes/upstream/release/2026",
        "--",
        ":(literal)content/post.md",
      ]
    )
  }

  func testNormalizesTrimmedRepeatedSlashesDotsAndRenameTarget() {
    let result = plan(
      provider: .github,
      upstreamName: "origin/main",
      repositoryPath: " old/path.md ->  ./content//posts/./hello.md  "
    )

    XCTAssertEqual(result?.repositoryPath, "content/posts/hello.md")
    XCTAssertEqual(
      result?.contentArguments.last,
      "refs/remotes/origin/main:content/posts/hello.md"
    )
  }

  func testExactAndStructuredInputsPreserveArrowInsideLiteralDestination() throws {
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
      let result = try XCTUnwrap(policy.plan(for: input))
      XCTAssertEqual(result.repositoryPath, destination)
      XCTAssertEqual(
        result.contentArguments.last,
        "refs/remotes/origin/main:\(destination)"
      )
    }

    let legacyInput = RepositoryFileSnapshotCommandInput(
      provider: .github,
      upstreamName: "origin/main",
      repositoryPath: "content/posts/old.md -> \(destination)"
    )
    XCTAssertNotEqual(exactInput, legacyInput)
    XCTAssertEqual(policy.plan(for: legacyInput)?.repositoryPath, destination)
  }

  func testPreservesUnicodeSpacesQuotesGlobsColonsAndNormalizationForm() {
    let nfc = "café/标题 \"draft\" *?[]: final.md"
    let nfd = "cafe\u{301}/标题 \"draft\" *?[]: final.md"

    XCTAssertEqual(
      plan(provider: .github, upstreamName: "origin/main", repositoryPath: nfc)?.repositoryPath,
      nfc
    )
    XCTAssertEqual(
      plan(provider: .github, upstreamName: "origin/main", repositoryPath: nfd)?.repositoryPath,
      nfd
    )
    XCTAssertNotEqual(
      Array(nfc.unicodeScalars),
      Array(nfd.unicodeScalars)
    )

    let gitLabGlob = "content/posts/*?[]: draft.md"
    XCTAssertEqual(
      plan(
        provider: .gitlab,
        upstreamName: "origin/main",
        repositoryPath: gitLabGlob
      )?.versionArguments.last,
      ":(literal)\(gitLabGlob)"
    )
  }

  func testPreservesPathMiddleColonButRejectsLeadingColonAndSchemes() {
    XCTAssertEqual(
      plan(
        provider: .github,
        upstreamName: "origin/main",
        repositoryPath: "docs/v1:notes.md"
      )?.repositoryPath,
      "docs/v1:notes.md"
    )
    XCTAssertEqual(
      plan(
        provider: .github,
        upstreamName: "origin/main",
        repositoryPath: "a:b.md"
      )?.repositoryPath,
      "a:b.md"
    )

    for path in [":notes.md", "file:/tmp/notes.md", "http://example.test/notes.md", "C:/notes.md"] {
      XCTAssertNil(
        plan(provider: .github, upstreamName: "origin/main", repositoryPath: path),
        path
      )
    }
  }

  func testAcceptsUnicodeRemoteTrackingRefs() {
    let result = plan(
      provider: .github,
      upstreamName: "远端/发布分支",
      repositoryPath: "内容/文章.md"
    )

    XCTAssertEqual(
      result?.contentArguments,
      ["show", "--end-of-options", "refs/remotes/远端/发布分支:内容/文章.md"]
    )
  }

  func testRejectsInvalidRepositoryPaths() {
    let invalidPaths = [
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
      "./",
    ]

    for path in invalidPaths {
      XCTAssertNil(
        plan(provider: .github, upstreamName: "origin/main", repositoryPath: path),
        path
      )
    }
  }

  func testRejectsInvalidRemoteTrackingRefs() {
    let invalidRefs = [
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

    for ref in invalidRefs {
      XCTAssertNil(
        plan(provider: .github, upstreamName: ref, repositoryPath: "content/file.md"),
        ref
      )
    }
  }

  func testPlanHasValueSemantics() {
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

    XCTAssertEqual(input, sameInput)
    XCTAssertEqual(input.hashValue, sameInput.hashValue)

    let policy = RepositoryFileSnapshotCommandPolicy()
    let first = policy.plan(for: input)
    let second = policy.plan(for: sameInput)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first?.hashValue, second?.hashValue)
  }

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
}
