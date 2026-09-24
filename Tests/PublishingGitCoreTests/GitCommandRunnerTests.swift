import XCTest

@testable import PublishingGitCore

final class GitCommandRunnerTests: XCTestCase {
  func testSyncAndAsyncCommandsDisableReplacementAndGraftHistory() async throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }
    let runner = GitCommandRunner(executableURL: scriptURL)
    let root = scriptURL.deletingLastPathComponent()
    let synchronous = Self.runSynchronously(runner, ["history-environment"], at: root)
    let asynchronous = await runner.runAsync(["history-environment"], rootURL: root)
    XCTAssertEqual(synchronous.terminationStatus, 0)
    XCTAssertEqual(asynchronous.terminationStatus, 0)
    XCTAssertEqual(synchronous.standardOutput, "1|/dev/null")
    XCTAssertEqual(asynchronous.standardOutput, "1|/dev/null")
  }

  func testSyncAndAsyncCommandsRejectGraftsInWorktreeAndCommonMetadata() async throws {
    for commonMetadata in [false, true] {
      let scriptURL = try makeFakeGitExecutable()
      let root = scriptURL.deletingLastPathComponent()
      defer { try? FileManager.default.removeItem(at: root) }
      let gitDirectory = root.appendingPathComponent("metadata", isDirectory: true)
      let commonDirectory = root.appendingPathComponent("shared", isDirectory: true)
      try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: commonDirectory, withIntermediateDirectories: true)
      try "gitdir: metadata\n".write(
        to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
      try "../shared\n".write(
        to: gitDirectory.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
      let info = (commonMetadata ? commonDirectory : gitDirectory).appendingPathComponent("info")
      try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
      try "fixture\n".write(
        to: info.appendingPathComponent("grafts"), atomically: true, encoding: .utf8)
      let runner = GitCommandRunner(executableURL: scriptURL)
      let synchronous = Self.runSynchronously(runner, ["short-output"], at: root)
      let asynchronous = await runner.runAsync(["short-output"], rootURL: root)
      for result in [synchronous, asynchronous] {
        XCTAssertEqual(result.terminationStatus, 126)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertTrue(result.standardError.contains("info/grafts"))
      }
    }
  }

  func testRealGitIgnoresGraftCreatedAfterConfigurationCheck() async throws {
    let scriptURL = try makeFakeGitExecutable()
    let root = scriptURL.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: root) }
    let setupRunner = GitCommandRunner()
    for arguments in [
      ["init", "-b", "main"],
      [
        "-c", "user.name=Tests", "-c", "user.email=tests@example.com", "commit", "--allow-empty",
        "-m", "base",
      ],
      [
        "-c", "user.name=Tests", "-c", "user.email=tests@example.com", "commit", "--allow-empty",
        "-m", "child",
      ],
    ] {
      let result = await setupRunner.runAsync(arguments, rootURL: root)
      XCTAssertEqual(result.terminationStatus, 0, result.output)
    }
    let head = await setupRunner.runAsync(["rev-parse", "HEAD"], rootURL: root)
    XCTAssertEqual(head.terminationStatus, 0)
    let graftData = Data("\(head.standardOutput)\n".utf8)
    let graftsURL = root.appendingPathComponent(".git/info/grafts")
    let runner = GitCommandRunner(
      executableURL: URL(fileURLWithPath: "/usr/bin/git"),
      testingBeforeProcessRun: {
        _ = FileManager.default.createFile(atPath: graftsURL.path, contents: graftData)
      })
    let result = await runner.runAsync(["rev-list", "--count", "HEAD"], rootURL: root)
    XCTAssertTrue(FileManager.default.fileExists(atPath: graftsURL.path))
    XCTAssertEqual(result.terminationStatus, 0, result.output)
    XCTAssertEqual(result.standardOutput, "2")
  }

  private static func runSynchronously(
    _ runner: GitCommandRunner, _ arguments: [String], at root: URL,
    inputLines: [String]? = nil
  ) -> GitCommandResult {
    runner.run(arguments, rootURL: root, inputLines: inputLines)
  }

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

  func testCanPreserveLeadingWhitespaceAndNulDelimitedOutputForMachineParsing() throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

    let result = GitCommandRunner(executableURL: scriptURL).run(
      ["raw-status"],
      rootURL: FileManager.default.temporaryDirectory,
      preserveStandardOutputWhitespace: true
    )

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.standardOutput, " M leading-space.md\0?? untracked.md\0")
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

  func testLargeInputToEarlyExitingChildDoesNotTerminateHost() async throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }
    let runner = GitCommandRunner(executableURL: scriptURL, timeout: 1)
    let input = [String(repeating: "x", count: 1_000_000)]
    let root = scriptURL.deletingLastPathComponent()

    let synchronous = Self.runSynchronously(
      runner, ["exit-before-input"], at: root, inputLines: input)
    let asynchronous = await runner.runAsync(
      ["exit-before-input"], rootURL: root, inputLines: input)

    for result in [synchronous, asynchronous] {
      XCTAssertEqual(result.terminationStatus, 17, result.output)
      XCTAssertFalse(result.didTimeOut)
      XCTAssertTrue(result.output.contains("Git stdin write failed"), result.output)
    }
  }

  func testRealGitCheckIgnoreOutsideRepositorySurvivesLargeInput() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("GitCommandRunnerNonRepository-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = GitCommandRunner(timeout: 2).run(
      ["check-ignore", "--stdin", "-z"],
      rootURL: root,
      inputLines: [String(repeating: "x", count: 1_000_000)],
      inputDelimiter: .nul
    )

    XCTAssertNotEqual(result.terminationStatus, 0)
    XCTAssertFalse(result.didTimeOut, result.output)
  }

  func testLargeInputToNonReadingChildHonorsTimeout() async throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }
    let runner = GitCommandRunner(executableURL: scriptURL, timeout: 0.05)
    let input = [String(repeating: "x", count: 1_000_000)]
    let root = scriptURL.deletingLastPathComponent()

    let synchronousStart = Date()
    let synchronous = Self.runSynchronously(
      runner, ["never-read-input"], at: root, inputLines: input)
    XCTAssertEqual(synchronous.terminationStatus, 124, synchronous.output)
    XCTAssertTrue(synchronous.didTimeOut)
    XCTAssertLessThan(Date().timeIntervalSince(synchronousStart), 1.5)

    let asynchronousStart = Date()
    let asynchronous = await runner.runAsync(
      ["never-read-input"], rootURL: root, inputLines: input)
    XCTAssertEqual(asynchronous.terminationStatus, 124, asynchronous.output)
    XCTAssertTrue(asynchronous.didTimeOut)
    XCTAssertLessThan(Date().timeIntervalSince(asynchronousStart), 1.5)
  }

  func testAsyncTimeoutContinuesAfterChildExitsWhileStdinReaderRemainsOpen() async throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }
    let runner = GitCommandRunner(executableURL: scriptURL, timeout: 0.05)
    let start = Date()

    let result = await runner.runAsync(
      ["exit-with-reader"],
      rootURL: scriptURL.deletingLastPathComponent(),
      inputLines: [String(repeating: "x", count: 1_000_000)]
    )

    XCTAssertEqual(result.terminationStatus, 124, result.output)
    XCTAssertTrue(result.didTimeOut)
    XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
  }

  func testAsyncCancellationReturnsWhileLargeInputWriterIsBlocked() async throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }
    let markerURL = scriptURL.deletingLastPathComponent().appendingPathComponent("reading-started")
    let runner = GitCommandRunner(executableURL: scriptURL, timeout: 5)
    let task = Task {
      await runner.runAsync(
        ["never-read-input", markerURL.path],
        rootURL: scriptURL.deletingLastPathComponent(),
        inputLines: [String(repeating: "x", count: 1_000_000)]
      )
    }

    for _ in 0..<100 where !FileManager.default.fileExists(atPath: markerURL.path) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    let start = Date()
    task.cancel()
    let result = await task.value

    XCTAssertEqual(result.terminationStatus, 130, result.output)
    XCTAssertFalse(result.didTimeOut)
    XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
  }

  func testAsyncCancellationReturnsAfterChildExitsWhileStdinReaderRemainsOpen() async throws {
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }
    let markerURL = scriptURL.deletingLastPathComponent().appendingPathComponent("child-exited")
    let runner = GitCommandRunner(executableURL: scriptURL, timeout: 5)
    let task = Task {
      await runner.runAsync(
        ["exit-with-reader", markerURL.path],
        rootURL: scriptURL.deletingLastPathComponent(),
        inputLines: [String(repeating: "x", count: 1_000_000)]
      )
    }

    for _ in 0..<100 where !FileManager.default.fileExists(atPath: markerURL.path) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    try await Task.sleep(nanoseconds: 100_000_000)
    let start = Date()
    task.cancel()
    let result = await task.value

    XCTAssertEqual(result.terminationStatus, 130, result.output)
    XCTAssertFalse(result.didTimeOut)
    XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
  }

  func testAsyncRunnerCancelsChildProcess() async throws {
    let launchEntered = DispatchSemaphore(value: 0)
    let releaseLaunch = DispatchSemaphore(value: 0)
    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

    let runner = GitCommandRunner(
      executableURL: scriptURL,
      timeout: 5,
      testingBeforeProcessRun: {
        launchEntered.signal()
        releaseLaunch.wait()
      }
    )
    let task = Task {
      await runner.runAsync(
        ["startup-barrier"],
        rootURL: FileManager.default.temporaryDirectory
      )
    }
    await waitForSemaphore(launchEntered)
    task.cancel()
    releaseLaunch.signal()
    let result = await task.value

    XCTAssertEqual(result.terminationStatus, 130)
    XCTAssertFalse(result.didTimeOut)
  }

  func testAsyncRunnerCancelledBeforeStartupDoesNotLaunchChild() async throws {
    let (gateStream, gateContinuation) = AsyncStream<Void>.makeStream()
    let (readyStream, readyContinuation) = AsyncStream<Void>.makeStream()
    let startupMarkerURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("GitCommandRunnerTests-pre-cancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: startupMarkerURL) }

    let scriptURL = try makeFakeGitExecutable()
    defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

    let runner = GitCommandRunner(executableURL: scriptURL, timeout: 5)
    let task = Task {
      readyContinuation.yield(())
      for await _ in gateStream {
        break
      }
      return await runner.runAsync(
        ["pre-cancel", startupMarkerURL.path],
        rootURL: FileManager.default.temporaryDirectory
      )
    }
    for await _ in readyStream {
      break
    }
    task.cancel()
    gateContinuation.yield(())
    gateContinuation.finish()
    let result = await task.value

    XCTAssertEqual(result.terminationStatus, 130)
    XCTAssertFalse(result.didTimeOut)
    XCTAssertFalse(FileManager.default.fileExists(atPath: startupMarkerURL.path))
  }

  private func makeFakeGitExecutable() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PersonalSitePublisherMacGitRunnerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let scriptURL = directoryURL.appendingPathComponent("fake-git")
    let script = """
      #!/bin/sh
      shift 2
      if [ "$1" = "history-environment" ]; then
        printf '%s|%s' "$GIT_NO_REPLACE_OBJECTS" "$GIT_GRAFT_FILE"
        exit 0
      fi
      if [ "$1" = "sleep" ]; then
        sleep 2
        exit 0
      fi
      if [ "$1" = "exit-before-input" ]; then
        exit 17
      fi
      if [ "$1" = "never-read-input" ]; then
        if [ -n "$2" ]; then printf 'started' > "$2"; fi
        while :; do :; done
      fi
      if [ "$1" = "exit-with-reader" ]; then
        sleep 2 <&0 >/dev/null 2>&1 &
        if [ -n "$2" ]; then printf 'exited' > "$2"; fi
        exit 0
      fi
      if [ "$1" = "startup-barrier" ]; then
        trap 'exit 130' TERM INT
        while :; do :; done
      fi
      if [ "$1" = "pre-cancel" ]; then
        printf 'started' > "$2"
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
      if [ "$1" = "raw-status" ]; then
        printf ' M leading-space.md\\0?? untracked.md\\0'
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

private func waitForSemaphore(_ semaphore: DispatchSemaphore) async {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      semaphore.wait()
      continuation.resume()
    }
  }
}
