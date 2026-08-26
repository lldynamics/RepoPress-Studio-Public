import XCTest

@testable import PublishingGitCore

final class RepositoryLocalDiffCommandPolicyTests: XCTestCase {
  private let policy = RepositoryLocalDiffCommandPolicy()

  func testTrackedSingleKindsUseStagedThenUnstagedLiteralCommands() throws {
    let path = "content/posts/文章.md"
    let expected = [
      ["diff", "-M", "-C", "--cached", "--", ":(literal)\(path)"],
      ["diff", "-M", "-C", "--", ":(literal)\(path)"],
    ]

    for kind in [RepositoryChangeKind.modified, .added, .deleted] {
      let file = RepositoryChangedFile(status: "", path: path, kind: kind)
      XCTAssertEqual(policy.plan(for: file)?.argumentsInExecutionOrder, expected, kind.rawValue)
    }
  }

  func testRenameAndCopyKeepSourceThenDestinationForBothCommands() throws {
    let source = "内容/旧 -> 源 \"稿\".md"
    let destination = "内容/新 -> 目标\n稿.md"
    let expected = [
      [
        "diff", "-M", "-C", "--cached", "--",
        ":(literal)\(source)", ":(literal)\(destination)",
      ],
      [
        "diff", "-M", "-C", "--",
        ":(literal)\(source)", ":(literal)\(destination)",
      ],
    ]

    for kind in [RepositoryChangeKind.renamed, .other] {
      let file = RepositoryChangedFile(
        status: kind == .renamed ? "R100" : "C100",
        sourcePath: source,
        destinationPath: destination,
        kind: kind
      )
      XCTAssertEqual(policy.plan(for: file)?.argumentsInExecutionOrder, expected, kind.rawValue)
    }
  }

  func testTrackedPathsPreserveSpecialCharactersWithoutTrimming() throws {
    let paths = [
      "内容/空 格/引号\"/换\n行 *?[]: \\文件.md",
      "-leading.md",
      "/absolute-looking.md",
      "./dot/../literal.md",
    ]

    for path in paths {
      let file = RepositoryChangedFile(status: " M", path: path, kind: .modified)
      let arguments = try XCTUnwrap(policy.plan(for: file)?.argumentsInExecutionOrder)
      XCTAssertEqual(arguments[0].last, ":(literal)\(path)", path)
      XCTAssertEqual(arguments[1].last, ":(literal)\(path)", path)
    }
  }

  func testUntrackedUsesRawFilesystemPathWithoutLiteralMagic() throws {
    let path = "content/posts/*?[]: \"未跟踪\" \\文件\n.md"
    let file = RepositoryChangedFile(status: "??", path: path, kind: .untracked)

    XCTAssertEqual(
      policy.plan(for: file)?.argumentsInExecutionOrder,
      [["diff", "--no-index", "--", "/dev/null", path]]
    )
  }

  func testRejectsEmptyNULAndUntrackedStructuredPairs() {
    XCTAssertNil(
      policy.plan(for: RepositoryChangedFile(status: " M", path: "", kind: .modified))
    )
    XCTAssertNil(
      policy.plan(for: RepositoryChangedFile(status: " M", path: "bad\0path", kind: .modified))
    )
    XCTAssertNil(
      policy.plan(for: RepositoryChangedFile(
        status: "??",
        sourcePath: "old.md",
        destinationPath: "new.md",
        kind: .untracked
      ))
    )
    XCTAssertNil(
      policy.plan(for: RepositoryChangedFile(
        status: "R",
        sourcePath: "old\0.md",
        destinationPath: "new.md",
        kind: .renamed
      ))
    )
  }

  func testRejectsAbsoluteAndDotTraversalUntrackedPathsWithoutTrimming() {
    let invalidPaths = [
      "/tmp/file.md",
      "./file.md",
      "content/./file.md",
      "content/../file.md",
      "content/posts/..",
    ]

    for path in invalidPaths {
      XCTAssertNil(
        policy.plan(for: RepositoryChangedFile(status: "??", path: path, kind: .untracked)),
        path
      )
    }

    let leadingSpace = " content/posts/file.md "
    XCTAssertEqual(
      policy.plan(for: RepositoryChangedFile(status: "??", path: leadingSpace, kind: .untracked))?.argumentsInExecutionOrder,
      [["diff", "--no-index", "--", "/dev/null", leadingSpace]]
    )
  }

  func testLegacyRenameDisplayAndOrdinaryArrowFilenameRemainCompatible() throws {
    let rename = RepositoryChangedFile(
      status: "R100",
      path: "content/old.md -> content/new.md",
      kind: .renamed
    )
    let literalArrowFilename = RepositoryChangedFile(
      status: " M",
      path: "content/posts/name -> literal.md",
      kind: .modified
    )

    XCTAssertEqual(rename.sourcePath, "content/old.md")
    XCTAssertEqual(rename.destinationPath, "content/new.md")
    XCTAssertEqual(
      policy.plan(for: rename)?.argumentsInExecutionOrder[0].suffix(2),
      [":(literal)content/old.md", ":(literal)content/new.md"]
    )
    XCTAssertEqual(
      policy.plan(for: literalArrowFilename)?.argumentsInExecutionOrder[0].last,
      ":(literal)content/posts/name -> literal.md"
    )
  }

  func testLineDiffDoesNotAffectPlanValueSemantics() throws {
    let file = RepositoryChangedFile(status: " M", path: "README.md", kind: .modified)
    var withDiff = file
    withDiff.lineDiff = "-old\n+new"

    let first = try XCTUnwrap(policy.plan(for: file))
    let second = try XCTUnwrap(policy.plan(for: withDiff))
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.hashValue, second.hashValue)
    XCTAssertEqual(first, RepositoryLocalDiffCommandPlan(argumentsInExecutionOrder: first.argumentsInExecutionOrder))
  }
}
