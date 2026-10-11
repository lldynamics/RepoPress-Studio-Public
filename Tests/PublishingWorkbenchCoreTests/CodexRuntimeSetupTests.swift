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

@MainActor
final class CodexAccountLoginCoordinatorTests: XCTestCase {
  private let authenticated = CodexAppServerAccountStatus(
    isAuthenticated: true, accountID: "fixture", accountType: "chatgpt")

  func testOnlyOneOwnerCanStartAnAccountOperation() async {
    let service = ControlledAccountLoginService()
    var refreshed = false
    let account = authenticated
    let coordinator = CodexAccountLoginCoordinator(
      service: service, accountDidChange: { refreshed = true }, accountStatus: { account })
    let owner = UUID()
    XCTAssertTrue(start(coordinator, owner: owner))
    XCTAssertFalse(start(coordinator, owner: UUID()))
    XCTAssertFalse(coordinator.logout(owner: UUID()))
    let waiting = await service.waitUntilWaiting()
    XCTAssertTrue(waiting)
    coordinator.cancelLogin(owner: UUID())
    XCTAssertEqual(coordinator.phase, .waiting)
    XCTAssertEqual(coordinator.ownerID, owner)
    await service.completeWait()
    await coordinator.waitForCurrentOperation()
    XCTAssertTrue(refreshed)
    XCTAssertEqual(coordinator.completion?.ownerID, owner)
    XCTAssertEqual(coordinator.completion?.result, .loggedIn)
  }

  func testOwnerCancellationWaitsForLateTaskBeforeAdmittingReplacement() async {
    let service = ControlledAccountLoginService()
    let account = authenticated
    let coordinator = CodexAccountLoginCoordinator(
      service: service, accountDidChange: {}, accountStatus: { account })
    let first = UUID()
    XCTAssertTrue(start(coordinator, owner: first))
    let waiting = await service.waitUntilWaiting()
    XCTAssertTrue(waiting)
    let originalOperation = coordinator.operationID
    coordinator.cancelLogin(owner: first)
    XCTAssertEqual(coordinator.phase, .cancelling)
    XCTAssertFalse(start(coordinator, owner: UUID()))
    await service.completeWait()
    await coordinator.waitForCurrentOperation()
    XCTAssertNil(coordinator.completion)
    XCTAssertNil(coordinator.deviceCode)
    XCTAssertEqual(coordinator.phase, .idle)
    let cancellations = await service.cancellationCount
    XCTAssertEqual(cancellations, 1)
    let second = UUID()
    XCTAssertTrue(start(coordinator, owner: second))
    XCTAssertNotEqual(coordinator.operationID, originalOperation)
    let secondWaiting = await service.waitUntilWaiting()
    XCTAssertTrue(secondWaiting)
    await service.completeWait()
    await coordinator.waitForCurrentOperation()
    XCTAssertEqual(coordinator.completion?.ownerID, second)
    XCTAssertEqual(coordinator.phase, .succeeded)
  }

  func testBrowserOpenFailureCancelsTheSessionWithoutWaiting() async {
    let service = ControlledAccountLoginService()
    let coordinator = CodexAccountLoginCoordinator(
      service: service, accountDidChange: {}, accountStatus: { nil })
    XCTAssertTrue(start(coordinator, owner: UUID(), opened: false))
    await coordinator.waitForCurrentOperation()
    XCTAssertEqual(coordinator.phase, .failed)
    XCTAssertTrue(coordinator.isError)
    XCTAssertNil(coordinator.completion)
    let cancellations = await service.cancellationCount
    let waits = await service.waitCount
    XCTAssertEqual(cancellations, 1)
    XCTAssertEqual(waits, 0)
  }

