import XCTest
@testable import PublishingWorkbenchCore

final class GitCommandRunnerTests: XCTestCase {
  func testContinuouslyDrainsNoisyStandardStreamsWithinOutputLimit() throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

    let result = GitCommandRunner(
      executableURL: scriptURL,
      timeout: 2,
      maximumOutputBytes: 4_096
    ).run(["noisy"], rootURL: FileManager.default.temporaryDirectory)

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertFalse(result.didTimeOut)
    XCTAssertTrue(result.wasOutputTruncated)
    XCTAssertLessThanOrEqual(result.output.utf8.count, 4_200)
    XCTAssertTrue(result.output.contains("[Git output truncated after 4096 bytes]"))
  }

  func testTimeoutDiagnosticQuotesArgumentsAsPOSIXShellValues() throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

    let result = GitCommandRunner(executableURL: scriptURL, timeout: 0.05).run(
      ["sleep", "$(touch /tmp/should-not-run)", "line\nbreak"],
      rootURL: FileManager.default.temporaryDirectory
    )

    XCTAssertEqual(result.terminationStatus, 124)
    XCTAssertTrue(result.didTimeOut)
    XCTAssertTrue(result.output.contains("'$(touch /tmp/should-not-run)'"))
    XCTAssertTrue(result.output.contains("'line\nbreak'"))
  }

  private func makeFakeGitExecutable() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacGitRunnerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let scriptURL = directoryURL.appendingPathComponent("fake-git")
    let script = """
    #!/bin/sh
    shift 2
    if [ "$1" = "sleep" ]; then
      sleep 2
      exit 0
    fi
    count=0
    while [ "$count" -lt 512 ]; do
      printf 'oooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo\n'
      printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n' >&2
      count=$((count + 1))
    done
    """
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
  }
}
