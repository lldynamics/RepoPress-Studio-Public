import Foundation
import XCTest

@testable import PublishingPreviewCore
@testable import PublishingWorkbenchCore

#if canImport(Darwin)
  import Darwin
#endif

final class QuartzStaticPreviewRunnerTests: XCTestCase {
  func testBuildLogLimitStopsNoisyBuilder() throws {
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
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      let stopDeadline = Date().addingTimeInterval(2)
      while process.isRunning, Date() < stopDeadline {
        Thread.sleep(forTimeInterval: 0.05)
      }
      #if canImport(Darwin)
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
      #endif
      XCTFail("Noisy builder outlived its log limit")
    }
    process.waitUntilExit()
    let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertTrue(log.contains("exceeded its log limit"))
    XCTAssertLessThan(log.utf8.count, 80_000)
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
      wrapper.waitUntilExit()
      XCTAssertEqual(wrapper.terminationStatus, 0)
      let runnerPID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
      defer { _ = Darwin.kill(runnerPID, SIGKILL) }
      var runnerExited = false
      for _ in 0..<100 {
        if Darwin.kill(runnerPID, 0) == -1, errno == ESRCH {
          runnerExited = true
          break
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertTrue(runnerExited, "Quartz runner survived its launching parent")
      let retained = try FileManager.default.contentsOfDirectory(atPath: base.path).filter {
        $0.hasPrefix("RepoPress-Quartz-Preview-\(runnerPID)-")
      }
      XCTAssertTrue(retained.isEmpty)
    #else
      throw XCTSkip("Requires Darwin process inspection")
    #endif
  }

  func testTemporaryDirectoryInsideRepositoryFailsBeforeCopy() throws {
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
    process.waitUntilExit()
    XCTAssertNotEqual(process.terminationStatus, 0)
    let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertTrue(log.contains("temporary directory is inside the repository"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: site.path), [])
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
      child = subprocess.Popen(['/bin/sleep', '30'])
      Path(os.environ['CHILD_PID_FILE']).write_text(str(child.pid))
      time.sleep(30)
      """.utf8
    ).write(to: quartz.appendingPathComponent("bootstrap-cli.mjs"))
    let childPIDFile = base.appendingPathComponent("child.pid")
    let port = try XCTUnwrap(LocalSitePreviewPortAllocator.allocateDynamicPort())
    let process = Process()
    process.executableURL = python
    process.arguments = QuartzStaticPreviewRunner.arguments(
      rootPath: site.path, nodePath: python.path, port: port
    )
    process.environment = ProcessInfo.processInfo.environment.merging([
      "TMPDIR": base.path, "CHILD_PID_FILE": childPIDFile.path,
      "REPOPRESS_QUARTZ_PREVIEW_TOKEN": "child-test-token",
    ]) { _, override in override }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }

    for _ in 0..<100 where !FileManager.default.fileExists(atPath: childPIDFile.path) {
      try await Task.sleep(for: .milliseconds(50))
    }
    let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDFile, encoding: .utf8)))
    process.terminate()
    for _ in 0..<100 where process.isRunning {
      try await Task.sleep(for: .milliseconds(50))
    }
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
  }

  func testEscapingRepositoryLinkStopsBeforeQuartzBuild() throws {
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
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    if finished.wait(timeout: .now() + 10) == .timedOut {
      process.terminate()
      XCTFail("Quartz preview did not reject the escaping link")
    }
    process.waitUntilExit()

    XCTAssertNotEqual(process.terminationStatus, 0)
    let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertTrue(log.contains("escaping symbolic link"))
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
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }

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
    let (_, probeResponse) = try await URLSession.shared.data(from: probeURL)
    XCTAssertEqual(
      (probeResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-RepoPress-Quartz-Preview"),
      "ready-test-token"
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: site.appendingPathComponent("public").path))

    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertTrue(log.contains("content/note.md:4: fixture diagnostic"))
    let retained = try FileManager.default.contentsOfDirectory(atPath: base.path).filter {
      $0.hasPrefix("RepoPress-Quartz-Preview-\(process.processIdentifier)-")
    }
    XCTAssertTrue(retained.isEmpty)
  }
}
