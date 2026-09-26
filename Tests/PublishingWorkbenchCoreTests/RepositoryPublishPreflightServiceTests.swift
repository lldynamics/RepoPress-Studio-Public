import Darwin
import Foundation
import XCTest
import os

@testable import PublishingWorkbenchCore

final class RepositoryPublishPreflightServiceTests: XCTestCase {
  func testProductionRunnerReapsLeaderAndStopsTermIgnoringChildrenAfterTimeout() throws {
    let fixture = try makeZolaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let script = """
      trap '' TERM
      printf '%s' "$$" > leader.pid
      /bin/sh -c 'trap "" TERM; i=0; while [ "$i" -lt 100 ]; do printf x >> heartbeat; /bin/sleep 0.05; i=$((i+1)); done' &
      wait
      """
    let result = RepositoryPublishPreflightCommandRunner.production.run(
      .init(
        stage: .build, executablePath: "/bin/sh", arguments: ["-c", script],
        workingDirectoryPath: fixture.root.path, timeout: 1, maximumOutputBytes: 1_024))

    XCTAssertEqual(result.termination, .timedOut)
    let pidText = try String(
      contentsOf: fixture.root.appendingPathComponent("leader.pid"), encoding: .utf8)
    let leader = try XCTUnwrap(Int32(pidText))
    XCTAssertEqual(Darwin.kill(leader, 0), -1, "The runner must reap its leader before returning")
    XCTAssertEqual(errno, ESRCH)
    let heartbeatURL = fixture.root.appendingPathComponent("heartbeat")
    let heartbeat = try Data(contentsOf: heartbeatURL)
    XCTAssertFalse(heartbeat.isEmpty)
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertEqual(
      try Data(contentsOf: heartbeatURL), heartbeat, "Children must stop writing after timeout")
  }

  func testProductionRunnerStopsChildrenHoldingOutputAfterLeaderExits() throws {
    let fixture = try makeZolaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let script = """
      /bin/sh -c 'trap "" TERM; i=0; while [ "$i" -lt 100 ]; do printf x >> heartbeat; printf x; /bin/sleep 0.05; i=$((i+1)); done' &
      while [ ! -s heartbeat ]; do /bin/sleep 0.01; done
      exit 7
      """
    let result = RepositoryPublishPreflightCommandRunner.production.run(
      .init(
        stage: .build, executablePath: "/bin/sh", arguments: ["-c", script],
        workingDirectoryPath: fixture.root.path, timeout: 2, maximumOutputBytes: 1_024))
    XCTAssertEqual(result.termination, .exited)
    XCTAssertEqual(result.exitStatus, 7)
    let heartbeatURL = fixture.root.appendingPathComponent("heartbeat")
    let heartbeat = try Data(contentsOf: heartbeatURL)
    XCTAssertFalse(heartbeat.isEmpty)
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertEqual(try Data(contentsOf: heartbeatURL), heartbeat)
  }

  func testProductionRunnerPreservesWorkingDirectoryOutputAndExitStatus() throws {
    let fixture = try makeZolaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let result = RepositoryPublishPreflightCommandRunner.production.run(
      .init(
        stage: .check, executablePath: "/bin/sh",
        arguments: ["-c", "pwd; printf 'standard output'; printf 'standard error' >&2; exit 7"],
        workingDirectoryPath: fixture.root.path, timeout: 5, maximumOutputBytes: 4_096))

    XCTAssertEqual(result.termination, .exited)
    XCTAssertEqual(result.exitStatus, 7)
    XCTAssertTrue(result.standardOutput.contains(fixture.root.resolvingSymlinksInPath().path))
    XCTAssertTrue(result.standardOutput.contains("standard output"))
    XCTAssertTrue(result.standardOutput.contains("standard error"))
  }

  func testProductionRunnerBoundsContinuousOutputAndFailsMissingExecutable() throws {
    let fixture = try makeZolaFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let result = RepositoryPublishPreflightCommandRunner.production.run(
      .init(
        stage: .build, executablePath: "/usr/bin/yes", arguments: [],
        workingDirectoryPath: fixture.root.path, timeout: 5, maximumOutputBytes: 1_024))
    XCTAssertEqual(result.termination, .outputTruncated)
    XCTAssertEqual(result.standardOutput.lengthOfBytes(using: .utf8), 1_024)

    let missing = RepositoryPublishPreflightCommandRunner.production.run(
      .init(
        stage: .build, executablePath: fixture.root.appendingPathComponent("missing-tool").path,
        arguments: [], workingDirectoryPath: fixture.root.path, timeout: 1,
        maximumOutputBytes: 1_024))
    XCTAssertEqual(missing.termination, .launchFailed)
  }

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