  func testOwnerCancellationDuringBrowserFailureCleanupDoesNotBecomeFailure() async {
    let service = ControlledAccountLoginService(holdCancellation: true)
    let coordinator = CodexAccountLoginCoordinator(
      service: service, accountDidChange: {}, accountStatus: { nil })
    let owner = UUID()
    XCTAssertTrue(start(coordinator, owner: owner, opened: false))
    let cancelling = await service.waitUntilCancelling()
    XCTAssertTrue(cancelling)
    coordinator.cancelLogin(owner: owner)
    XCTAssertEqual(coordinator.phase, .cancelling)
    XCTAssertFalse(start(coordinator, owner: UUID()))
    await service.releaseCancellation()
    await coordinator.waitForCurrentOperation()
    XCTAssertEqual(coordinator.phase, .idle)
    XCTAssertFalse(coordinator.isError)
    XCTAssertNil(coordinator.completion)
    let cancellations = await service.cancellationCount
    XCTAssertEqual(cancellations, 1)
  }

  func testClientCancellationAndExpiryKeepCoordinatorBusyUntilRemoteCleanup() async throws {
    for expires in [false, true] {
      let transport = ControlledLoginTransport(holdCancellation: true)
      let client = CodexAppServerClient(transport: transport)
      let coordinator = CodexAccountLoginCoordinator(
        service: client, accountDidChange: {}, accountStatus: { nil })
      let owner = UUID()
      XCTAssertTrue(start(coordinator, owner: owner))
      let sent = await transport.waitForMessage("account/login/start")
      XCTAssertTrue(sent)
      await transport.replyToLogin()
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(2))
      while await client.loginState.waiters.isEmpty, clock.now < deadline {
        try await clock.sleep(for: .milliseconds(1))
      }
      let waiting = await !client.loginState.waiters.isEmpty
      XCTAssertTrue(waiting)
      var expiry: Task<Void, Never>?
      if expires {
        let capturedTimerID = await client.loginState.expiryTokens["controlled-login"]
        let timerID = try XCTUnwrap(capturedTimerID)
        let generation = await client.transportGeneration
        expiry = Task {
          await client.expireLogin(
            loginID: "controlled-login", timerID: timerID, generation: generation)
        }
      } else {
        coordinator.cancelLogin(owner: owner)
      }
      let cancelling = await transport.waitForMessage("account/login/cancel")
      XCTAssertTrue(cancelling)
      // Observe the whole held-response interval, including the resumed waiter.
      let observationEnd = clock.now.advanced(by: .milliseconds(30))
      while clock.now < observationEnd {
        XCTAssertTrue(coordinator.isBusy)
        if !coordinator.isBusy { break }
        XCTAssertFalse(start(coordinator, owner: UUID()))
        XCTAssertFalse(coordinator.logout(owner: UUID()))
        try await clock.sleep(for: .milliseconds(1))
      }
      await transport.replyToCancellation()
      await expiry?.value
      await coordinator.waitForCurrentOperation()
      XCTAssertEqual(coordinator.phase, expires ? .failed : .idle)
      let cancellations = await transport.count("account/login/cancel")
      XCTAssertEqual(cancellations, 1)
      XCTAssertFalse(coordinator.isBusy)
      await client.shutdown()
    }
  }

  func testDeviceBrowserFailureKeepsCodeForManualRecoveryAndCopiesOnce() async {
    let service = ControlledAccountLoginService()
    let account = authenticated
    let coordinator = CodexAccountLoginCoordinator(
      service: service, accountDidChange: {}, accountStatus: { account })
    var copied: [String] = []
    XCTAssertTrue(
      coordinator.login(
        owner: UUID(), mode: .deviceCode, openURL: { _ in false },
        copyDeviceCode: { copied.append($0) }))
    let waiting = await service.waitUntilWaiting()
    XCTAssertTrue(waiting)
    XCTAssertEqual(coordinator.phase, .waiting)
    XCTAssertTrue(coordinator.isError)
    XCTAssertEqual(coordinator.deviceCode?.userCode, "ABCD-EFGH")
    XCTAssertEqual(copied, ["ABCD-EFGH"])
    await service.completeWait()
    await coordinator.waitForCurrentOperation()
    XCTAssertEqual(coordinator.phase, .succeeded)
    XCTAssertNil(coordinator.deviceCode)
    XCTAssertFalse(coordinator.isError)
  }

  func testDeviceWaitFailureClearsTheExpiredCode() async {
    let service = ControlledAccountLoginService()
    let coordinator = CodexAccountLoginCoordinator(
      service: service, accountDidChange: {}, accountStatus: { nil })
    XCTAssertTrue(
      coordinator.login(
        owner: UUID(), mode: .deviceCode, openURL: { _ in true }, copyDeviceCode: { _ in }))
    let waiting = await service.waitUntilWaiting()
    XCTAssertTrue(waiting)
    XCTAssertNotNil(coordinator.deviceCode)
    await service.failWait()
    await coordinator.waitForCurrentOperation()
    XCTAssertEqual(coordinator.phase, .failed)
    XCTAssertNil(coordinator.deviceCode)
    XCTAssertTrue(coordinator.isError)
    XCTAssertNil(coordinator.completion)
  }

  func testCompletionRequiresRefreshedAuthenticatedChatGPTAccount() async {
    let service = ControlledAccountLoginService()
    var refreshed = false
    let coordinator = CodexAccountLoginCoordinator(
      service: service, accountDidChange: { refreshed = true }, accountStatus: { nil })
    XCTAssertTrue(start(coordinator, owner: UUID()))
    let waiting = await service.waitUntilWaiting()
    XCTAssertTrue(waiting)
    await service.completeWait()
    await coordinator.waitForCurrentOperation()
    XCTAssertTrue(refreshed)
    XCTAssertEqual(coordinator.phase, .failed)
    XCTAssertNil(coordinator.completion)
  }

  func testLogoutIsSerializedAndPublishesCompletionAfterRefresh() async {
    let service = ControlledAccountLoginService()
    var refreshed = false
    let coordinator = CodexAccountLoginCoordinator(
      service: service, accountDidChange: { refreshed = true }, accountStatus: { nil })
    let owner = UUID()
    XCTAssertTrue(coordinator.logout(owner: owner))
    XCTAssertFalse(start(coordinator, owner: UUID()))
    await coordinator.waitForCurrentOperation()
    XCTAssertTrue(refreshed)
    XCTAssertEqual(coordinator.completion?.ownerID, owner)
    XCTAssertEqual(coordinator.completion?.result, .loggedOut)
    let logouts = await service.logoutCount
    XCTAssertEqual(logouts, 1)
  }

  private func start(
    _ coordinator: CodexAccountLoginCoordinator, owner: UUID, opened: Bool = true
  ) -> Bool {
    coordinator.login(
      owner: owner, mode: .browser, openURL: { _ in opened }, copyDeviceCode: { _ in })
  }
}

