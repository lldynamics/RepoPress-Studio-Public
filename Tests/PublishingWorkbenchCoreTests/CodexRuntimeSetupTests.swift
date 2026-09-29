import Foundation
import XCTest

@testable import PublishingAICore
@testable import PublishingWorkbenchCore

final class CodexRuntimeSetupTests: XCTestCase {
  func testManagedRuntimeRecommendationKeepsOlderRuntimeUsable() {
    let status = CodexAppServerRuntimeStatus(
      executableURL: URL(fileURLWithPath: "/tmp/codex"), version: "codex-cli 0.148.0")
    XCTAssertTrue(status.isCompatible)
    XCTAssertTrue(CodexRuntimeSetupService.needsRecommendedUpdate(status))
    XCTAssertTrue(CodexRuntimeSetupService.plan(for: .init()).isAutomatic)
    XCTAssertEqual(CodexRuntimeSetupService.plan(for: status).method, .managed)
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

  func testPrepareUsesManagedArchiveAndAtomicallyKeepsPreviousSelection() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeArchive(in: root, version: "0.157.0")
    let release = CodexRuntimeRelease(
      version: .init(major: 0, minor: 157, patch: 0),
      archiveURL: URL(string: "https://example.invalid/codex.tar.gz")!,
      sha256: try CodexRuntimeSetupService.digest(of: fixture))
    let layout = CodexManagedRuntime(directory: root.appendingPathComponent("managed"))
    var initial = CodexManagedRuntime.Selection()
    initial.activeRelease = "old"
    initial.previousRelease = "older"
    initial.useSystem = true
    try layout.save(initial)
    let service = CodexRuntimeSetupService(
      directory: layout.directory, release: release,
      download: { _, destination in try FileManager.default.copyItem(at: fixture, to: destination)
      },
      validate: { _, _ in })

    let status = try await service.prepare(plan: .init(method: .managed, runtimeURL: nil)) { _ in }
    let updated = try layout.selection()
    XCTAssertEqual(status.source, .managed)
    XCTAssertEqual(updated.previousRelease, "old")
    XCTAssertEqual(updated.deferredVersion, nil)
    XCTAssertFalse(updated.useSystem)
    XCTAssertEqual(
      try XCTUnwrap(status.executableURL), layout.executableURL(for: updated.activeRelease!))
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: status.executableURL!.path))
  }

  func testPrepareRejectsShaMismatchAndValidationFailureWithoutChangingSelection() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeArchive(in: root, version: "0.157.0")
    let release = CodexRuntimeRelease(
      version: .init(major: 0, minor: 157, patch: 0),
      archiveURL: URL(string: "https://example.invalid")!,
      sha256: String(repeating: "0", count: 64))
    let layout = CodexManagedRuntime(directory: root.appendingPathComponent("managed"))
    var initial = CodexManagedRuntime.Selection()
    initial.activeRelease = "stable"
    try layout.save(initial)
    let service = CodexRuntimeSetupService(
      directory: layout.directory, release: release,
      download: { _, destination in try FileManager.default.copyItem(at: fixture, to: destination)
      },
      validate: { _, _ in throw CodexRuntimeSetupError.verificationFailed })
    do {
      _ = try await service.prepare(plan: .init(method: .managed, runtimeURL: nil)) { _ in }
      XCTFail("expected digest failure")
    } catch { XCTAssertEqual(error as? CodexRuntimeSetupError, .invalidArchive) }
    XCTAssertEqual(try layout.selection(), initial)

    let valid = CodexRuntimeRelease(
      version: release.version, archiveURL: release.archiveURL,
      sha256: try CodexRuntimeSetupService.digest(of: fixture))
    let failing = CodexRuntimeSetupService(
      directory: layout.directory, release: valid,
      download: { _, destination in try FileManager.default.copyItem(at: fixture, to: destination)
      },
      validate: { _, _ in throw CodexRuntimeSetupError.verificationFailed })
    do {
      _ = try await failing.prepare(plan: .init(method: .managed, runtimeURL: nil)) { _ in }
      XCTFail("expected validation failure")
    } catch { XCTAssertEqual(error as? CodexRuntimeSetupError, .verificationFailed) }
    XCTAssertEqual(try layout.selection(), initial)
  }

  func testPrepareCancellationLeavesSelectionUntouched() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let release = CodexRuntimeRelease(
      version: .init(major: 0, minor: 157, patch: 0),
      archiveURL: URL(string: "https://example.invalid")!, sha256: String(repeating: "0", count: 64)
    )
    let layout = CodexManagedRuntime(directory: root)
    var initial = CodexManagedRuntime.Selection()
    initial.activeRelease = "stable"
    try layout.save(initial)
    let service = CodexRuntimeSetupService(
      directory: root, release: release,
      download: { _, _ in try await Task.sleep(for: .seconds(30)) }, validate: { _, _ in })
    let task = Task {
      _ = try await service.prepare(plan: .init(method: .managed, runtimeURL: nil)) { _ in }
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(try layout.selection(), initial)
  }

  func testPrepareReportsInstallationLockConflict() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = try CodexRuntimeInstallationLock(directory: root)
    defer { lock.unlock() }
    let release = CodexRuntimeRelease(
      version: .init(major: 0, minor: 157, patch: 0),
      archiveURL: URL(string: "https://example.invalid")!, sha256: "")
    let service = CodexRuntimeSetupService(
      directory: root, release: release,
      download: { _, _ in }, validate: { _, _ in })
    do {
      _ = try await service.prepare(plan: .init(method: .managed, runtimeURL: nil)) { _ in }
      XCTFail("expected lock conflict")
    } catch { XCTAssertEqual(error as? CodexRuntimeSetupError, .installationBusy) }
  }

  func testRollbackSetsDeferredVersionAndSwapsSelection() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = CodexManagedRuntime(directory: root)
    let old = try makeVersionedExecutable(
      at: layout.releasesDirectory.appendingPathComponent("old/bin/codex"), version: "0.156.0")
    _ = old
    var initial = CodexManagedRuntime.Selection()
    initial.activeRelease = "new"
    initial.previousRelease = "old"
    try layout.save(initial)
    let release = CodexRuntimeRelease(
      version: .init(major: 0, minor: 157, patch: 0),
      archiveURL: URL(string: "https://example.invalid")!, sha256: "")
    let service = CodexRuntimeSetupService(
      directory: root, release: release,
      download: { _, _ in }, validate: { _, _ in })
    try await service.rollback()
    let value = try layout.selection()
    XCTAssertEqual(value.activeRelease, "old")
    XCTAssertEqual(value.previousRelease, "new")
    XCTAssertEqual(value.deferredVersion, "0.157.0")
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

  private func makeArchive(in root: URL, version: String) throws -> URL {
    let fixture = root.appendingPathComponent("fixture-\(version)")
    let executable = fixture.appendingPathComponent("bin/codex")
    try makeExecutable(executable)
    let archive = root.appendingPathComponent("fixture.tar.gz")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-czf", archive.path, "-C", fixture.path, "bin/codex"]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return archive
  }

  private func makeVersionedExecutable(at url: URL, version: String) throws -> URL {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n[ \"$1\" = \"--version\" ] && echo codex-cli \(version)\n".utf8).write(
      to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }
}