  func testUnsupportedProfileSkipsWithoutRunningCommands() {
    var profile = SiteProfile(name: "Other", siteKind: .nextJS)
    profile.localRepositoryRootPath = "/does-not-need-to-exist"
    let recorder = CommandRecorder(results: [])

    let result = makeService(recorder: recorder).run(profile: profile)

    XCTAssertEqual(result.outcome, .skipped(.unsupportedSiteKind))
    XCTAssertFalse(result.blocksPublication)
    XCTAssertTrue(recorder.commands.isEmpty)
  }

  func testAdditionalEnginesRunOnlyInStagedRepository() throws {
    let expectations: [(SiteKind, String, [RepositoryPublishPreflightCommand.Stage])] = [
      (.hugo, "hugo.toml", [.check, .build]),
      (.astro, "package.json", [.check, .build]),
      (.vitePress, "package.json", [.build]),
      (.hexo, "_config.yml", [.build]),
      (.jekyll, "Gemfile", [.build]),
      (.quartz, "quartz.config.ts", [.build]),
      (.docusaurus, "docusaurus.config.js", [.build]),
      (.mkDocs, "mkdocs.yml", [.build]),
    ]
    for (kind, config, stages) in expectations {
      let fixture = try makeAdditionalFixture(kind: kind, config: config)
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      let recorder = CommandRecorder(results: stages.map { _ in success() })
      let service = RepositoryPublishPreflightService(
        commandRunner: recorder.runner,
        temporaryDirectory: { fixture.base },
        trustedExecutable: { "/usr/bin/\($0)" }
      )

      let result = service.run(profile: fixture.profile)

      XCTAssertEqual(result.outcome, .passed, "\(kind)")
      XCTAssertEqual(recorder.commands.map(\.stage), stages, "\(kind)")
      for command in recorder.commands {
        XCTAssertTrue(command.workingDirectoryPath.hasPrefix(fixture.base.path + "/RepoPress-"))
        XCTAssertFalse(command.workingDirectoryPath.hasPrefix(fixture.root.path + "/"))
        XCTAssertEqual(command.environmentOverrides["CI"], "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: command.workingDirectoryPath))
      }
    }
  }

  func testAdditionalEngineCommandsUseNonDeployBuilds() throws {
    let cases: [(SiteKind, String, [String])] = [
      (.hugo, "hugo.toml", ["-e", "production"]),
      (.astro, "package.json", ["build", "--outDir"]),
      (.vitePress, "package.json", ["build", "docs", "--outDir"]),
      (.hexo, "_config.yml", ["generate", "--bail"]),
      (.jekyll, "Gemfile", ["exec", "jekyll", "build", "--destination"]),
      (.quartz, "quartz.config.ts", ["build", "--output"]),
      (.docusaurus, "docusaurus.config.js", ["build", "--out-dir"]),
      (.mkDocs, "mkdocs.yml", ["build", "--strict", "--site-dir"]),
    ]
    for (kind, config, requiredSequence) in cases {
      let fixture = try makeAdditionalFixture(kind: kind, config: config)
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      let recorder = CommandRecorder(results: [success(), success()])
      let service = RepositoryPublishPreflightService(
        commandRunner: recorder.runner,
        temporaryDirectory: { fixture.base },
        trustedExecutable: { "/usr/bin/\($0)" }
      )

      XCTAssertEqual(service.run(profile: fixture.profile).outcome, .passed)
      let build = try XCTUnwrap(recorder.commands.last)
      XCTAssertTrue(
        build.arguments.joined(separator: " ").contains(requiredSequence.joined(separator: " ")))
      XCTAssertFalse(build.arguments.contains("deploy"))
      if kind == .astro {
        XCTAssertEqual(Array(recorder.commands.first?.arguments.suffix(1) ?? []), ["check"])
      }
    }
  }

  func testMissingEngineDependencyBlocksPublication() throws {
    let fixture = try makeAdditionalFixture(kind: .astro, config: "package.json")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try FileManager.default.removeItem(
      at: fixture.root.appendingPathComponent("node_modules/.bin/astro"))
    let recorder = CommandRecorder(results: [])
    let service = RepositoryPublishPreflightService(
      commandRunner: recorder.runner,
      trustedExecutable: { "/usr/bin/\($0)" }
    )

    let result = service.run(profile: fixture.profile)

    XCTAssertEqual(result.outcome, .failed(.dependencyUnavailable))
    XCTAssertTrue(result.blocksPublication)
    XCTAssertTrue(recorder.commands.isEmpty)
  }

  func testMissingEngineConfigurationBlocksPublication() throws {
    let fixture = try makeAdditionalFixture(kind: .hugo, config: "hugo.toml")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("hugo.toml"))
    let recorder = CommandRecorder(results: [])
    let service = RepositoryPublishPreflightService(
      commandRunner: recorder.runner,
      trustedExecutable: { "/usr/bin/\($0)" }
    )

    let result = service.run(profile: fixture.profile)

    XCTAssertEqual(result.outcome, .failed(.configurationUnavailable))
    XCTAssertTrue(recorder.commands.isEmpty)
  }