private actor ControlledAccountLoginService: CodexAccountLoginServing {
  private var waiter: CheckedContinuation<Void, Error>?
  private let holdCancellation: Bool
  private var cancellationWaiter: CheckedContinuation<Void, Never>?
  private(set) var waitCount = 0
  private(set) var cancellationCount = 0
  private(set) var logoutCount = 0

  init(holdCancellation: Bool = false) { self.holdCancellation = holdCancellation }

  func startChatGPTLogin() async throws -> CodexAppServerLoginResult {
    .init(loginID: UUID().uuidString, authURL: URL(string: "https://auth.example.test/browser")!)
  }
  func startChatGPTDeviceCodeLogin() async throws -> CodexAppServerDeviceCodeLoginResult {
    .init(
      loginID: UUID().uuidString, verificationURL: URL(string: "https://auth.example.test/device")!,
      userCode: "ABCD-EFGH")
  }
  func waitForLoginCompletion(loginID: String) async throws {
    waitCount += 1
    try await withCheckedThrowingContinuation { waiter = $0 }
  }
  func cancelLogin(loginID: String) async {
    cancellationCount += 1
    if holdCancellation { await withCheckedContinuation { cancellationWaiter = $0 } }
  }
  func releaseCancellation() {
    cancellationWaiter?.resume()
    cancellationWaiter = nil
  }
  func waitUntilCancelling() async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while cancellationWaiter == nil {
      guard clock.now < deadline else { return false }
      try? await clock.sleep(for: .milliseconds(1))
    }
    return true
  }
  func logout() async throws { logoutCount += 1 }
  func completeWait() {
    waiter?.resume()
    waiter = nil
  }
  func failWait() {
    waiter?.resume(throwing: CodexAppServerError.loginTimedOut)
    waiter = nil
  }
  func waitUntilWaiting() async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while waiter == nil {
      guard clock.now < deadline else { return false }
      try? await clock.sleep(for: .milliseconds(1))
    }
    return true
  }
}