final class CodexManagedRuntimeTests: XCTestCase {
  func testManagedSelectionIsPreferredAndSystemRequiresExplicitOptIn() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = CodexManagedRuntime(directory: root)
    let id = "0.157.0-abc"
    let executable = try makeExecutable(
      at: layout.releasesDirectory.appendingPathComponent(id).appendingPathComponent("bin/codex"))
    var selection = CodexManagedRuntime.Selection()
    selection.activeRelease = id
    try layout.save(selection)
    XCTAssertEqual(layout.preferredExecutableURL(), executable)
    selection.useSystem = true
    try layout.save(selection)
    XCTAssertNil(layout.preferredExecutableURL())
  }

  func testMissingOrDamagedManagedSelectionDoesNotFallBackToSystemCLI() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = CodexManagedRuntime(directory: root)
    var selection = CodexManagedRuntime.Selection()
    selection.activeRelease = "missing"
    try layout.save(selection)
    let preferred = try XCTUnwrap(layout.preferredExecutableURL())
    XCTAssertEqual(preferred, layout.executableURL(for: "missing"))
    XCTAssertFalse(FileManager.default.isExecutableFile(atPath: preferred.path))
    try Data("invalid selection".utf8).write(to: layout.selectionURL)
    let damaged = try XCTUnwrap(layout.preferredExecutableURL())
    XCTAssertTrue(damaged.path.hasSuffix("unavailable/bin/codex"))
  }

  func testSelectionRejectsPathTraversalIDs() throws {
    var selection = CodexManagedRuntime.Selection()
    selection.activeRelease = "../system"
    XCTAssertThrowsError(try CodexManagedRuntime(directory: temporaryDirectory()).save(selection))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexManaged-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeExecutable(at url: URL) throws -> URL {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }
}

