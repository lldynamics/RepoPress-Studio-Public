import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RepositoryGitIsolationSecurityTests: XCTestCase {
  func testSyncAndAsyncGitStatusDisableRepositoryFsmonitor() async throws {
    let rootURL = try temporaryDirectoryURL(prefix: "RepoPressGitIsolation")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try runGit(["init", "-b", "main"], rootURL: rootURL)

    let markerURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("RepoPressGitIsolationMarker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: markerURL) }
    let fsmonitorURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("RepoPressFsmonitor-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: fsmonitorURL) }
    let script = "#!/bin/sh\nprintf 'fsmonitor executed' > \(posixShellQuote(markerURL.path))\n"
    try script.write(to: fsmonitorURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fsmonitorURL.path
    )
    try runGit(["config", "core.fsmonitor", fsmonitorURL.path], rootURL: rootURL)

    let runner = GitCommandRunner()
    let syncResult = runSync(
      ["status", "--porcelain=v1", "--branch"],
      with: runner,
      rootURL: rootURL
    )
    XCTAssertEqual(syncResult.terminationStatus, 0, syncResult.output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

    let asyncResult = await runner.runAsync(
      ["status", "--porcelain=v1", "--branch"],
      rootURL: rootURL
    )
    XCTAssertEqual(asyncResult.terminationStatus, 0, asyncResult.output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

    let syncWorkTree = runSync(
      ["rev-parse", "--is-inside-work-tree"],
      with: runner,
      rootURL: rootURL
    )
    XCTAssertEqual(syncWorkTree.terminationStatus, 0)
    XCTAssertEqual(syncWorkTree.standardOutput, "true")
    let asyncWorkTree = await runner.runAsync(
      ["rev-parse", "--is-inside-work-tree"],
      rootURL: rootURL
    )
    XCTAssertEqual(asyncWorkTree.terminationStatus, 0)
    XCTAssertEqual(asyncWorkTree.standardOutput, "true")
  }

  func testSyncAndAsyncAutomaticCommitsSkipRepositoryHooks() async throws {
    let rootURL = try temporaryDirectoryURL(prefix: "RepoPressGitHooks")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try runGit(["init", "-b", "main"], rootURL: rootURL)
    try runGit(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try runGit(["config", "user.name", "Tests"], rootURL: rootURL)
    try "seed\n".write(
      to: rootURL.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    try runGit(["add", "README.md"], rootURL: rootURL)
    try runGit(["commit", "-m", "Initial"], rootURL: rootURL)

    let markerURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("RepoPressGitHookMarker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: markerURL) }
    let hook = "#!/bin/sh\nprintf 'hook executed' >> \(posixShellQuote(markerURL.path))\nexit 1\n"
    for hookName in ["pre-commit", "commit-msg", "post-commit"] {
      let hookURL = rootURL.appendingPathComponent(".git/hooks/\(hookName)")
      try hook.write(to: hookURL, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
    }

    var profile = SiteProfile.defaultProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let service = LocalGitPublishService()

    let syncResult = try service.publish(
      package: makePackage(path: "content/posts/sync.md", body: "sync body\n"),
      profile: profile,
      mode: .directCommit
    )
    XCTAssertFalse(syncResult.commitSHA.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

    let asyncResult = try await service.publishAsync(
      package: makePackage(path: "content/posts/async.md", body: "async body\n"),
      profile: profile,
      mode: .directCommit
    )
    XCTAssertFalse(asyncResult.commitSHA.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    XCTAssertEqual(try runGit(["status", "--porcelain"], rootURL: rootURL), "")
  }

  func testRepositoryCleanFilterCannotExecuteDuringStatusOrDiff() throws {
    let rootURL = try makeTrackedRepository(prefix: "RepoPressGitFilter")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let markerURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("RepoPressGitFilterMarker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: markerURL) }
    let filterURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("RepoPressGitFilter-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: filterURL) }
    let filter = "#!/bin/sh\n/bin/cat\n/usr/bin/touch \(posixShellQuote(markerURL.path))\n"
    try filter.write(to: filterURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: filterURL.path)
    try runGit(["config", "filter.untrusted.clean", filterURL.path], rootURL: rootURL)
    try "*.txt filter=untrusted\n".write(
      to: rootURL.appendingPathComponent(".gitattributes"),
      atomically: true,
      encoding: .utf8
    )
    try "changed\n".write(
      to: rootURL.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )

    let result = GitCommandRunner().run(
      ["status", "--porcelain=v1", "--branch"],
      rootURL: rootURL
    )

    XCTAssertNotEqual(result.terminationStatus, 0, result.output)
    XCTAssertTrue(result.output.contains("Git command blocked"), result.output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

    let diffResult = GitCommandRunner().run(
      ["diff", "--", "tracked.txt"],
      rootURL: rootURL
    )
    XCTAssertNotEqual(diffResult.terminationStatus, 0, diffResult.output)
    XCTAssertTrue(diffResult.output.contains("Git command blocked"), diffResult.output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
  }

  func testRepositoryExternalDiffCannotExecuteDuringScanDiff() throws {
    let rootURL = try makeTrackedRepository(prefix: "RepoPressGitDiff")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let markerURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("RepoPressGitDiffMarker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: markerURL) }
    let diffURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("RepoPressGitDiff-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: diffURL) }
    let externalDiff = "#!/bin/sh\n/usr/bin/touch \(posixShellQuote(markerURL.path))\nexit 0\n"
    try externalDiff.write(to: diffURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: diffURL.path)
    try runGit(["config", "diff.external", diffURL.path], rootURL: rootURL)
    try "changed\n".write(
      to: rootURL.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )

    let result = GitCommandRunner().run(
      ["diff", "--", "tracked.txt"],
      rootURL: rootURL
    )

    XCTAssertNotEqual(result.terminationStatus, 0, result.output)
    XCTAssertTrue(result.output.contains("Git command blocked"), result.output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
  }

  func testRepositoryConfigIncludeCannotInjectExecutableSettings() throws {
    let rootURL = try makeTrackedRepository(prefix: "RepoPressGitInclude")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let markerURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("RepoPressGitIncludeMarker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: markerURL) }
    let fsmonitorURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("RepoPressGitIncludeFsmonitor-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: fsmonitorURL) }
    let injectedConfigURL = rootURL.deletingLastPathComponent()
      .appendingPathComponent("RepoPressGitInjectedConfig-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: injectedConfigURL) }
    let script =
      "#!/bin/sh\nprintf 'included config executed' > \(posixShellQuote(markerURL.path))\n"
    try script.write(to: fsmonitorURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fsmonitorURL.path)
    try "[core]\n\tfsmonitor = \(fsmonitorURL.path)\n"
      .write(to: injectedConfigURL, atomically: true, encoding: .utf8)
    try runGit(["config", "include.path", injectedConfigURL.path], rootURL: rootURL)

    let result = GitCommandRunner().run(
      ["status", "--porcelain=v1", "--branch"],
      rootURL: rootURL
    )

    XCTAssertNotEqual(result.terminationStatus, 0, result.output)
    XCTAssertTrue(result.output.contains("include"), result.output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
  }

  private func makePackage(path: String, body: String) -> PublishPackage {
    PublishPackage(
      draftID: UUID(),
      title: "Git isolation",
      markdownPath: path,
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: path,
          content: body
        )
      ],
      commitMessage: "Git isolation",
      reviewBranchName: "git-isolation",
      reviewTitle: "Git isolation",
      reviewChecklist: []
    )
  }

  private func makeTrackedRepository(prefix: String) throws -> URL {
    let rootURL = try temporaryDirectoryURL(prefix: prefix)
    try runGit(["init", "-b", "main"], rootURL: rootURL)
    try runGit(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try runGit(["config", "user.name", "Tests"], rootURL: rootURL)
    try "baseline\n".write(
      to: rootURL.appendingPathComponent("tracked.txt"),
      atomically: true,
      encoding: .utf8
    )
    try runGit(["add", "tracked.txt"], rootURL: rootURL)
    try runGit(["commit", "-m", "Initial"], rootURL: rootURL)
    return rootURL
  }

  @discardableResult
  private func runGit(_ arguments: [String], rootURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", rootURL.path] + arguments
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let output =
      String(
        data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    let error =
      String(
        data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "RepositoryGitIsolationSecurityTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: output + error]
      )
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private func runSync(
  _ arguments: [String],
  with runner: GitCommandRunner,
  rootURL: URL
) -> GitCommandResult {
  runner.run(arguments, rootURL: rootURL)
}
