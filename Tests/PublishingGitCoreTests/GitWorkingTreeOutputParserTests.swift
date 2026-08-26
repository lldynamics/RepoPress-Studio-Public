import XCTest

@testable import PublishingGitCore

final class GitWorkingTreeOutputParserTests: XCTestCase {
  private let parser = GitRepositoryOutputParser()

  func testClassifiesAllKindsAndPreservesCombinationPriority() {
    let cases: [(String, RepositoryChangeKind)] = [
      ("??", .untracked),
      ("A ", .added),
      ("AM", .added),
      ("MA", .added),
      (" M", .modified),
      ("RM", .modified),
      ("MD", .modified),
      (" D", .deleted),
      ("RD", .deleted),
      ("R ", .renamed),
      ("C ", .other),
      ("!!", .other),
      ("XY", .other),
    ]

    for (status, expectedKind) in cases {
      XCTAssertEqual(parser.changeKind(for: status), expectedKind, status)
    }
  }

  func testParsesTextNameStatusForEveryStatusAndRenameCopyDirections() {
    let output = "M\tmodified.md\nA\tadded.md\nD\tdeleted.md\nR100\told.md\tnew.md\nC075\tsource.md\tdestination.md\n"

    XCTAssertEqual(
      parser.parseNameStatus(output),
      [
        RepositoryChangedFile(status: "M", path: "modified.md", kind: .modified),
        RepositoryChangedFile(status: "A", path: "added.md", kind: .added),
        RepositoryChangedFile(status: "D", path: "deleted.md", kind: .deleted),
        RepositoryChangedFile(status: "R100", path: "old.md -> new.md", kind: .renamed),
        RepositoryChangedFile(status: "C075", path: "source.md -> destination.md", kind: .other),
      ]
    )
  }

  func testParsesNULNameStatusForEveryStatusAndPreservesLiteralPaths() {
    let output = [
      "M", " modified file.md ",
      "A", "添加 文件.md",
      "D", "quoted \"file\".md",
      "R100", "old\nname.md", "new\nname.md",
      "C075", "copy source.md", "copy destination.md",
    ].joined(separator: "\0") + "\0"

    XCTAssertEqual(
      parser.parseNameStatus(output),
      [
        RepositoryChangedFile(status: "M", path: " modified file.md ", kind: .modified),
        RepositoryChangedFile(status: "A", path: "添加 文件.md", kind: .added),
        RepositoryChangedFile(status: "D", path: "quoted \"file\".md", kind: .deleted),
        RepositoryChangedFile(status: "R100", path: "old\nname.md -> new\nname.md", kind: .renamed),
        RepositoryChangedFile(status: "C075", path: "copy source.md -> copy destination.md", kind: .other),
      ]
    )
  }

  func testParsesPorcelainBranchAndNormalRecordsWithLiteralPaths() {
    let output = [
      "## feature/read-me...origin/feature/read-me [ahead 2, behind 1]",
      " M  modified file.md",
      "A  添加 文件.md",
      "?? quoted \"file\".md",
      "R  new\nname.md", "old\nname.md",
      "C  destination.md", "source.md",
    ].joined(separator: "\0") + "\0"

    let result = parser.parsePorcelainV1Status(output)

    XCTAssertEqual(
      result.branchStatus,
      RepositoryBranchStatus(
        branchName: "feature/read-me",
        upstreamName: "origin/feature/read-me",
        aheadCount: 2,
        behindCount: 1
      )
    )
    XCTAssertEqual(
      result.changedFiles,
      [
        RepositoryChangedFile(status: " M", path: " modified file.md", kind: .modified),
        RepositoryChangedFile(status: "A ", path: "添加 文件.md", kind: .added),
        RepositoryChangedFile(status: "??", path: "quoted \"file\".md", kind: .untracked),
        RepositoryChangedFile(status: "R ", path: "old\nname.md -> new\nname.md", kind: .renamed),
        RepositoryChangedFile(status: "C ", path: "source.md -> destination.md", kind: .other),
      ]
    )
    XCTAssertTrue(result.changedFiles.allSatisfy { $0.lineDiff == nil })
  }