  func testAdditionalEngineRejectsTemporaryDirectoryInsideRepository() throws {
    let fixture = try makeAdditionalFixture(kind: .hugo, config: "hugo.toml")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let recorder = CommandRecorder(results: [])
    let service = RepositoryPublishPreflightService(
      commandRunner: recorder.runner,
      temporaryDirectory: { fixture.root },
      trustedExecutable: { "/usr/bin/\($0)" }
    )

    let result = service.run(profile: fixture.profile)

    XCTAssertEqual(result.outcome, .failed(.temporaryOutputUnavailable))
    XCTAssertTrue(recorder.commands.isEmpty)
  }

  func testAdditionalEngineCheckFailureStopsBeforeBuild() throws {
    let fixture = try makeAdditionalFixture(kind: .astro, config: "package.json")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let recorder = CommandRecorder(results: [failure("front matter syntax error")])
    let service = RepositoryPublishPreflightService(
      commandRunner: recorder.runner,
      temporaryDirectory: { fixture.base },
      trustedExecutable: { "/usr/bin/\($0)" }
    )

    let result = service.run(profile: fixture.profile)

    XCTAssertEqual(result.outcome, .failed(.checkFailed))
    XCTAssertEqual(recorder.commands.map(\.stage), [.check])
    XCTAssertEqual(result.diagnostics, ["front matter syntax error"])
  }

  func testEscapingSymlinkCannotRunAgainstOriginalOrExternalTree() throws {
    let fixture = try makeAdditionalFixture(kind: .astro, config: "package.json")
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appendingPathComponent("external"),
      withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
    )
    let recorder = CommandRecorder(results: [])
    let service = RepositoryPublishPreflightService(
      commandRunner: recorder.runner,
      temporaryDirectory: { fixture.base },
      trustedExecutable: { "/usr/bin/\($0)" }
    )

    let result = service.run(profile: fixture.profile)

    XCTAssertEqual(result.outcome, .failed(.unsafeRepositoryLink))
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

  private func makeAdditionalFixture(
    kind: SiteKind,
    config: String
  ) throws -> (base: URL, root: URL, profile: SiteProfile) {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("repopress-engine-preflight-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("site", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: root.appendingPathComponent(config))
    if kind == .vitePress {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("docs", isDirectory: true),
        withIntermediateDirectories: true
      )
    }
    if kind == .quartz {
      let cliDirectory = root.appendingPathComponent("quartz", isDirectory: true)
      try FileManager.default.createDirectory(at: cliDirectory, withIntermediateDirectories: true)
      try Data("// Quartz 4 CLI\n".utf8).write(
        to: cliDirectory.appendingPathComponent("bootstrap-cli.mjs")
      )
    }
    let cli: String?
    switch kind {
    case .astro: cli = "astro"
    case .vitePress: cli = "vitepress"
    case .hexo: cli = "hexo"
    case .docusaurus: cli = "docusaurus"
    default: cli = nil
    }
    if let cli {
      let bin = root.appendingPathComponent("node_modules/.bin", isDirectory: true)
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      try Data("#!/usr/bin/env node\n".utf8).write(to: bin.appendingPathComponent(cli))
    }
    var profile = SiteProfile(name: "Test \(kind)", siteKind: kind)
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
