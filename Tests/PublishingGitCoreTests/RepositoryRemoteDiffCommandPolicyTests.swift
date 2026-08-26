import XCTest

@testable import PublishingGitCore

final class RepositoryRemoteDiffCommandPolicyTests: XCTestCase {
  func testShortRemotesAndFullRefsProduceIdenticalPlans() {
    let names = [
      "origin/main",
      "remotes/origin/main",
      "refs/remotes/origin/main",
    ]
    let plans = names.compactMap { name in
      RepositoryRemoteDiffCommandPolicy().plan(
        for: RepositoryRemoteDiffCommandInput(upstreamName: name)
      )
    }

    XCTAssertEqual(plans.count, names.count)
    XCTAssertEqual(Set(plans.map(\.fullRef)), ["refs/remotes/origin/main"])
    XCTAssertEqual(Set(plans.map(\.changedFilesArguments)).count, 1)
  }

  func testPlansExactChangedListAndFileDiffArguments() throws {
    let plan = try XCTUnwrap(
      RepositoryRemoteDiffCommandPolicy().plan(
        for: RepositoryRemoteDiffCommandInput(upstreamName: "origin/release/2026")
      )
    )

    XCTAssertEqual(plan.fullRef, "refs/remotes/origin/release/2026")
    XCTAssertEqual(
      plan.changedFilesArguments,
      [
        "diff",
        "-M",
        "-C",
        "--name-status",
        "-z",
        "--end-of-options",
        "HEAD...refs/remotes/origin/release/2026",
        "--",
      ]
    )
    XCTAssertEqual(
      plan.fileDiffArguments(for: "content/posts/article.md"),
      [
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

  func testRejectsInvalidRefsAndPreservesUnicodeRefs() {
    let invalidRefs = [
      "",
      " ",
      "-origin/main",
      "origin",
      "origin/",
      "origin//main",
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
      "remotes/origin",
      "origin/feature\u{0009}name",
    ]

    for ref in invalidRefs {
      XCTAssertNil(
        RepositoryRemoteDiffCommandPolicy().plan(
          for: RepositoryRemoteDiffCommandInput(upstreamName: ref)
        ),
        ref
      )
    }

    let unicode = RepositoryRemoteDiffCommandPolicy().plan(
      for: RepositoryRemoteDiffCommandInput(upstreamName: "远端/发布分支")
    )
    XCTAssertEqual(unicode?.fullRef, "refs/remotes/远端/发布分支")
  }

  func testFilePathUsesLiteralArgumentWithoutNormalization() throws {
    let plan = try XCTUnwrap(
      RepositoryRemoteDiffCommandPolicy().plan(
        for: RepositoryRemoteDiffCommandInput(upstreamName: "origin/main")
      )
    )
    let paths = [
      "内容/空 格/引号\" *?[]: 文件.md",
      "内容/换\n行.md",
      "\\absolute-looking\\file.md",
      "-leading.md",
      ":magic-looking.md",
      "./dot/../literal.md",
    ]

    for path in paths {
      XCTAssertEqual(
        plan.fileDiffArguments(for: path)?.last,
        ":(literal)\(path)",
        path
      )
    }

    XCTAssertNil(plan.fileDiffArguments(for: ""))
    XCTAssertNil(plan.fileDiffArguments(for: "content/has\0nul.md"))
  }

  func testPairFileDiffUsesExactSourceThenDestinationLiteralArguments() throws {
    let plan = try XCTUnwrap(
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

    XCTAssertEqual(
      plan.fileDiffArguments(for: file),
      [
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

  func testPairFileDiffRejectsAnEmptyOrNULPath() throws {
    let plan = try XCTUnwrap(
      RepositoryRemoteDiffCommandPolicy().plan(
        for: RepositoryRemoteDiffCommandInput(upstreamName: "origin/main")
      )
    )

    XCTAssertNil(
      plan.fileDiffArguments(
        for: .sourceAndDestination(source: "", destination: "content/new.md")
      )
    )
    XCTAssertNil(
      plan.fileDiffArguments(
        for: .sourceAndDestination(source: "content/old.md", destination: "content/new\0.md")
      )
    )
  }

  func testInputAndPlanHaveValueSemantics() throws {
    let input = RepositoryRemoteDiffCommandInput(upstreamName: "origin/main")
    let sameInput = RepositoryRemoteDiffCommandInput(upstreamName: "origin/main")
    XCTAssertEqual(input, sameInput)
    XCTAssertEqual(input.hashValue, sameInput.hashValue)

    let first = try XCTUnwrap(RepositoryRemoteDiffCommandPolicy().plan(for: input))
    let second = try XCTUnwrap(RepositoryRemoteDiffCommandPolicy().plan(for: sameInput))
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.hashValue, second.hashValue)
  }
}