  func testEmptyAndBranchOnlyInputsProduceSafeEmptyResults() {
    XCTAssertEqual(parser.parsePorcelainV1Status(""), GitWorkingTreeParseResult())
    XCTAssertEqual(
      parser.parsePorcelainV1Status("## main\0"),
      GitWorkingTreeParseResult(
        branchStatus: RepositoryBranchStatus(branchName: "main", upstreamName: nil)
      )
    )
    XCTAssertEqual(parser.parseNameStatus(""), [])
  }

  func testMalformedPorcelainRecordsAreSkippedWithoutDiscardingPreviousRecords() {
    let output = [
      " M valid-before.md",
      "short",
      " Mnot-a-space.md",
      " M ",
      "R  destination-without-source.md", "",
      "C  destination-with-empty-source.md", "",
      "A  valid-after.md",
    ].joined(separator: "\0") + "\0"

    XCTAssertEqual(
      parser.parsePorcelainV1Status(output).changedFiles,
      [
        RepositoryChangedFile(status: " M", path: "valid-before.md", kind: .modified),
        RepositoryChangedFile(status: "A ", path: "valid-after.md", kind: .added),
      ]
    )
  }

  func testMalformedNameStatusRecordsDoNotCreatePartialRenames() {
    let nulOutput = [
      "M", "valid.md",
      "R100", "source-without-destination.md", "",
      "C075", "", "",
      "A", "",
      "A", "valid-after.md",
      "D",
    ].joined(separator: "\0") + "\0"

    XCTAssertEqual(
      parser.parseNameStatus(nulOutput),
      [
        RepositoryChangedFile(status: "M", path: "valid.md", kind: .modified),
        RepositoryChangedFile(status: "A", path: "valid-after.md", kind: .added),
      ]
    )

    XCTAssertEqual(
      parser.parseNameStatus("R100\tsource-only.md\nC075\t\tdestination.md\nM\tvalid-after.md\n"),
      [RepositoryChangedFile(status: "M", path: "valid-after.md", kind: .modified)]
    )
  }

  func testConsecutiveNULFieldsDoNotReinterpretEmptyFieldsAsPaths() {
    let output = "M\0first.md\0\0A\0second.md\0"

    XCTAssertEqual(
      parser.parseNameStatus(output),
      [
        RepositoryChangedFile(status: "M", path: "first.md", kind: .modified),
        RepositoryChangedFile(status: "A", path: "second.md", kind: .added),
      ]
    )
  }

  func testStructuredRenameAndCopyPathsDoNotSplitArrowInsideEitherEndpoint() {
    let textFiles = parser.parseNameStatus(
      "R100\told -> source \u{4E2D}.md\tnew -> destination \u{4E2D}.md\n"
        + "C075\tcopy -> source.md\tcopy -> destination.md\n"
    )
    XCTAssertEqual(textFiles.map(\.sourcePath), ["old -> source 中.md", "copy -> source.md"])
    XCTAssertEqual(textFiles.map(\.destinationPath), ["new -> destination 中.md", "copy -> destination.md"])

    let nulFiles = parser.parseNameStatus([
      "R100", "旧 -> source\n 文件.md", "新 -> destination\n 文件.md",
      "C075", "copy -> 源.md", "copy -> 目标.md",
    ].joined(separator: "\0") + "\0")
    XCTAssertEqual(nulFiles.map(\.sourcePath), ["旧 -> source\n 文件.md", "copy -> 源.md"])
    XCTAssertEqual(nulFiles.map(\.destinationPath), ["新 -> destination\n 文件.md", "copy -> 目标.md"])

    let porcelain = parser.parsePorcelainV1Status([
      "R  新 -> destination.md", "旧 -> source.md",
      "C  copy -> destination.md", "copy -> source.md",
    ].joined(separator: "\0") + "\0")
    XCTAssertEqual(porcelain.changedFiles.map(\.sourcePath), ["旧 -> source.md", "copy -> source.md"])
    XCTAssertEqual(porcelain.changedFiles.map(\.destinationPath), ["新 -> destination.md", "copy -> destination.md"])
  }
}
