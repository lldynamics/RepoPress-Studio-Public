import Foundation
import XCTest
import os

@testable import PublishingWorkbenchCore

final class RepositoryPublishPreflightServiceTests: XCTestCase {
  func testPassesCheckAndBuildInRepositoryExternalTemporaryDirectory() throws {
    let fixture = try makeZolaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let recorder = CommandRecorder(results: [success(), success()])

    let result = makeService(recorder: recorder, temporaryDirectory: fixture.base).run(
      profile: fixture.profile)

    XCTAssertEqual(result.outcome, .passed)
    XCTAssertFalse(result.blocksPublication)
    XCTAssertEqual(recorder.commands.map(\.stage), [.check, .build])
    XCTAssertEqual(recorder.commands[0].arguments, ["check", "--skip-external-links"])
    XCTAssertEqual(
      Array(recorder.commands[1].arguments.prefix(4)),
      ["build", "--force", "--minify", "--output-dir"]
    )
    let outputPath = recorder.commands[1].arguments[4]
    XCTAssertFalse(outputPath.hasPrefix(fixture.root.path + "/"))
    XCTAssertTrue(outputPath.hasPrefix(fixture.base.path + "/RepoPress-Zola-Preflight-"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outputPath))
  }

  func testMissingTrustedZolaFailsClosed() throws {
    let fixture = try makeZolaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let recorder = CommandRecorder(results: [])

    let result = RepositoryPublishPreflightService(
      commandRunner: recorder.runner,
      trustedZolaExecutable: { nil }
    ).run(profile: fixture.profile)

    XCTAssertEqual(result.outcome, .failed(.zolaUnavailable))
    XCTAssertTrue(result.blocksPublication)
    XCTAssertTrue(recorder.commands.isEmpty)
  }

  func testCheckFailureStopsBeforeBuild() throws {
    let fixture = try makeZolaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let recorder = CommandRecorder(results: [failure("invalid front matter")])

    let result = makeService(recorder: recorder).run(profile: fixture.profile)

    XCTAssertEqual(result.outcome, .failed(.checkFailed))
    XCTAssertEqual(recorder.commands.map(\.stage), [.check])
    XCTAssertEqual(result.diagnostics, ["invalid front matter"])
  }

  func testBuildFailureFailsClosedAfterCheck() throws {
    let fixture = try makeZolaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let recorder = CommandRecorder(results: [success(), failure("template error")])

    let result = makeService(recorder: recorder).run(profile: fixture.profile)

    XCTAssertEqual(result.outcome, .failed(.buildFailed))
    XCTAssertEqual(recorder.commands.map(\.stage), [.check, .build])
  }

  func testTimeoutFailsClosed() throws {
    let fixture = try makeZolaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let recorder = CommandRecorder(results: [success(), .init(termination: .timedOut)])

    let result = makeService(recorder: recorder).run(profile: fixture.profile)

    XCTAssertEqual(result.outcome, .failed(.timedOut))
    XCTAssertTrue(result.blocksPublication)
  }

  func testTruncatedOutputFailsClosedAndSanitizesSecrets() throws {
    let fixture = try makeZolaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let recorder = CommandRecorder(results: [
      success(),
      .init(termination: .outputTruncated, standardError: "token=should-not-appear"),
    ])

    let result = makeService(recorder: recorder).run(profile: fixture.profile)

    XCTAssertEqual(result.outcome, .failed(.outputTruncated))
    XCTAssertEqual(result.diagnostics, ["token=[已隐藏]"])
  }

  func testNonZolaProfileSkipsWithoutRunningCommands() {
    var profile = SiteProfile(name: "Other", siteKind: .hugo)
    profile.localRepositoryRootPath = "/does-not-need-to-exist"
    let recorder = CommandRecorder(results: [])

    let result = makeService(recorder: recorder).run(profile: profile)

    XCTAssertEqual(result.outcome, .skipped(.nonZolaProfile))
    XCTAssertFalse(result.blocksPublication)
    XCTAssertTrue(recorder.commands.isEmpty)
  }

  func testZolaProfileWithoutConfigurationSkipsExplicitly() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    var profile = SiteProfile(name: "No Config")
    profile.localRepositoryRootPath = base.path
    let recorder = CommandRecorder(results: [])

    let result = makeService(recorder: recorder).run(profile: profile)

    XCTAssertEqual(result.outcome, .skipped(.zolaConfigurationNotFound))
    XCTAssertTrue(recorder.commands.isEmpty)
  }

  func testRejectsTemporaryBuildDirectoryInsideRepository() throws {
    let fixture = try makeZolaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let recorder = CommandRecorder(results: [success()])

    let result = makeService(
      recorder: recorder,
      temporaryDirectory: fixture.root
    ).run(profile: fixture.profile)

    XCTAssertEqual(result.outcome, .failed(.temporaryOutputUnavailable))
    XCTAssertEqual(recorder.commands.map(\.stage), [.check])
  }

  private func makeService(
    recorder: CommandRecorder,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) -> RepositoryPublishPreflightService {
    RepositoryPublishPreflightService(
      commandRunner: recorder.runner,
      temporaryDirectory: { temporaryDirectory },
      trustedZolaExecutable: { "/usr/local/bin/zola" }
    )
  }

  private func makeZolaFixture() throws -> (base: URL, root: URL, profile: SiteProfile) {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("repopress-zola-preflight-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("base_url = \"https://example.com\"\n".utf8).write(
      to: root.appendingPathComponent("config.toml")
    )
    var profile = SiteProfile(name: "Test Zola", siteKind: .zola)
    profile.localRepositoryRootPath = root.path
    return (base, root, profile)
  }

  private func success() -> RepositoryPublishPreflightCommandResult {
    .init(termination: .exited, exitStatus: 0)
  }

  private func failure(_ text: String) -> RepositoryPublishPreflightCommandResult {
    .init(termination: .exited, exitStatus: 1, standardError: text)
  }
}

private struct CommandRecorderState {
  var queuedResults: [RepositoryPublishPreflightCommandResult]
  var commands: [RepositoryPublishPreflightCommand] = []
}

private final class CommandRecorder: Sendable {
  private let state: OSAllocatedUnfairLock<CommandRecorderState>

  init(results: [RepositoryPublishPreflightCommandResult]) {
    state = OSAllocatedUnfairLock(initialState: CommandRecorderState(queuedResults: results))
  }

  var commands: [RepositoryPublishPreflightCommand] {
    state.withLock { $0.commands }
  }

  var runner: RepositoryPublishPreflightCommandRunner {
    RepositoryPublishPreflightCommandRunner { [self] command in
      state.withLock { state in
        state.commands.append(command)
        guard !state.queuedResults.isEmpty else {
          return .init(termination: .launchFailed, standardError: "Unexpected command")
        }
        return state.queuedResults.removeFirst()
      }
    }
  }
}
