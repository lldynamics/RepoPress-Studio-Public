import Foundation
import XCTest

@testable import PublishingGitCore

final class GitRepositoryOutputParserTests: XCTestCase {
  private let parser = GitRepositoryOutputParser()

  func testParsesCurrentNoncurrentAndMissingBranchFields() {
    let current = parser.parseBranchListLine("  main | * | origin/main  ")
    XCTAssertEqual(current, RepositoryBranch(
      name: "main",
      isCurrent: true,
      upstreamName: "origin/main"
    ))

    let noncurrent = parser.parseBranchListLine("feature/read-me| | ")
    XCTAssertEqual(noncurrent, RepositoryBranch(name: "feature/read-me"))

    let missingFields = parser.parseBranchListLine(" release ")
    XCTAssertEqual(missingFields, RepositoryBranch(name: "release"))

    XCTAssertNil(parser.parseBranchListLine(" | * | origin/main"))
    XCTAssertNil(parser.parseBranchListLine("   "))
  }

  func testParsesCommitRowsShortSHAsAndBothISODateForms() {
    let fullSHA = "1234567890abcdef1234567890abcdef12345678"
    let fractional = parser.parseRecentCommitLine(
      "\(fullSHA)\tAlice\t2024-01-02T03:04:05.123Z\tFirst commit",
      fallbackDate: .distantPast
    )
    XCTAssertEqual(fractional?.sha, fullSHA)
    XCTAssertEqual(fractional?.shortSHA, "12345678")
    XCTAssertEqual(fractional?.author, "Alice")
    XCTAssertEqual(fractional?.message, "First commit")
    XCTAssertEqual(
      fractional?.date.timeIntervalSince1970 ?? .nan,
      1_704_164_645.123,
      accuracy: 0.001
    )

    let eightCharacterSHA = parser.parseRecentCommitLine(
      "deadbeef\tBob\t2024-01-02T03:04:05Z\tEight character SHA",
      fallbackDate: .distantPast
    )
    XCTAssertEqual(eightCharacterSHA?.shortSHA, "deadbeef")
    XCTAssertEqual(
      eightCharacterSHA?.date.timeIntervalSince1970 ?? .nan,
      1_704_164_645,
      accuracy: 0.001
    )
  }

  func testParsesLegacyGitDateOffsetsWithoutUsingFallback() {
    let dates: [(String, TimeInterval)] = [
      ("2024-01-02 03:04:05 +0800", 1_704_135_845),
      ("2024-01-02 03:04:05 +0000", 1_704_164_645),
      ("2024-01-02 03:04:05 -0730", 1_704_191_645),
      ("2024-01-02 03:04:05 +0545", 1_704_143_945),
    ]

    for (text, expectedEpoch) in dates {
      let date = parser.parseGitDate(text, fallbackDate: .distantPast)
      XCTAssertEqual(date.timeIntervalSince1970, expectedEpoch, accuracy: 0.001, "Failed to parse \(text)")
    }
  }

  func testParsesStrictISODateOffsetsAndWhitespace() {
    let dates: [(String, TimeInterval)] = [
      (" 2024-01-02T03:04:05+08:00 ", 1_704_135_845),
      ("2024-01-02T03:04:05-07:30", 1_704_191_645),
      ("2024-01-02T03:04:05+05:45", 1_704_143_945),
      ("2024-01-02T03:04:05Z", 1_704_164_645),
    ]

    for (text, expectedEpoch) in dates {
      let date = parser.parseGitDate(text, fallbackDate: .distantPast)
      XCTAssertEqual(date.timeIntervalSince1970, expectedEpoch, accuracy: 0.001, "Failed to parse \(text)")
    }
  }

  func testParsesCompleteLegacyCommitRowWithCorrectEpoch() {
    let commit = parser.parseRecentCommitLine(
      "1234567890abcdef1234567890abcdef12345678\tAlice\t 2024-01-02 03:04:05 +0800 \tFirst commit",
      fallbackDate: .distantPast
    )

    XCTAssertEqual(commit?.date.timeIntervalSince1970 ?? .nan, 1_704_135_845, accuracy: 0.001)
  }