extension CodexConnectionControllerTests {
  func testAccountEventsDiscardInFlightIdentityAndCoalesceBurstIntoFreshRead() async {
    let source = ControllerAccountEventSource()
    let accounts = ControllerAccountReadPlan(
      [
        .init(isAuthenticated: true, accountID: "old", accountType: "chatgpt"),
        .init(isAuthenticated: true, accountID: "new", accountType: "chatgpt"),
      ], holding: [1])
    let controller = eventController(source: source, accounts: accounts)
    let initial = Task { await controller.refresh() }
    let reading = await waitForControllerCondition { await accounts.count == 1 }
    XCTAssertTrue(reading)
    for index in 1...100 {
      source.emit(
        .init(
          generation: 1, accountRevision: UInt64(index), sequence: UInt64(index),
          kind: .accountChanged))
    }
    let invalidated = await waitForControllerCondition { controller.accountEventSequence == 100 }
    XCTAssertTrue(invalidated)
    XCTAssertNil(controller.accountStatus)
    XCTAssertNil(controller.rateLimits)
    await accounts.release(1)
    await initial.value
    let reads = await accounts.count
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(controller.accountStatus?.accountID, "new")
    XCTAssertEqual(controller.phase, .ready)
    source.finish()
  }

  func testAccountChangeDuringFreshReadRequiresAnotherFreshRead() async {
    let source = ControllerAccountEventSource()
    let accounts = ControllerAccountReadPlan(
      [
        .init(isAuthenticated: true, accountID: "old", accountType: "chatgpt"),
        .init(isAuthenticated: true, accountID: "stale", accountType: "chatgpt"),
        .init(isAuthenticated: true, accountID: "current", accountType: "chatgpt"),
      ], holding: [2])
    let controller = eventController(source: source, accounts: accounts)
    await controller.refresh()
    source.emit(.init(generation: 1, accountRevision: 1, sequence: 1, kind: .accountChanged))
    let reading = await waitForControllerCondition { await accounts.count == 2 }
    XCTAssertTrue(reading)
    XCTAssertNil(controller.accountStatus)
    source.emit(.init(generation: 1, accountRevision: 2, sequence: 2, kind: .accountChanged))
    let invalidated = await waitForControllerCondition { controller.accountRevision == 2 }
    XCTAssertTrue(invalidated)
    await accounts.release(2)
    await controller.refresh()
    let reads = await accounts.count
    XCTAssertEqual(reads, 3)
    XCTAssertEqual(controller.accountStatus?.accountID, "current")
    source.finish()
  }

  func testQuotaEventWinsOverEarlierReadWithoutInvalidatingAccount() async {
    let source = ControllerAccountEventSource()
    let quota = ControllerQuotaReadPlan([10], holding: [1])
    let controller = eventController(source: source, quota: quota)
    await controller.refresh()
    let reading = await waitForControllerCondition { await quota.count == 1 }
    XCTAssertTrue(reading)
    let revision = controller.accountRevision
    source.emit(
      .init(
        generation: 1, accountRevision: 0, sequence: 1,
        kind: .rateLimitsUpdated(.init(primary: .init(usedPercent: 80)))))
    let updated = await waitForControllerCondition {
      controller.rateLimits?.primary?.usedPercent == 80
    }
    XCTAssertTrue(updated)
    var waiting = false
    let sharedRead = Task {
      waiting = true
      await controller.refreshRateLimits()
    }
    let joined = await waitForControllerCondition { waiting }
    XCTAssertTrue(joined)
    await quota.release(1)
    await sharedRead.value
    XCTAssertEqual(controller.rateLimits?.primary?.usedPercent, 80)
    XCTAssertEqual(controller.accountRevision, revision)
    let reads = await quota.count
    XCTAssertEqual(reads, 1)
    source.finish()
  }

