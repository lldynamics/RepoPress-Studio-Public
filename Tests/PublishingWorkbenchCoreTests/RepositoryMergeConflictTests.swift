import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RepositoryMergeConflictTests: XCTestCase {
  func testScansGitStagesAndStagesExplicitFinalText() throws {
    let rootURL = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try runGit(["init", "-q", "-b", "main"], rootURL: rootURL)
    try runGit(["config", "user.name", "Conflict Test"], rootURL: rootURL)
    try runGit(["config", "user.email", "conflict@example.invalid"], rootURL: rootURL)
    try write("title\nbase\n", to: rootURL.appendingPathComponent("content/posts/article.md"))
    try runGit(["add", "--", "content/posts/article.md"], rootURL: rootURL)
    try runGit(["commit", "-q", "-m", "base"], rootURL: rootURL)

    try runGit(["switch", "-q", "-c", "feature"], rootURL: rootURL)
    try write("title\nremote\n", to: rootURL.appendingPathComponent("content/posts/article.md"))
    try runGit(["commit", "-q", "-am", "remote"], rootURL: rootURL)
    try runGit(["switch", "-q", "main"], rootURL: rootURL)
    try write("title\nlocal\n", to: rootURL.appendingPathComponent("content/posts/article.md"))
    try runGit(["commit", "-q", "-am", "local"], rootURL: rootURL)
    XCTAssertThrowsError(try runGit(["merge", "feature"], rootURL: rootURL))

    let profile = SiteProfile(
      name: "Conflict Test",
      localRepositoryRootPath: rootURL.path
    )
    let service = LocalRepositoryService()
    let session = service.mergeConflictSession(profile: profile)

    XCTAssertEqual(session.conflicts.count, 1)
    let conflict = try XCTUnwrap(session.conflicts.first)
    XCTAssertEqual(conflict.repositoryPath, "content/posts/article.md")
    XCTAssertEqual(conflict.base.text, "title\nbase\n")
    XCTAssertEqual(conflict.ours.text, "title\nlocal\n")
    XCTAssertEqual(conflict.theirs.text, "title\nremote\n")
    XCTAssertTrue(conflict.final.text?.contains("<<<<<<<") == true)
    XCTAssertTrue(conflict.canResolve)

    let finalText = "title\nresolved\n\n"
    try service.resolveMergeConflict(
      profile: profile,
      repositoryPath: conflict.repositoryPath,
      finalContent: finalText
    )

    XCTAssertEqual(try runGit(["ls-files", "-u", "-z"], rootURL: rootURL), "")
    XCTAssertEqual(
      try String(decoding: Data(contentsOf: rootURL.appendingPathComponent(conflict.repositoryPath)), as: UTF8.self),
      finalText
    )
    XCTAssertTrue(service.mergeConflictSession(profile: profile).isEmpty)
  }

  func testRejectsPathsOutsideRepositoryAndDoesNotAutoResolve() throws {
    let service = LocalRepositoryService()
    let rootURL = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try runGit(["init", "-q", "-b", "main"], rootURL: rootURL)

    let profile = SiteProfile(name: "Conflict Test", localRepositoryRootPath: rootURL.path)
    XCTAssertThrowsError(
      try service.resolveMergeConflict(
        profile: profile,
        repositoryPath: "../outside.txt",
        finalContent: "unsafe"
      )
    ) { error in
      XCTAssertEqual(error as? RepositoryMergeConflictError, .unsafeRepositoryPath)
    }
  }

  func testModifyDeleteConflictCanKeepAnExplicitFinalText() throws {
    let rootURL = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try runGit(["init", "-q", "-b", "main"], rootURL: rootURL)
    try runGit(["config", "user.name", "Conflict Test"], rootURL: rootURL)
    try runGit(["config", "user.email", "conflict@example.invalid"], rootURL: rootURL)
    let path = "content/posts/article.md"
    try write("base\n", to: rootURL.appendingPathComponent(path))
    try runGit(["add", "--", path], rootURL: rootURL)
    try runGit(["commit", "-q", "-m", "base"], rootURL: rootURL)

    try runGit(["switch", "-q", "-c", "feature"], rootURL: rootURL)
    try write("remote modification\n", to: rootURL.appendingPathComponent(path))
    try runGit(["commit", "-q", "-am", "modify"], rootURL: rootURL)
    try runGit(["switch", "-q", "main"], rootURL: rootURL)
    try runGit(["rm", "-q", "--", path], rootURL: rootURL)
    try runGit(["commit", "-q", "-m", "delete"], rootURL: rootURL)
    XCTAssertThrowsError(try runGit(["merge", "feature"], rootURL: rootURL))

    let profile = SiteProfile(name: "Conflict Test", localRepositoryRootPath: rootURL.path)
    let service = LocalRepositoryService()
    let conflict = try XCTUnwrap(service.mergeConflictSession(profile: profile).conflicts.first)
    XCTAssertEqual(conflict.ours.kind, .missing)
    XCTAssertEqual(conflict.theirs.text, "remote modification\n")
    XCTAssertTrue(conflict.canResolve)

    try service.resolveMergeConflict(
      profile: profile,
      repositoryPath: path,
      finalContent: "explicit merged result\n"
    )
    XCTAssertTrue(service.mergeConflictSession(profile: profile).isEmpty)
  }

  func testBinaryConflictIsDiagnosticOnlyAndCannotBeOverwritten() throws {
    let rootURL = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try runGit(["init", "-q", "-b", "main"], rootURL: rootURL)
    try runGit(["config", "user.name", "Conflict Test"], rootURL: rootURL)
    try runGit(["config", "user.email", "conflict@example.invalid"], rootURL: rootURL)
    let path = rootURL.appendingPathComponent("static/image.bin")
    try writeData(Data([0, 1, 2]), to: path)
    try runGit(["add", "--", "static/image.bin"], rootURL: rootURL)
    try runGit(["commit", "-q", "-m", "base"], rootURL: rootURL)
    try runGit(["switch", "-q", "-c", "feature"], rootURL: rootURL)
    try writeData(Data([0, 3, 4]), to: path)
    try runGit(["commit", "-q", "-am", "remote binary"], rootURL: rootURL)
    try runGit(["switch", "-q", "main"], rootURL: rootURL)
    try writeData(Data([0, 5, 6]), to: path)
    try runGit(["commit", "-q", "-am", "local binary"], rootURL: rootURL)
    XCTAssertThrowsError(try runGit(["merge", "feature"], rootURL: rootURL))

    let profile = SiteProfile(name: "Conflict Test", localRepositoryRootPath: rootURL.path)
    let service = LocalRepositoryService()
    let conflict = try XCTUnwrap(service.mergeConflictSession(profile: profile).conflicts.first)
    XCTAssertTrue([.binary, .undecodable].contains(conflict.ours.kind))
    XCTAssertTrue([.binary, .undecodable].contains(conflict.theirs.kind))
    XCTAssertFalse(conflict.canResolve)
    XCTAssertThrowsError(
      try service.resolveMergeConflict(
        profile: profile,
        repositoryPath: conflict.repositoryPath,
        finalContent: "manual text"
      )
    ) { error in
      XCTAssertEqual(error as? RepositoryMergeConflictError, .unsupportedBinaryContent)
    }
    XCTAssertFalse(try runGit(["ls-files", "-u", "-z"], rootURL: rootURL).isEmpty)
  }

  func testParsesNulDelimitedIndexRecordsWithStageOrdering() {
    let parser = RepositoryMergeConflictIndexParser()
    let sha = String(repeating: "a", count: 40)
    let output = [
      "100644 \(sha) 3\tcontent/posts/article.md",
      "100644 \(sha) 1\tcontent/posts/article.md",
      "100644 \(sha) 2\tcontent/posts/article.md",
    ].joined(separator: "\0") + "\0"

    let entries = parser.parse(output)
    XCTAssertEqual(entries.map(\.stage), [.theirs, .base, .ours])
    XCTAssertEqual(entries.map(\.repositoryPath), Array(repeating: "content/posts/article.md", count: 3))
  }

  private func makeTemporaryRepository() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepositoryMergeConflictTests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url)
  }

  private func writeData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url)
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
    let output = String(
      data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
    guard process.terminationStatus == 0 else {
      let error = String(
        data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? "Git command failed"
      throw NSError(
        domain: "RepositoryMergeConflictTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: error]
      )
    }
    return output
  }
}
