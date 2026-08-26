import XCTest

@testable import PublishingGitCore

final class RepositoryReleaseHistoryCommandPolicyTests: XCTestCase {
  func testClampsLimitAndAcceptsOnlyCompleteSHA1OrSHA256Cursor() {
    let policy = RepositoryReleaseHistoryCommandPolicy()

    XCTAssertEqual(policy.plan(for: .init(limit: -5)).request.limit, 1)
    XCTAssertEqual(policy.plan(for: .init(limit: 9_999)).request.limit, 200)

    let sha1 = String(repeating: "A", count: 40)
    let sha256 = String(repeating: "b", count: 64)
    XCTAssertEqual(policy.plan(for: .init(limit: 10, cursor: sha1)).request.cursor, sha1.lowercased())
    XCTAssertEqual(policy.plan(for: .init(limit: 10, cursor: sha256)).request.cursor, sha256)
    XCTAssertNil(policy.plan(for: .init(limit: 10, cursor: "deadbeef")).request.cursor)
    XCTAssertNil(policy.plan(for: .init(limit: 10, cursor: "$(touch /tmp/nope)")).request.cursor)
  }

  func testUsesOverfetchAndFixedNotesReference() throws {
    let cursor = String(repeating: "c", count: 40)
    let plan = RepositoryReleaseHistoryCommandPolicy().plan(
      for: .init(limit: 20, cursor: cursor)
    )

    XCTAssertEqual(plan.commitArguments[0], "log")
    XCTAssertEqual(plan.commitArguments[1...2], ["-n", "21"])
    XCTAssertTrue(plan.commitArguments.contains("--skip=1"))
    XCTAssertEqual(plan.commitArguments.suffix(2), ["--end-of-options", cursor])
    XCTAssertEqual(plan.notesArguments, [
      "notes", "--ref", "refs/notes/repopress/releases", "list",
    ])
    XCTAssertFalse(plan.argumentsInExecutionOrder.flatMap { $0 }.contains("$(touch /tmp/nope)"))
    XCTAssertNil(plan.noteShowArguments(for: "main; echo unsafe"))
    XCTAssertEqual(
      try XCTUnwrap(plan.noteShowArguments(for: cursor)),
      ["notes", "--ref", "refs/notes/repopress/releases", "show", cursor]
    )
  }

  func testFirstPageDoesNotSkipHead() {
    let plan = RepositoryReleaseHistoryCommandPolicy().plan(for: .init(limit: 20))

    XCTAssertFalse(plan.commitArguments.contains("--skip=1"))
    XCTAssertEqual(plan.commitArguments.suffix(2), ["--end-of-options", "HEAD"])
  }
}