  func testDroppedAccountEventRevisionInvalidatesBeforeApplyingQuota() async {
    let source = ControllerAccountEventSource()
    let accounts = ControllerAccountReadPlan(
      [
        .init(isAuthenticated: true, accountID: "old", accountType: "chatgpt"),
        .init(isAuthenticated: true, accountID: "new", accountType: "chatgpt"),
      ], holding: [2])
    let controller = eventController(source: source, accounts: accounts)
    await controller.refresh()
    source.emit(
      .init(
        generation: 1, accountRevision: 5, sequence: 100,
        kind: .rateLimitsUpdated(.init(primary: .init(usedPercent: 80)))))
    let reading = await waitForControllerCondition { await accounts.count == 2 }
    XCTAssertTrue(reading)
    XCTAssertNil(controller.accountStatus)
    XCTAssertNil(controller.rateLimits)
    await accounts.release(2)
    await controller.refresh()
    XCTAssertEqual(controller.accountStatus?.accountID, "new")
    XCTAssertEqual(controller.rateLimits?.primary?.usedPercent, 80)
    source.finish()
  }

  func testOldQuotaReadCannotRestorePreviousAccountsQuota() async {
    let source = ControllerAccountEventSource()
    let accounts = ControllerAccountReadPlan(
      [
        .init(isAuthenticated: true, accountID: "old", accountType: "chatgpt"),
        .init(isAuthenticated: true, accountID: "new", accountType: "chatgpt"),
      ])
    let quota = ControllerQuotaReadPlan([10, 20], holding: [1])
    let controller = eventController(source: source, accounts: accounts, quota: quota)
    await controller.refresh()
    let reading = await waitForControllerCondition { await quota.count == 1 }
    XCTAssertTrue(reading)
    await controller.accountDidChange()
    let updated = await waitForControllerCondition {
      controller.rateLimits?.primary?.usedPercent == 20
    }
    XCTAssertTrue(updated)
    await quota.release(1)
    await Task.yield()
    XCTAssertEqual(controller.accountStatus?.accountID, "new")
    XCTAssertEqual(controller.rateLimits?.primary?.usedPercent, 20)
    source.finish()
  }

  func testConnectionClosedDiscardsPendingReadWithoutAutomaticRestart() async {
    let source = ControllerAccountEventSource()
    let accounts = ControllerAccountReadPlan(
      [
        .init(isAuthenticated: true, accountID: "old", accountType: "chatgpt"),
        .init(isAuthenticated: true, accountID: "stale", accountType: "chatgpt"),
      ], holding: [2])
    let controller = eventController(source: source, accounts: accounts)
    await controller.refresh()
    let pending = Task { await controller.refresh() }
    let reading = await waitForControllerCondition { await accounts.count == 2 }
    XCTAssertTrue(reading)
    source.emit(.init(generation: 1, accountRevision: 1, sequence: 1, kind: .connectionClosed))
    let closed = await waitForControllerCondition { controller.phase == .failed }
    XCTAssertTrue(closed)
    await accounts.release(2)
    await pending.value
    await controller.refreshOnForeground()
    XCTAssertEqual(controller.phase, .failed)
    XCTAssertNil(controller.accountStatus)
    XCTAssertNil(controller.rateLimits)
    let reads = await accounts.count
    XCTAssertEqual(reads, 2)
    source.finish()
  }

  func testQuotaReadsAreSharedAndFailureDoesNotHideAuthenticatedAccount() async {
    let source = ControllerAccountEventSource()
    let quota = ControllerQuotaReadPlan([10], holding: [1])
    let controller = eventController(source: source, quota: quota)
    await controller.refresh()
    let reading = await waitForControllerCondition { await quota.count == 1 }
    XCTAssertTrue(reading)
    var firstJoined = false
    var secondJoined = false
    let first = Task {
      firstJoined = true
      return await controller.refreshRateLimits()
    }
    let second = Task {
      secondJoined = true
      return await controller.refreshRateLimits()
    }
    let joined = await waitForControllerCondition { firstJoined && secondJoined }
    XCTAssertTrue(joined)
    await quota.release(1)
    let firstResult = await first.value
    let secondResult = await second.value
    XCTAssertTrue(firstResult)
    XCTAssertTrue(secondResult)
    let reads = await quota.count
    XCTAssertEqual(reads, 1)
    source.finish()

    let runtime = compatibleRuntime()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexQuotaFailure-\(UUID().uuidString)")
    let service = CodexRuntimeSetupService(
      directory: root, release: .approved, download: { _, _ in }, validate: { _, _ in })
    let failed = CodexConnectionController(
      service: service, inspect: { runtime },
      readAccount: { .init(isAuthenticated: true, accountType: "chatgpt") },
      readRateLimits: { throw CodexAppServerError.invalidResponse })
    await failed.refresh()
    let result = await failed.refreshRateLimits()
    XCTAssertFalse(result)
    XCTAssertEqual(failed.phase, .ready)
    XCTAssertTrue(failed.accountStatus?.isAuthenticated ?? false)
    XCTAssertNil(failed.rateLimits)
  }

