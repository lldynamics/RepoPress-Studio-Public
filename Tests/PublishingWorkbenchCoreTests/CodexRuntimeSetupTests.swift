import Foundation
import XCTest

@testable import PublishingAICore
@testable import PublishingWorkbenchCore

final class CodexRuntimeSetupTests: XCTestCase {
  func testRecommendationDoesNotBlockOlderCompatibleRuntime() {
    let status = CodexAppServerRuntimeStatus(
      executableURL: URL(fileURLWithPath: "/tmp/codex"), version: "codex-cli 0.148.0")
    XCTAssertTrue(status.isCompatible)
    XCTAssertTrue(CodexRuntimeSetupService.needsRecommendedUpdate(status))
    XCTAssertTrue(CodexRuntimeSetupService.plan(for: .init()).isAutomatic)
    XCTAssertFalse(CodexRuntimeSetupService.plan(for: status).isAutomatic)
  }

  func testHomebrewFormulaAndCaskKeepTheirOriginalChannel() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try makeExecutable(bin.appendingPathComponent("brew"))
    for (component, method) in [
      ("Caskroom", CodexRuntimeSetupPlan.Method.homebrew), ("Cellar", .homebrewFormula),
    ] {
      let target = root.appendingPathComponent("\(component)/codex/0.148.0/codex")
      try makeExecutable(target)
      let runtime = bin.appendingPathComponent("codex")
      try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: target)
      let plan = CodexRuntimeSetupService.plan(
        for: .init(executableURL: runtime, source: .homebrew, version: "codex-cli 0.148.0"))
      XCTAssertEqual(plan.method, method)
      XCTAssertEqual(
        CodexRuntimeSetupService.managerArguments(for: method),
        ["upgrade", component == "Cellar" ? "--formula" : "--cask", "codex"])
      try FileManager.default.removeItem(at: runtime)
    }
  }

  func testStandaloneInstallIsFoundWithoutShellPATH() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent(".codex/packages/standalone/releases/0.153.4/codex")
    try makeExecutable(target)
    let bin = root.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let runtime = bin.appendingPathComponent("codex")
    try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: target)
    let location = try XCTUnwrap(
      CodexAppServerProcessTransport.discoverRuntimeLocation(
        environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"], fallbackCandidates: []))
    XCTAssertEqual(location.url, runtime)
    let plan = CodexRuntimeSetupService.plan(
      for: .init(executableURL: runtime, source: .path), environment: ["HOME": root.path])
    XCTAssertEqual(plan.method, .standalone)
  }

  func testInstallerFailureRetainsBoundedStderrAndExitStatus() async {
    let result = await AIComponentProcessRunner(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf 'permission denied' >&2; exit 7"]
    ).run(timeout: .seconds(2))
    XCTAssertFalse(result.succeeded)
    XCTAssertNotEqual(result.terminationStatus, 0)
    XCTAssertTrue(result.output.contains("permission denied"))
    XCTAssertEqual(
      CodexRuntimeSetupService.sanitizedDiagnostic("https://user:password@example.com/path"),
      "https://[已隐藏]@example.com/path")
  }

  func testAlreadyCancelledInstallerDoesNotLaunch() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("should-not-exist")
    let task = Task {
      try? await Task.sleep(for: .seconds(1))
      return await AIComponentProcessRunner(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "/usr/bin/touch \"$1\"", "fixture", marker.path]
      ).run(timeout: .seconds(2))
    }
    task.cancel()
    let result = await task.value
    XCTAssertEqual(result.interruption, "cancelled")
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testInstallerTimeoutEndsItsProcessGroup() async {
    let result = await AIComponentProcessRunner(
      executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 20 & wait"]
    ).run(timeout: .milliseconds(50))
    XCTAssertFalse(result.succeeded)
    XCTAssertEqual(result.interruption, "timedOut")
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexSetupTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeExecutable(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }
}
