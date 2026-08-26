import Foundation
import XCTest

@testable import PublishingGitCore

final class RepositoryReleaseHistoryParserTests: XCTestCase {
  private let parser = RepositoryReleaseHistoryParser()
  private let sha1 = String(repeating: "1", count: 40)
  private let sha256 = String(repeating: "2", count: 64)

  func testParsesNULRecordsChineseMultilineCommitAndBothTagKinds() throws {
    let commitOutput = [
      [sha1, "张三", "2026-08-26T08:00:00Z", "发布首页\n补充说明"].joined(separator: "\0"),
      [sha256, "Alice", "2026-08-25T08:00:00Z", "SHA-256 commit"].joined(separator: "\0"),
    ].joined(separator: "\0\0") + "\0\0"
    let annotatedTarget = String(repeating: "3", count: 40)
    let tagOutput = [
      ["v1.0", sha1, "commit", "轻量标签", "", ""].joined(separator: "\0"),
      ["v2.0", String(repeating: "4", count: 40), "tag", "带说明的标签", annotatedTarget, "commit"].joined(separator: "\0"),
    ].joined(separator: "\0\0") + "\0\0"
    let noteJSON = "{\"schema\":1,\"title\":\"中文发布\",\"body\":\"第一行\\n第二行\"}"
    let noteOutput = [sha1, noteJSON].joined(separator: "\0") + "\0\0"

    let snapshot = parser.parse(
      commitOutput: commitOutput,
      tagOutput: tagOutput,
      noteOutput: noteOutput,
      request: .init(limit: 2),
      fallbackDate: .distantPast
    )

    XCTAssertEqual(snapshot.historyAvailability, .available)
    XCTAssertEqual(snapshot.notesAvailability, .available)
    XCTAssertEqual(snapshot.commits.count, 2)
    XCTAssertEqual(snapshot.commits[0].message, "发布首页\n补充说明")
    XCTAssertEqual(snapshot.commits[0].author, "张三")
    XCTAssertEqual(snapshot.commits[1].sha, sha256)
    XCTAssertEqual(snapshot.tags.count, 2)
    XCTAssertFalse(snapshot.tags[0].isAnnotated)
    XCTAssertEqual(snapshot.tags[0].targetSHA, sha1)
    XCTAssertTrue(snapshot.tags[1].isAnnotated)
    XCTAssertEqual(snapshot.tags[1].targetSHA, annotatedTarget)
    XCTAssertEqual(snapshot.notes.first?.metadata["title"], "中文发布")
    XCTAssertEqual(snapshot.notes.first?.schemaVersion, 1)
    XCTAssertFalse(snapshot.partial)
  }

  func testOverfetchProducesCursorAndExplicitPartialSnapshot() {
    let records = (0..<3).map { index in
      [
        String(format: "%040d", index + 1),
        "author",
        "2026-08-26T08:00:00Z",
        "commit \(index)",
      ].joined(separator: "\0")
    }.joined(separator: "\0\0")

    let snapshot = parser.parse(
      commitOutput: records,
      tagOutput: "",
      request: .init(limit: 2)
    )

    XCTAssertEqual(snapshot.commits.count, 2)
    XCTAssertEqual(snapshot.cursor, String(format: "%040d", 2))
    XCTAssertTrue(snapshot.partial)
    XCTAssertEqual(snapshot.historyAvailability, .available)
  }

  func testCorruptAndOversizedNotesOnlyProduceDiagnostics() {
    let valid = [sha1, "{\"schema\":1,\"kind\":\"publish\"}"].joined(separator: "\0")
    let corrupt = [sha256, "{\"schema\":2}"].joined(separator: "\0")
    let oversized = [String(repeating: "5", count: 40), "{\"schema\":1,\"body\":\"" + String(repeating: "x", count: 16 * 1024) + "\"}"].joined(separator: "\0")
    let output = [valid, corrupt, oversized].joined(separator: "\0\0")

    let result = parser.parseNoteOutput(output)

    XCTAssertEqual(result.notes.count, 1)
    XCTAssertEqual(result.notes.first?.metadata["kind"], "publish")
    XCTAssertEqual(result.diagnostics.count, 2)
  }

  func testCommandFailuresRemainRepresentedInAvailabilityAndDiagnostics() {
    let history = GitCommandResult(
      terminationStatus: 128,
      standardOutput: "",
      standardError: "fatal: shallow history"
    )
    let notes = GitCommandResult(
      terminationStatus: 1,
      standardOutput: "",
      standardError: "no notes"
    )
    let snapshot = parser.parse(
      commitResult: history,
      tagResult: GitCommandResult(terminationStatus: 0, output: ""),
      notesResult: notes,
      shallowResult: GitCommandResult(terminationStatus: 0, output: "true")
    )

    XCTAssertEqual(snapshot.historyAvailability, .unknown)
    XCTAssertEqual(snapshot.notesAvailability, .unavailable)
    XCTAssertTrue(snapshot.shallow)
    XCTAssertTrue(snapshot.partial)
    XCTAssertGreaterThanOrEqual(snapshot.diagnostics.count, 2)
  }
}