  func testOutOfOrderSequenceAndOlderGenerationCannotReplaceQuota() async {
    let source = ControllerAccountEventSource()
    let accounts = ControllerAccountReadPlan([
      .init(isAuthenticated: true, accountID: "current", accountType: "chatgpt")
    ])
    let controller = eventController(source: source, accounts: accounts)
    await controller.refresh()
    source.emit(
      .init(
        generation: 2, accountRevision: 0, sequence: 2,
        kind: .rateLimitsUpdated(.init(primary: .init(usedPercent: 80)))))
    let received = await waitForControllerCondition { controller.accountEventSequence == 2 }
    XCTAssertTrue(received)
    source.emit(
      .init(
        generation: 2, accountRevision: 0, sequence: 1,
        kind: .rateLimitsUpdated(.init(primary: .init(usedPercent: 11)))))
    source.emit(
      .init(
        generation: 1, accountRevision: 0, sequence: 3,
        kind: .rateLimitsUpdated(.init(primary: .init(usedPercent: 12)))))
    source.emit(
      .init(
        generation: 2, accountRevision: 0, sequence: 4,
        kind: .rateLimitsUpdated(.init(primary: .init(usedPercent: 80)))))
    let drained = await waitForControllerCondition { controller.accountEventSequence == 4 }
    XCTAssertTrue(drained)
    let reads = await accounts.count
    XCTAssertEqual(reads, 1)
    XCTAssertEqual(controller.rateLimits?.primary?.usedPercent, 80)
    XCTAssertEqual(controller.accountRevision, 0)
    source.finish()
  }

  func testAccountEventDuringPreparationStatusReadGetsFreshIdentityBeforeFinishing() async {
    let source = ControllerAccountEventSource()
    let accounts = ControllerAccountReadPlan(
      [
        .init(isAuthenticated: true, accountID: "stale", accountType: "chatgpt"),
        .init(isAuthenticated: true, accountID: "current", accountType: "chatgpt"),
      ], holding: [1])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexPreparationEvents-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let service = CodexRuntimeSetupService(
      directory: root, release: .approved,
      download: { _, _ in throw CodexRuntimeSetupError.failed("simulated update failure") },
      validate: { _, _ in })
    let runtime = compatibleRuntime()
    let controller = CodexConnectionController(
      service: service, inspect: { runtime }, readAccount: { await accounts.read() },
      accountEvents: { source.stream })
    controller.prepare()
    let reading = await waitForControllerCondition { await accounts.count == 1 }
    XCTAssertTrue(reading)
    XCTAssertTrue(controller.isPreparing)
    source.emit(.init(generation: 1, accountRevision: 1, sequence: 1, kind: .accountChanged))
    let invalidated = await waitForControllerCondition { controller.accountEventSequence == 1 }
    XCTAssertTrue(invalidated)
    await accounts.release(1)
    let finished = await waitForControllerCondition { !controller.isPreparing }
    XCTAssertTrue(finished)
    XCTAssertEqual(controller.phase, .ready)
    XCTAssertEqual(controller.accountStatus?.accountID, "current")
    let reads = await accounts.count
    XCTAssertEqual(reads, 2)
    source.finish()
  }

