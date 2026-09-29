import Foundation
import XCTest

@testable import PublishingPreviewCore
@testable import PublishingWorkbenchCore

#if canImport(Darwin)
  import Darwin
#endif

final class QuartzStaticPreviewRunnerTests: XCTestCase {
  private enum ProcessExitError: Error, CustomStringConvertible {
    case timedOut(String)

    var description: String {
      switch self {
      case .timedOut(let context): "Timed out waiting for \(context)"
      }
    }
  }

  private func waitForExit(_ process: Process, within timeout: Duration, context: String)
    async throws
  {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while process.isRunning {
      guard ContinuousClock.now < deadline else { throw ProcessExitError.timedOut(context) }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private static func pauseForCleanup() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(50)) {
        continuation.resume()
      }
    }
  }

  private static func waitForCleanupExit(_ process: Process, within timeout: Duration) async -> Bool
  {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while process.isRunning, ContinuousClock.now < deadline {
      await Self.pauseForCleanup()
    }
    return !process.isRunning
  }

  private static func cleanupOwnedProcess(_ process: Process) async {
    guard process.isRunning else { return }
    #if canImport(Darwin)
      _ = Darwin.kill(process.processIdentifier, SIGTERM)
    #else
      process.terminate()
    #endif
    if !(await Self.waitForCleanupExit(process, within: .seconds(2))) {
      #if canImport(Darwin)
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
      #else
        process.terminate()
      #endif
      if !(await Self.waitForCleanupExit(process, within: .seconds(2))) {
        XCTFail("Owned Quartz test process remained alive after cleanup")
      }
    }
  }

  #if canImport(Darwin)
    private static func cleanupOwnedDetachedRunner(_ runnerPID: Int32) async {
      guard runnerPID > 0, Darwin.kill(runnerPID, 0) == 0 else { return }
      _ = Darwin.kill(runnerPID, SIGTERM)
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while Darwin.kill(runnerPID, 0) == 0, ContinuousClock.now < deadline {
        await Self.pauseForCleanup()
      }
      if Darwin.kill(runnerPID, 0) == 0 {
        _ = Darwin.kill(runnerPID, SIGKILL)
        let forcedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while Darwin.kill(runnerPID, 0) == 0, ContinuousClock.now < forcedDeadline {
          await Self.pauseForCleanup()
        }
        if Darwin.kill(runnerPID, 0) == 0 {
          XCTFail("Owned detached Quartz runner remained alive after cleanup")
        }
      }
    }

    private static func cleanupOwnedBuildGroup(buildPIDFile: URL, childPIDFile: URL) async {
      guard
        let buildPIDText = try? String(contentsOf: buildPIDFile, encoding: .utf8),
        let buildPID = Int32(buildPIDText.trimmingCharacters(in: .whitespacesAndNewlines)),
        buildPID > 0
      else { return }
      let childPID = (try? String(contentsOf: childPIDFile, encoding: .utf8)).flatMap {
        Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      func groupIsOwned() -> Bool {
        Darwin.getpgid(buildPID) == buildPID
          || (childPID.map { Darwin.getpgid($0) == buildPID } ?? false)
      }
      guard groupIsOwned() else { return }
      _ = Darwin.kill(-buildPID, SIGTERM)
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while groupIsOwned(), ContinuousClock.now < deadline {
        await Self.pauseForCleanup()
      }
      if groupIsOwned() {
        _ = Darwin.kill(-buildPID, SIGKILL)
        let forcedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while groupIsOwned(), ContinuousClock.now < forcedDeadline {
          await Self.pauseForCleanup()
        }
        if groupIsOwned() {
          XCTFail("Owned Quartz build process group remained alive after cleanup")
        }
      }
    }
  #endif

  func testBuildLogLimitStopsNoisyBuilder() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "quartz-log-limit-test-\(UUID().uuidString)", isDirectory: true
    )
    let site = base.appendingPathComponent("site", isDirectory: true)
    let quartz = site.appendingPathComponent("quartz", isDirectory: true)
    try FileManager.default.createDirectory(at: quartz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data("export default {}".utf8).write(
      to: site.appendingPathComponent("quartz.config.ts")
    )
    try Data(
      """
      import sys
      import time
      sys.stdout.write('x' * 100000)
      sys.stdout.flush()
      time.sleep(30)
      """.utf8
    ).write(to: quartz.appendingPathComponent("bootstrap-cli.mjs"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = QuartzStaticPreviewRunner.arguments(
      rootPath: site.path, nodePath: "/usr/bin/python3", port: 43210
    )
    process.environment = ProcessInfo.processInfo.environment.merging([
      "TMPDIR": base.path, "REPOPRESS_QUARTZ_PREVIEW_TOKEN": "log-test-token",
    ]) { _, override in override }
    let output = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = output
    try process.run()
    do {
      try await waitForExit(process, within: .seconds(5), context: "noisy builder log limit")
      let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      XCTAssertTrue(log.contains("exceeded its log limit"))
      XCTAssertLessThan(log.utf8.count, 80_000)
    } catch {
      await Self.cleanupOwnedProcess(process)
      throw error
    }
  }

  func testRunnerExitsWhenLaunchingParentImmediatelyExits() async throws {
    #if canImport(Darwin)
      let base = FileManager.default.temporaryDirectory.appendingPathComponent(
        "quartz-parent-exit-test-\(UUID().uuidString)", isDirectory: true
      )
      let site = base.appendingPathComponent("site", isDirectory: true)
      let quartz = site.appendingPathComponent("quartz", isDirectory: true)
      try FileManager.default.createDirectory(at: quartz, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: base) }
      try Data("export default {}".utf8).write(
        to: site.appendingPathComponent("quartz.config.ts")
      )
      try Data(
        """
        from pathlib import Path
        import sys
        output = Path(sys.argv[sys.argv.index('--output') + 1])
        output.mkdir(parents=True)
        (output / 'index.html').write_text('ready')
        """.utf8
      ).write(to: quartz.appendingPathComponent("bootstrap-cli.mjs"))
      let pidFile = base.appendingPathComponent("runner.pid")
      let wrapper = Process()
      wrapper.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      wrapper.arguments = [
        "-c",
        """
        import os, subprocess, sys
        from pathlib import Path
        child = subprocess.Popen(
            [sys.executable, '-I', '-c', sys.argv[1], sys.argv[2], sys.executable,
             sys.argv[3], str(os.getpid())],
            env=os.environ, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        Path(sys.argv[4]).write_text(str(child.pid))
        """,
        QuartzStaticPreviewRunner.pythonSource,
        site.path,
        "43210",
        pidFile.path,
      ]
      wrapper.environment = ProcessInfo.processInfo.environment.merging([
        "TMPDIR": base.path, "REPOPRESS_QUARTZ_PREVIEW_TOKEN": "parent-test-token",
      ]) { _, override in override }
      try wrapper.run()
      do {
        try await waitForExit(wrapper, within: .seconds(5), context: "launching parent")
      } catch {
        await Self.cleanupOwnedProcess(wrapper)
        if let recordedPID = try? String(contentsOf: pidFile, encoding: .utf8),
          let runnerPID = Int32(recordedPID.trimmingCharacters(in: .whitespacesAndNewlines))
        {
          await Self.cleanupOwnedDetachedRunner(runnerPID)
        }
        throw error
      }
      XCTAssertEqual(wrapper.terminationStatus, 0)
      let runnerPID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
      do {
        var runnerExited = false
        for _ in 0..<100 {
          if Darwin.kill(runnerPID, 0) == -1, errno == ESRCH {
            runnerExited = true
            break
          }
          try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(runnerExited, "Quartz runner survived its launching parent")
        if !runnerExited { await Self.cleanupOwnedDetachedRunner(runnerPID) }
        let retained = try FileManager.default.contentsOfDirectory(atPath: base.path).filter {
          $0.hasPrefix("RepoPress-Quartz-Preview-\(runnerPID)-")
        }
        XCTAssertTrue(retained.isEmpty)
      } catch {
        await Self.cleanupOwnedDetachedRunner(runnerPID)
        throw error
      }
    #else
      throw XCTSkip("Requires Darwin process inspection")
    #endif
  }

  func testTemporaryDirectoryInsideRepositoryFailsBeforeCopy() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "quartz-nested-temp-test-\(UUID().uuidString)", isDirectory: true
    )
    let site = base.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = QuartzStaticPreviewRunner.arguments(
      rootPath: site.path, nodePath: "/usr/bin/python3", port: 43210
    )
    process.environment = ProcessInfo.processInfo.environment.merging([
      "TMPDIR": site.path, "REPOPRESS_QUARTZ_PREVIEW_TOKEN": "nested-test-token",
    ]) { _, override in override }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    do {
      try await waitForExit(
        process, within: .seconds(5), context: "nested temporary directory rejection")
      XCTAssertNotEqual(process.terminationStatus, 0)
      let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      XCTAssertTrue(log.contains("temporary directory is inside the repository"))
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: site.path), [])
    } catch {
      await Self.cleanupOwnedProcess(process)
      throw error
    }
  }

  func testStoppingBuildTerminatesItsChildProcess() async throws {
    let python = URL(fileURLWithPath: "/usr/bin/python3")
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "quartz-child-preview-test-\(UUID().uuidString)", isDirectory: true
    )
    let site = base.appendingPathComponent("site", isDirectory: true)
    let quartz = site.appendingPathComponent("quartz", isDirectory: true)
    try FileManager.default.createDirectory(at: quartz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data("export default {}".utf8).write(
      to: site.appendingPathComponent("quartz.config.ts")
    )
    try Data(
      """
      import os
      from pathlib import Path
      import subprocess
      import time
      Path(os.environ['BUILD_PID_FILE']).write_text(str(os.getpid()))
      child = subprocess.Popen(['/bin/sleep', '30'])
      Path(os.environ['CHILD_PID_FILE']).write_text(str(child.pid))
      time.sleep(30)
      """.utf8
    ).write(to: quartz.appendingPathComponent("bootstrap-cli.mjs"))
    let buildPIDFile = base.appendingPathComponent("build.pid")
    let childPIDFile = base.appendingPathComponent("child.pid")
    let port = try XCTUnwrap(LocalSitePreviewPortAllocator.allocateDynamicPort())
    let process = Process()
    process.executableURL = python
    process.arguments = QuartzStaticPreviewRunner.arguments(
      rootPath: site.path, nodePath: python.path, port: port
    )
    process.environment = ProcessInfo.processInfo.environment.merging([
      "TMPDIR": base.path, "BUILD_PID_FILE": buildPIDFile.path,
      "CHILD_PID_FILE": childPIDFile.path,
      "REPOPRESS_QUARTZ_PREVIEW_TOKEN": "child-test-token",
    ]) { _, override in override }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    do {
      for _ in 0..<100 where !FileManager.default.fileExists(atPath: childPIDFile.path) {
        try await Task.sleep(for: .milliseconds(50))
      }
      let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDFile, encoding: .utf8)))
      #if canImport(Darwin)
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGTERM) }
      #else
        if process.isRunning { process.terminate() }
      #endif
      try await waitForExit(process, within: .seconds(5), context: "stopped Quartz runner")
      XCTAssertFalse(process.isRunning)
      #if canImport(Darwin)
        var childStillRunning = true
        for _ in 0..<100 {
          if Darwin.kill(childPID, 0) == -1, errno == ESRCH {
            childStillRunning = false
            break
          }
          try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(childStillRunning, "Quartz build child remained alive after stop")
      #endif
    } catch {
      #if canImport(Darwin)
        await Self.cleanupOwnedBuildGroup(buildPIDFile: buildPIDFile, childPIDFile: childPIDFile)
      #endif
      await Self.cleanupOwnedProcess(process)
      throw error
    }
    #if canImport(Darwin)
      await Self.cleanupOwnedBuildGroup(buildPIDFile: buildPIDFile, childPIDFile: childPIDFile)
    #endif
    await Self.cleanupOwnedProcess(process)
  }

  func testEscapingRepositoryLinkStopsBeforeQuartzBuild() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "quartz-link-preview-test-\(UUID().uuidString)", isDirectory: true
    )
    let site = base.appendingPathComponent("site", isDirectory: true)
    let quartz = site.appendingPathComponent("quartz", isDirectory: true)
    try FileManager.default.createDirectory(at: quartz, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try Data("export default {}".utf8).write(
      to: site.appendingPathComponent("quartz.config.ts")
    )
    try Data("not executed".utf8).write(to: quartz.appendingPathComponent("bootstrap-cli.mjs"))
    try FileManager.default.createSymbolicLink(
      at: site.appendingPathComponent("outside"), withDestinationURL: base
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = QuartzStaticPreviewRunner.arguments(
      rootPath: site.path, nodePath: "/usr/bin/python3", port: 43210
    )
    process.environment = ProcessInfo.processInfo.environment.merging([
      "TMPDIR": base.path, "REPOPRESS_QUARTZ_PREVIEW_TOKEN": "link-test-token",
    ]) {
      _, override in override
    }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    do {
      try await waitForExit(process, within: .seconds(10), context: "escaping link rejection")
      XCTAssertNotEqual(process.terminationStatus, 0)
      let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      XCTAssertTrue(log.contains("escaping symbolic link"))
    } catch {
      await Self.cleanupOwnedProcess(process)
      throw error
    }
  }

  func testStaticSnapshotServesLoopbackAndRemovesTemporaryCopy() async throws {
    let python = URL(fileURLWithPath: "/usr/bin/python3")
    guard FileManager.default.isExecutableFile(atPath: python.path) else {
      throw XCTSkip("System Python is unavailable")
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "quartz-static-preview-test-\(UUID().uuidString)", isDirectory: true
    )
    let site = base.appendingPathComponent("site", isDirectory: true)
    let quartz = site.appendingPathComponent("quartz", isDirectory: true)
    try FileManager.default.createDirectory(at: quartz, withIntermediateDirectories: true)
    try Data("export default {}".utf8).write(
      to: site.appendingPathComponent("quartz.config.ts")
    )
    try Data(
      """
      from pathlib import Path
      import sys
      output = Path(sys.argv[sys.argv.index('--output') + 1])
      output.mkdir(parents=True)
      (output / 'index.html').write_text('<h1>Quartz fixture</h1>')
      print('content/note.md:4: fixture diagnostic')
      """.utf8
    ).write(to: quartz.appendingPathComponent("bootstrap-cli.mjs"))
    defer { try? FileManager.default.removeItem(at: base) }

    let port = try XCTUnwrap(LocalSitePreviewPortAllocator.allocateDynamicPort())
    let process = Process()
    process.executableURL = python
    process.arguments = QuartzStaticPreviewRunner.arguments(
      rootPath: site.path, nodePath: python.path, port: port
    )
    process.environment = ProcessInfo.processInfo.environment.merging([
      "TMPDIR": base.path, "REPOPRESS_QUARTZ_PREVIEW_TOKEN": "ready-test-token",
    ]) {
      _, override in override
    }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    do {
      var responseText: String?
      for _ in 0..<100 {
        if !process.isRunning { break }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 0.2
        if let (data, _) = try? await URLSession.shared.data(for: request) {
          responseText = String(decoding: data, as: UTF8.self)
          break
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertEqual(responseText, "<h1>Quartz fixture</h1>")
      let probeURL = URL(string: "http://127.0.0.1:\(port)/.__repopress_quartz_probe")!
      var probeRequest = URLRequest(url: probeURL)
      probeRequest.timeoutInterval = 2.0
      let (_, probeResponse) = try await URLSession.shared.data(for: probeRequest)
      XCTAssertEqual(
        (probeResponse as? HTTPURLResponse)?.value(
          forHTTPHeaderField: "X-RepoPress-Quartz-Preview"),
        "ready-test-token"
      )
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: site.appendingPathComponent("public").path))

      #if canImport(Darwin)
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGTERM) }
      #else
        if process.isRunning { process.terminate() }
      #endif
      try await waitForExit(process, within: .seconds(5), context: "static Quartz preview shutdown")
      let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      XCTAssertTrue(log.contains("content/note.md:4: fixture diagnostic"))
      let retained = try FileManager.default.contentsOfDirectory(atPath: base.path).filter {
        $0.hasPrefix("RepoPress-Quartz-Preview-\(process.processIdentifier)-")
      }
      XCTAssertTrue(retained.isEmpty)
    } catch {
      await Self.cleanupOwnedProcess(process)
      throw error
    }
  }

  func testCancelledCleanupReapsTermIgnoringFixtureAfterTimeout() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "quartz-cleanup-test-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let readyFile = base.appendingPathComponent("ready")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-c",
      """
      import signal
      import sys
      import time
      from pathlib import Path
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      Path(sys.argv[1]).write_text('ready')
      time.sleep(30)
      """,
      readyFile.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    do {
      for _ in 0..<100 where !FileManager.default.fileExists(atPath: readyFile.path) {
        try await Task.sleep(for: .milliseconds(50))
      }
      guard FileManager.default.fileExists(atPath: readyFile.path) else {
        throw ProcessExitError.timedOut("TERM-ignoring fixture startup")
      }
      var timedOut = false
      do {
        try await waitForExit(process, within: .milliseconds(200), context: "TERM-ignoring fixture")
      } catch ProcessExitError.timedOut {
        timedOut = true
      }
      XCTAssertTrue(timedOut, "The live fixture must report a timeout before cleanup")

      withUnsafeCurrentTask { $0?.cancel() }
      await Self.cleanupOwnedProcess(process)
      XCTAssertFalse(process.isRunning, "Cancelled cleanup left the owned fixture alive")
    } catch {
      await Self.cleanupOwnedProcess(process)
      throw error
    }
  }
}