@MainActor
final class CodexConnectionControllerTests: XCTestCase {
  func testRefreshMapsMissingOldNeedsLoginReadyAndFailedStates() async throws {
    let cases:
      [(
        CodexAppServerRuntimeStatus, Result<CodexAppServerAccountStatus, Error>,
        CodexConnectionPhase
      )] = [
        (.init(), .success(.init(isAuthenticated: false)), .missingComponent),
        (
          .init(executableURL: URL(fileURLWithPath: "/tmp/codex"), source: .managed),
          .success(.init(isAuthenticated: false)), .failed
        ),
        (
          .init(executableURL: URL(fileURLWithPath: "/tmp/codex"), version: "invalid version"),
          .success(.init(isAuthenticated: false)), .failed
        ),
        (
          .init(executableURL: URL(fileURLWithPath: "/tmp/codex"), version: "codex-cli 0.141.0"),
          .success(.init(isAuthenticated: true, accountType: "chatgpt")), .updateRequired
        ),
        (
          .init(executableURL: URL(fileURLWithPath: "/tmp/codex"), version: "codex-cli 0.157.0"),
          .success(.init(isAuthenticated: true, accountType: "api_key")), .needsLogin
        ),
        (
          .init(executableURL: URL(fileURLWithPath: "/tmp/codex"), version: "codex-cli 0.157.0"),
          .success(.init(isAuthenticated: true, accountType: "chatgpt")), .ready
        ),
      ]
    for (runtime, account, expected) in cases {
      let controller = makeController(runtime: runtime, account: account)
      await controller.refresh()
      XCTAssertEqual(controller.phase, expected)
    }
    let failed = makeController(
      runtime: compatibleRuntime(), account: .failure(CodexAppServerError.invalidResponse))
    await failed.refresh()
    XCTAssertEqual(failed.phase, .failed)
    XCTAssertFalse(failed.failure?.isEmpty ?? true)
  }

  func testAuthorizationRequiredIsNeedsLoginAndApiKeyIsNotReady() async {
    let controller = makeController(
      runtime: compatibleRuntime(),
      account: .failure(CodexAppServerError.accountAuthorizationRequired))
    await controller.refresh()
    XCTAssertEqual(controller.phase, .needsLogin)
    let apiKey = makeController(
      runtime: compatibleRuntime(),
      account: .success(.init(isAuthenticated: true, accountType: "api_key")))
    await apiKey.refresh()
    XCTAssertEqual(apiKey.phase, .needsLogin)
  }

  func testConcurrentRefreshesShareOneInspectionAndAccountRead() async {
    let counter = RefreshCounter()
    let controller = makeController(
      runtime: compatibleRuntime(),
      account: .success(.init(isAuthenticated: true, accountType: "chatgpt")), counter: counter)
    let first = Task { await controller.refresh() }
    let second = Task { await controller.refresh() }
    await first.value
    await second.value
    let inspections = await counter.inspections
    let accounts = await counter.accounts
    XCTAssertEqual(inspections, 1)
    XCTAssertEqual(accounts, 1)
  }

