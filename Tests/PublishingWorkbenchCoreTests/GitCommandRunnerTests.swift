import XCTest
@testable import PublishingWorkbenchCore

final class GitCommandRunnerTests: XCTestCase {
  func testContinuouslyDrainsNoisyStandardStreamsWithinOutputLimit() throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

    let result = GitCommandRunner(
      executableURL: scriptURL,
      timeout: 10,
      maximumOutputBytes: 4_096
    ).run(["noisy"], rootURL: FileManager.default.temporaryDirectory)

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertFalse(result.didTimeOut)
    XCTAssertTrue(result.wasOutputTruncated)
    XCTAssertLessThanOrEqual(result.output.utf8.count, 4_200)
    XCTAssertLessThanOrEqual(
      result.standardOutput.utf8.count + result.standardError.utf8.count,
      4_096
    )
    XCTAssertTrue(result.output.contains("[Git output truncated after 4096 bytes]"))
  }

  func testSuccessfulCommandKeepsStandardErrorOutOfMachineReadableOutput() throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

    let result = GitCommandRunner(executableURL: scriptURL).run(
      ["stderr-warning"],
      rootURL: FileManager.default.temporaryDirectory
    )

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.standardOutput, "")
    XCTAssertEqual(result.standardError, "warning: simulated fsmonitor failure")
    XCTAssertTrue(result.output.contains("warning: simulated fsmonitor failure"))
  }

  func testRapidShortLivedCommandsRetainStandardOutput() throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }
    let runner = GitCommandRunner(executableURL: scriptURL)

    for iteration in 0..<100 {
      let result = runner.run(
        ["short-output"],
        rootURL: FileManager.default.temporaryDirectory
      )

      XCTAssertEqual(result.terminationStatus, 0, "iteration \(iteration)")
      XCTAssertEqual(
        result.standardOutput,
        "content/posts/article.md",
        "iteration \(iteration)"
      )
    }
  }

  func testAsyncSuccessfulCommandKeepsStandardErrorOutOfMachineReadableOutput() async throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

    let result = await GitCommandRunner(executableURL: scriptURL).runAsync(
      ["stderr-warning"],
      rootURL: FileManager.default.temporaryDirectory
    )

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.standardOutput, "")
    XCTAssertEqual(result.standardError, "warning: simulated fsmonitor failure")
    XCTAssertTrue(result.output.contains("warning: simulated fsmonitor failure"))
  }

  func testAsyncRapidShortLivedCommandsRetainStandardOutput() async throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }
    let runner = GitCommandRunner(executableURL: scriptURL)

    for iteration in 0..<50 {
      let result = await runner.runAsync(
        ["short-output"],
        rootURL: FileManager.default.temporaryDirectory
      )

      XCTAssertEqual(result.terminationStatus, 0, "iteration \(iteration)")
      XCTAssertEqual(
        result.standardOutput,
        "content/posts/article.md",
        "iteration \(iteration)"
      )
    }
  }

  func testDiagnosticOutputRedactsRemoteURLsAndCredentialValues() throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

    let result = GitCommandRunner(executableURL: scriptURL).run(
      ["redaction"],
      rootURL: FileManager.default.temporaryDirectory
    )

    XCTAssertEqual(result.terminationStatus, 1)
    XCTAssertTrue(result.standardOutput.contains("stdout-token"))
    XCTAssertFalse(result.standardError.contains("stderr-secret"))
    XCTAssertFalse(result.standardError.contains("stderr-token"))
    XCTAssertFalse(result.output.contains("alice"))
    XCTAssertFalse(result.output.contains("url-secret"))
    XCTAssertFalse(result.output.contains("stdout-secret"))
    XCTAssertFalse(result.output.contains("stderr-secret"))
    XCTAssertFalse(result.output.contains("stderr-token"))
    XCTAssertTrue(result.output.contains("https://github.com/owner/site.git"))
    XCTAssertTrue(result.output.contains("[REDACTED]"))
  }

  func testCommandDescriptionRedactsRemoteURLsUsernamesAndTokenFlags() {
    let command = GitCommandRunner.redactedCommandDescription([
      "remote",
      "add",
      "origin",
      "https://alice:url-secret@github.com/owner/site.git?token=url-token",
      "--token",
      "flag-token",
      "--header",
      "Authorization: Bearer header-token",
    ])

    XCTAssertFalse(command.contains("alice"))
    XCTAssertFalse(command.contains("url-secret"))
    XCTAssertFalse(command.contains("url-token"))
    XCTAssertFalse(command.contains("flag-token"))
    XCTAssertFalse(command.contains("header-token"))
    XCTAssertTrue(command.contains("https://github.com/owner/site.git"))
    XCTAssertTrue(command.contains("--token"))
    XCTAssertTrue(command.contains("[REDACTED]"))
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

  func testAsyncRunnerTimesOutWithoutBlockingCaller() async throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

    let result = await GitCommandRunner(executableURL: scriptURL, timeout: 0.05).runAsync(
      ["sleep"],
      rootURL: FileManager.default.temporaryDirectory
    )

    XCTAssertEqual(result.terminationStatus, 124)
    XCTAssertTrue(result.didTimeOut)
  }

  func testAsyncRunnerCancelsChildProcess() async throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

    let runner = GitCommandRunner(executableURL: scriptURL, timeout: 5)
    let task = Task { await runner.runAsync(["sleep"], rootURL: FileManager.default.temporaryDirectory) }
    try await Task.sleep(nanoseconds: 50_000_000)
    task.cancel()
    let result = await task.value

    XCTAssertEqual(result.terminationStatus, 130)
    XCTAssertFalse(result.didTimeOut)
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
    if [ "$1" = "stderr-warning" ]; then
      printf 'warning: simulated fsmonitor failure\n' >&2
      exit 0
    fi
    if [ "$1" = "short-output" ]; then
      printf 'content/posts/article.md\n'
      exit 0
    fi
    if [ "$1" = "redaction" ]; then
      printf 'remote=https://alice:url-secret@github.com/owner/site.git?token=stdout-token\n'
      printf 'Authorization: Bearer stderr-secret token=stderr-token\n' >&2
      exit 1
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