  func testForegroundChecksRequirePreviousUseAndShareMinimumInterval() async {
    let counter = RefreshCounter()
    let controller = makeController(
      runtime: compatibleRuntime(),
      account: .success(.init(isAuthenticated: true, accountType: "chatgpt")), counter: counter)
    await controller.refreshOnForeground()
    var inspections = await counter.inspections
    XCTAssertEqual(inspections, 0)
    await controller.refresh()
    for _ in 0..<20 { await controller.refreshOnForeground() }
    inspections = await counter.inspections
    XCTAssertEqual(inspections, 1)
  }

  func testEventSubscriptionDoesNotRetainControllerAndStopsOnDeinit() async {
    let source = ControllerAccountEventSource()
    let quota = ControllerQuotaReadPlan([10], holding: [1])
    var controller: CodexConnectionController? = eventController(source: source, quota: quota)
    weak let weakController = controller
    await controller?.refresh()
    let reading = await waitForControllerCondition { await quota.count == 1 }
    XCTAssertTrue(reading)
    controller = nil
    XCTAssertNil(weakController)
    let terminated = await waitForControllerCondition { await source.termination.didTerminate }
    XCTAssertTrue(terminated)
    await quota.release(1)
    source.finish()
  }

  private func eventController(
    source: ControllerAccountEventSource,
    accounts: ControllerAccountReadPlan = .init([
      .init(isAuthenticated: true, accountID: "fixture", accountType: "chatgpt")
    ]),
    quota: ControllerQuotaReadPlan = .init([10])
  ) -> CodexConnectionController {
    let runtime = compatibleRuntime()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexControllerEvents-\(UUID().uuidString)")
    let service = CodexRuntimeSetupService(
      directory: root, release: .approved, download: { _, _ in }, validate: { _, _ in })
    return CodexConnectionController(
      service: service, inspect: { runtime }, readAccount: { await accounts.read() },
      readRateLimits: { await quota.read() }, accountEvents: { source.stream })
  }

  private func waitForControllerCondition(
    _ predicate: @MainActor () async -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !(await predicate()) {
      guard clock.now < deadline else { return false }
      try? await clock.sleep(for: .milliseconds(1))
    }
    return true
  }
}

private final class ControllerAccountEventSource: Sendable {
  let stream: AsyncStream<CodexAppServerAccountEvent>
  let continuation: AsyncStream<CodexAppServerAccountEvent>.Continuation
  let termination = ControllerEventTermination()
  init() {
    let pair = AsyncStream<CodexAppServerAccountEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(16))
    stream = pair.stream
    continuation = pair.continuation
    continuation.onTermination = { [termination] _ in Task { await termination.mark() } }
  }
  func emit(_ event: CodexAppServerAccountEvent) { continuation.yield(event) }
  func finish() { continuation.finish() }
}

private actor ControllerEventTermination {
  private(set) var didTerminate = false
  func mark() { didTerminate = true }
}

private actor ControllerAccountReadPlan {
  private let accounts: [CodexAppServerAccountStatus]
  private let holding: Set<Int>
  private var releases: Set<Int> = []
  private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
  private(set) var count = 0
  init(_ accounts: [CodexAppServerAccountStatus], holding: Set<Int> = []) {
    self.accounts = accounts
    self.holding = holding
  }
  func read() async -> CodexAppServerAccountStatus {
    count += 1
    let index = count
    if holding.contains(index), !releases.contains(index) {
      await withCheckedContinuation { waiters[index] = $0 }
    }
    return accounts[min(index - 1, accounts.count - 1)]
  }
  func release(_ index: Int) {
    releases.insert(index)
    waiters.removeValue(forKey: index)?.resume()
  }
}

private actor ControllerQuotaReadPlan {
  private let values: [Double]
  private let holding: Set<Int>
  private var releases: Set<Int> = []
  private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
  private(set) var count = 0
  init(_ values: [Double], holding: Set<Int> = []) {
    self.values = values
    self.holding = holding
  }
  func read() async -> CodexAppServerRateLimits {
    count += 1
    let index = count
    if holding.contains(index), !releases.contains(index) {
      await withCheckedContinuation { waiters[index] = $0 }
    }
    return .init(primary: .init(usedPercent: values[min(index - 1, values.count - 1)]))
  }
  func release(_ index: Int) {
    releases.insert(index)
    waiters.removeValue(forKey: index)?.resume()
  }
}