  func testUsesExplicitFallbackForInvalidDatesAndRejectsMalformedRows() {
    let fallback = Date(timeIntervalSince1970: 42)
    let invalidDate = parser.parseRecentCommitLine(
      "abcdef0123456789\tAlice\tnot-a-date\tMessage",
      fallbackDate: fallback
    )
    XCTAssertEqual(invalidDate?.date, fallback)

    let emptyDate = parser.parseGitDate("", fallbackDate: fallback)
    XCTAssertEqual(emptyDate, fallback)
    XCTAssertEqual(parser.parseGitDate("not-a-date", fallbackDate: fallback), fallback)

    for invalidDate in [
      "2024-01-02 03:04:05 +2500",
      "2024-01-02 03:04:05 +0860",
      "2024-01-02T03:04:05+25:00",
      "2024-01-02T03:04:05-07:60",
      "2024-02-30T03:04:05Z",
    ] {
      XCTAssertEqual(parser.parseGitDate(invalidDate, fallbackDate: fallback), fallback, invalidDate)
    }

    XCTAssertNil(parser.parseRecentCommitLine("too-few-fields", fallbackDate: fallback))
    XCTAssertNil(parser.parseRecentCommitLine("\tAlice\t2024-01-02T03:04:05Z\tMessage", fallbackDate: fallback))
    XCTAssertNil(parser.parseRecentCommitLine("sha\t\t2024-01-02T03:04:05Z\tMessage", fallbackDate: fallback))
    XCTAssertNil(parser.parseRecentCommitLine("sha\tAlice\t2024-01-02T03:04:05Z\t", fallbackDate: fallback))
  }

  func testParsesDetachedNoCommitAndSynchronizationStatusBranches() {
    XCTAssertEqual(
      parser.parseBranchStatusLine("## HEAD (no branch)"),
      RepositoryBranchStatus(branchName: nil, upstreamName: nil, isDetached: true)
    )
    XCTAssertEqual(
      parser.parseBranchStatusLine("HEAD detached at abcdef0"),
      RepositoryBranchStatus(branchName: nil, upstreamName: nil, isDetached: true)
    )
    XCTAssertEqual(
      parser.parseBranchStatusLine("## No commits yet on main"),
      RepositoryBranchStatus(branchName: "main", upstreamName: nil)
    )
    XCTAssertEqual(
      parser.parseBranchStatusLine("## feature/read-me"),
      RepositoryBranchStatus(branchName: "feature/read-me", upstreamName: nil)
    )
    XCTAssertEqual(
      parser.parseBranchStatusLine("## main...origin/main"),
      RepositoryBranchStatus(branchName: "main", upstreamName: "origin/main")
    )
    XCTAssertEqual(
      parser.parseBranchStatusLine("## main...origin/main [ahead 2]"),
      RepositoryBranchStatus(
        branchName: "main",
        upstreamName: "origin/main",
        aheadCount: 2
      )
    )
    XCTAssertEqual(
      parser.parseBranchStatusLine("## main...origin/main [behind 3]"),
      RepositoryBranchStatus(
        branchName: "main",
        upstreamName: "origin/main",
        behindCount: 3
      )
    )
    XCTAssertEqual(
      parser.parseBranchStatusLine("## main...origin/main [ahead 2, behind 3]"),
      RepositoryBranchStatus(
        branchName: "main",
        upstreamName: "origin/main",
        aheadCount: 2,
        behindCount: 3
      )
    )
  }

  func testMalformedStatusLinesAndSyncCountsResolveSafely() {
    XCTAssertNil(parser.parseBranchStatusLine(""))
    XCTAssertNil(parser.parseBranchStatusLine("## ...origin/main"))
    XCTAssertEqual(
      parser.parseBranchStatusLine("## main...origin/main [ahead x, behind -2]"),
      RepositoryBranchStatus(branchName: "main", upstreamName: "origin/main")
    )
    XCTAssertEqual(parser.parseSyncCount(label: "ahead", in: "[behind 3]"), 0)
    XCTAssertEqual(parser.parseSyncCount(label: "ahead", in: "[ahead 12]"), 12)
    XCTAssertEqual(parser.parseSyncCount(label: "ahead.", in: "[ahead. 12]"), 12)
  }
}