  func testAutomaticUpdateRequiresManagedOptInAndSuppressesDeferredVersion() {
    let old = CodexAppServerRuntimeStatus(
      executableURL: URL(fileURLWithPath: "/tmp/codex"), source: .managed,
      version: "codex-cli 0.148.0")
    var selection = CodexManagedRuntime.Selection()
    selection.automaticallyUpdates = true
    XCTAssertTrue(
      CodexConnectionController.shouldAutomaticallyUpdate(
        selection: selection, status: old, attemptedVersion: nil))
    selection.useSystem = true
    XCTAssertFalse(
      CodexConnectionController.shouldAutomaticallyUpdate(
        selection: selection, status: old, attemptedVersion: nil))
    selection.useSystem = false
    selection.deferredVersion = CodexRuntimeSetupService.recommendedVersion.description
    XCTAssertFalse(
      CodexConnectionController.shouldAutomaticallyUpdate(
        selection: selection, status: old, attemptedVersion: nil))
    XCTAssertFalse(
      CodexConnectionController.shouldAutomaticallyUpdate(
        selection: selection,
        status: .init(executableURL: old.executableURL, source: .path, version: old.version),
        attemptedVersion: nil))
  }

  func testAccountDidChangeWaitsForInFlightRefreshThenReadsAgain() async {
    let gate = AccountReadGate()
    let controller = makeController(
      runtime: compatibleRuntime(),
      account: .success(.init(isAuthenticated: true, accountType: "chatgpt")), accountGate: gate)
    let initial = Task { await controller.refresh() }
    await gate.waitUntilStarted()
    let changed = Task { await controller.accountDidChange() }
    await Task.yield()
    await gate.releaseFirstRead()
    await changed.value
    await initial.value
    let reads = await gate.readCount
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(controller.phase, .needsLogin)
    XCTAssertFalse(controller.accountStatus?.isAuthenticated ?? true)
  }

  func testPrepareCannotCancelAfterAtomicCommitWhileReconnectIsPending() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try makeArchive(in: root, version: "0.157.0")
    let release = CodexRuntimeRelease(
      version: .init(major: 0, minor: 157, patch: 0),
      archiveURL: URL(string: "https://example.invalid/runtime.tar.gz")!,
      sha256: try CodexRuntimeSetupService.digest(of: archive))
    let pending = ReconnectPendingGate()
    let compatible = selfCompatibleRuntime()
    let service = CodexRuntimeSetupService(
      directory: root.appendingPathComponent("managed"), release: release,
      download: { _, destination in try FileManager.default.copyItem(at: archive, to: destination)
      }, validate: { _, _ in })
    let controller = CodexConnectionController(
      service: service, inspect: { compatible },
      readAccount: { .init(isAuthenticated: true, accountType: "chatgpt") },
      reconnect: {
        await pending.reconnectStarted()
        return true
      },
      reconnectPending: { await pending.isPending() })
    controller.prepare()
    await pending.waitUntilReconnectStarted()
    XCTAssertFalse(controller.canCancelPreparation)
    controller.cancelPreparation()
    XCTAssertTrue(controller.isPreparing)
    await pending.release()
    while controller.isPreparing { await Task.yield() }
    XCTAssertFalse(controller.isPreparing)
    XCTAssertFalse(controller.canCancelPreparation)
    XCTAssertEqual(controller.phase, .ready)
  }

  func testFailedUpdateRetainsReadyPhaseAndExplicitFailureWithOldSelection() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = CodexManagedRuntime(directory: root)
    var selection = CodexManagedRuntime.Selection()
    selection.activeRelease = "old"
    try layout.save(selection)
    let release = CodexRuntimeRelease(
      version: .init(major: 0, minor: 157, patch: 0),
      archiveURL: URL(string: "https://example.invalid")!, sha256: "")
    let compatible = selfCompatibleRuntime()
    let service = CodexRuntimeSetupService(
      directory: root, release: release,
      download: { _, _ in throw CodexRuntimeSetupError.failed("simulated update failure") },
      validate: { _, _ in })
    let controller = CodexConnectionController(
      service: service, inspect: { compatible },
      readAccount: { .init(isAuthenticated: true, accountType: "chatgpt") })
    controller.prepare()
    while controller.isPreparing { await Task.yield() }
    XCTAssertEqual(controller.phase, .ready)
    XCTAssertFalse(controller.failure?.isEmpty ?? true)
    XCTAssertEqual(try layout.selection(), selection)
  }

  func testApprovedArchiveInstallationWhenProvided() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["REPOPRESS_TEST_CODEX_ARCHIVE"], !path.isEmpty else {
      throw XCTSkip("set REPOPRESS_TEST_CODEX_ARCHIVE for the isolated real runtime acceptance")
    }
    let archive = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: archive.path) else {
      throw XCTSkip("archive is unavailable")
    }
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let release = CodexRuntimeRelease.approved
    let service = CodexRuntimeSetupService(
      directory: root, release: release,
      download: { _, destination in try FileManager.default.copyItem(at: archive, to: destination)
      },
      validate: CodexRuntimeSetupService.validateExecutable)
    let status = try await service.prepare(plan: .init(method: .managed, runtimeURL: nil)) { _ in }
    XCTAssertEqual(status.source, .managed)
    XCTAssertEqual(status.version, "codex-cli \(release.version)")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: try XCTUnwrap(status.executableURL).path))
  }

  private func compatibleRuntime() -> CodexAppServerRuntimeStatus {
    .init(
      executableURL: URL(fileURLWithPath: "/tmp/codex"), source: .managed,
      version: "codex-cli 0.157.0")
  }
  private func makeController(
    runtime: CodexAppServerRuntimeStatus, account: Result<CodexAppServerAccountStatus, Error>,
    counter: RefreshCounter? = nil, accountGate: AccountReadGate? = nil
  ) -> CodexConnectionController {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexController-\(UUID().uuidString)")
    let service = CodexRuntimeSetupService(
      directory: root, release: .approved, download: { _, _ in }, validate: { _, _ in })
    return CodexConnectionController(
      service: service,
      inspect: {
        await counter?.inspected()
        return runtime
      },
      readAccount: {
        await counter?.accounted()
        if let accountGate {
          let index = await accountGate.beginRead()
          if index == 1 { await accountGate.waitFirstReadRelease() }
          return index == 1 ? try account.get() : .init(isAuthenticated: false)
        }
        return try account.get()
      })
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexController-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeArchive(in root: URL, version: String) throws -> URL {
    let fixture = root.appendingPathComponent("fixture-\(version)")
    let executable = fixture.appendingPathComponent("bin/codex")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let archive = root.appendingPathComponent("fixture.tar.gz")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-czf", archive.path, "-C", fixture.path, "bin/codex"]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return archive
  }

  private func selfCompatibleRuntime() -> CodexAppServerRuntimeStatus {
    .init(
      executableURL: URL(fileURLWithPath: "/tmp/codex"), source: .managed,
      version: "codex-cli 0.157.0")
  }
}

private actor RefreshCounter {
  private(set) var inspections = 0
  private(set) var accounts = 0
  func inspected() { inspections += 1 }
  func accounted() { accounts += 1 }
}

private actor AccountReadGate {
  private(set) var readCount = 0
  private var started: CheckedContinuation<Void, Never>?
  private var firstRelease: CheckedContinuation<Void, Never>?
  private var firstReleased = false
  func beginRead() -> Int {
    readCount += 1
    if readCount == 1 {
      started?.resume()
      started = nil
    }
    return readCount
  }
  func waitUntilStarted() async {
    if readCount > 0 { return }
    await withCheckedContinuation { started = $0 }
  }
  func waitFirstReadRelease() async {
    if firstReleased { return }
    await withCheckedContinuation { firstRelease = $0 }
  }
  func releaseFirstRead() {
    firstReleased = true
    firstRelease?.resume()
    firstRelease = nil
  }
}

private actor ReconnectPendingGate {
  private var pending = true
  private var started: CheckedContinuation<Void, Never>?
  private var didStart = false
  func reconnectStarted() {
    didStart = true
    started?.resume()
    started = nil
  }
  func waitUntilReconnectStarted() async {
    if didStart { return }
    await withCheckedContinuation { started = $0 }
  }
  func isPending() -> Bool { pending }
  func release() { pending = false }
}
