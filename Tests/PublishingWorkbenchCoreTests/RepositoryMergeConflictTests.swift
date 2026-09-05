import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class RepositoryMergeConflictTests: XCTestCase {
  func testScansGitStagesAndStagesExpectedFinalText() throws {
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
    let expectation = try XCTUnwrap(conflict.resolutionExpectation)

    let unresolvedIndex = try runGit(["ls-files", "-u", "-z"], rootURL: rootURL)
    XCTAssertThrowsError(
      try service.resolveMergeConflict(
        profile: profile,
        request: .init(
          expectation: expectation,
          resolution: .finalText(try XCTUnwrap(conflict.final.text))
        )
      )
    ) { error in
      XCTAssertEqual(error as? RepositoryMergeConflictError, .unresolvedConflictMarkers)
    }
    XCTAssertEqual(try runGit(["ls-files", "-u", "-z"], rootURL: rootURL), unresolvedIndex)

    let finalText = "title\nresolved\n\n"
    try service.resolveMergeConflict(
      profile: profile,
      request: .init(expectation: expectation, resolution: .finalText(finalText))
    )

    XCTAssertEqual(try runGit(["ls-files", "-u", "-z"], rootURL: rootURL), "")
    XCTAssertEqual(
      try String(
        decoding: Data(contentsOf: rootURL.appendingPathComponent(conflict.repositoryPath)),
        as: UTF8.self),
      finalText
    )
    XCTAssertTrue(service.mergeConflictSession(profile: profile).isEmpty)
  }

  func testExpectationRejectsPathsOutsideRepository() {
    XCTAssertNil(
      RepositoryMergeConflictExpectation(
        repositoryPath: "../outside.txt",
        stageEntries: [],
        finalContent: .missing(),
        workingTreeContentSHA: nil
      )
    )
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
      request: .init(
        expectation: try XCTUnwrap(conflict.resolutionExpectation),
        resolution: .finalText("explicit merged result\n")
      )
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
        request: .init(
          expectation: try XCTUnwrap(conflict.resolutionExpectation),
          resolution: .finalText("manual text")
        )
      )
    ) { error in
      XCTAssertEqual(error as? RepositoryMergeConflictError, .unsupportedBinaryContent)
    }
    XCTAssertFalse(try runGit(["ls-files", "-u", "-z"], rootURL: rootURL).isEmpty)
  }

  func testExternalWorkingTreeEditRejectsExpectationAndPreservesExternalContent() throws {
    let rootURL = try makeTextConflictRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let profile = SiteProfile(name: "Conflict Test", localRepositoryRootPath: rootURL.path)
    let service = LocalRepositoryService()
    let conflict = try XCTUnwrap(service.mergeConflictSession(profile: profile).conflicts.first)
    let path = rootURL.appendingPathComponent(conflict.repositoryPath)
    let externalText = "title\nexternal edit\n"
    try write(externalText, to: path)

    XCTAssertThrowsError(
      try service.resolveMergeConflict(
        profile: profile,
        request: .init(
          expectation: try XCTUnwrap(conflict.resolutionExpectation),
          resolution: .finalText("title\nresolved\n")
        )
      )
    ) { error in
      XCTAssertEqual(error as? RepositoryMergeConflictError, .repositoryChanged)
    }
    XCTAssertEqual(try String(decoding: Data(contentsOf: path), as: UTF8.self), externalText)
    XCTAssertFalse(try runGit(["ls-files", "-u", "-z"], rootURL: rootURL).isEmpty)
  }

  func testChangedStageObjectRejectsExpectation() throws {
    let rootURL = try makeTextConflictRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let profile = SiteProfile(name: "Conflict Test", localRepositoryRootPath: rootURL.path)
    let service = LocalRepositoryService()
    let conflict = try XCTUnwrap(service.mergeConflictSession(profile: profile).conflicts.first)
    let baseSHA = try runGit(["rev-parse", ":1:\(conflict.repositoryPath)"], rootURL: rootURL)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try runGit(
      ["update-index", "--index-info"],
      rootURL: rootURL,
      input: "100644 \(baseSHA) 2\t\(conflict.repositoryPath)\n"
    )

    XCTAssertThrowsError(
      try service.resolveMergeConflict(
        profile: profile,
        request: .init(
          expectation: try XCTUnwrap(conflict.resolutionExpectation),
          resolution: .finalText("title\nresolved\n")
        )
      )
    ) { error in
      XCTAssertEqual(error as? RepositoryMergeConflictError, .repositoryChanged)
    }
    XCTAssertFalse(try runGit(["ls-files", "-u", "-z"], rootURL: rootURL).isEmpty)
  }

  func testModifyDeleteConflictCanBeExplicitlyDeleted() throws {
    let rootURL = try makeModifyDeleteConflictRepository(binary: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let profile = SiteProfile(name: "Conflict Test", localRepositoryRootPath: rootURL.path)
    let service = LocalRepositoryService()
    let conflict = try XCTUnwrap(service.mergeConflictSession(profile: profile).conflicts.first)
    XCTAssertTrue(conflict.isModifyDeleteConflict)
    XCTAssertTrue(conflict.canResolveByDeleting)

    try service.resolveMergeConflict(
      profile: profile,
      request: .init(
        expectation: try XCTUnwrap(conflict.resolutionExpectation),
        resolution: .delete
      )
    )
    XCTAssertTrue(service.mergeConflictSession(profile: profile).isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent(conflict.repositoryPath).path))
  }

  func testNonDeleteConflictRejectsExplicitDeletion() throws {
    let rootURL = try makeTextConflictRepository()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let profile = SiteProfile(name: "Conflict Test", localRepositoryRootPath: rootURL.path)
    let service = LocalRepositoryService()
    let conflict = try XCTUnwrap(service.mergeConflictSession(profile: profile).conflicts.first)
    let indexBefore = try runGit(["ls-files", "-u", "-z"], rootURL: rootURL)

    XCTAssertThrowsError(
      try service.resolveMergeConflict(
        profile: profile,
        request: .init(
          expectation: try XCTUnwrap(conflict.resolutionExpectation),
          resolution: .delete
        )
      )
    ) { error in
      XCTAssertEqual(error as? RepositoryMergeConflictError, .deleteNotAllowed)
    }
    XCTAssertEqual(try runGit(["ls-files", "-u", "-z"], rootURL: rootURL), indexBefore)
  }

  func testDeleteGateRejectsUnsupportedModesAndUnexpectedStageShapes() {
    let path = "content/posts/article.md"
    let regularBase = indexEntry(.base, path: path, mode: "100644")
    let regularOurs = indexEntry(.ours, path: path, mode: "100755")
    let regularTheirs = indexEntry(.theirs, path: path, mode: "100644")

    XCTAssertTrue(conflict(path: path, entries: [regularBase, regularOurs]).canResolveByDeleting)
    XCTAssertTrue(conflict(path: path, entries: [regularBase, regularTheirs]).canResolveByDeleting)
    XCTAssertFalse(
      conflict(
        path: path,
        entries: [regularBase, indexEntry(.ours, path: path, mode: "120000")]
      ).canResolveByDeleting
    )
    XCTAssertFalse(
      conflict(
        path: path,
        entries: [regularBase, indexEntry(.theirs, path: path, mode: "160000")]
      ).canResolveByDeleting
    )
    XCTAssertFalse(
      conflict(path: path, entries: [regularOurs, regularTheirs]).canResolveByDeleting
    )
    XCTAssertFalse(
      conflict(path: path, entries: [regularBase, regularOurs, regularTheirs])
        .canResolveByDeleting
    )
  }

  func testBinaryModifyDeleteConflictCanBeExplicitlyDeleted() throws {
    let rootURL = try makeModifyDeleteConflictRepository(binary: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let profile = SiteProfile(name: "Conflict Test", localRepositoryRootPath: rootURL.path)
    let service = LocalRepositoryService()
    let conflict = try XCTUnwrap(service.mergeConflictSession(profile: profile).conflicts.first)
    XCTAssertFalse(conflict.canResolve)
    XCTAssertTrue(conflict.canResolveByDeleting)

    try service.resolveMergeConflict(
      profile: profile,
      request: .init(
        expectation: try XCTUnwrap(conflict.resolutionExpectation),
        resolution: .delete
      )
    )
    XCTAssertTrue(service.mergeConflictSession(profile: profile).isEmpty)
  }

  func testSameSizeExternalBinaryEditRejectsDeletionExpectation() throws {
    let rootURL = try makeModifyDeleteConflictRepository(binary: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let profile = SiteProfile(name: "Conflict Test", localRepositoryRootPath: rootURL.path)
    let service = LocalRepositoryService()
    let conflict = try XCTUnwrap(service.mergeConflictSession(profile: profile).conflicts.first)
    let fileURL = rootURL.appendingPathComponent(conflict.repositoryPath)
    let externalData = Data([0, 9, 9])
    try writeData(externalData, to: fileURL)

    XCTAssertThrowsError(
      try service.resolveMergeConflict(
        profile: profile,
        request: .init(
          expectation: try XCTUnwrap(conflict.resolutionExpectation),
          resolution: .delete
        )
      )
    ) { error in
      XCTAssertEqual(error as? RepositoryMergeConflictError, .repositoryChanged)
    }
    XCTAssertEqual(try Data(contentsOf: fileURL), externalData)
    XCTAssertFalse(try runGit(["ls-files", "-u", "-z"], rootURL: rootURL).isEmpty)
  }

  func testParsesNulDelimitedIndexRecordsWithStageOrdering() {
    let parser = RepositoryMergeConflictIndexParser()
    let sha = String(repeating: "a", count: 40)
    let output =
      [
        "100644 \(sha) 3\tcontent/posts/article.md",
        "100644 \(sha) 1\tcontent/posts/article.md",
        "100644 \(sha) 2\tcontent/posts/article.md",
      ].joined(separator: "\0") + "\0"

    let entries = parser.parse(output)
    XCTAssertEqual(entries.map(\.stage), [.theirs, .base, .ours])
    XCTAssertEqual(
      entries.map(\.repositoryPath), Array(repeating: "content/posts/article.md", count: 3))
  }

  private func makeTextConflictRepository() throws -> URL {
    let rootURL = try makeTemporaryRepository()
    try runGit(["init", "-q", "-b", "main"], rootURL: rootURL)
    try configureTestAuthor(rootURL: rootURL)
    let path = "content/posts/article.md"
    try write("title\nbase\n", to: rootURL.appendingPathComponent(path))
    try runGit(["add", "--", path], rootURL: rootURL)
    try runGit(["commit", "-q", "-m", "base"], rootURL: rootURL)

    try runGit(["switch", "-q", "-c", "feature"], rootURL: rootURL)
    try write("title\nremote\n", to: rootURL.appendingPathComponent(path))
    try runGit(["commit", "-q", "-am", "remote"], rootURL: rootURL)
    try runGit(["switch", "-q", "main"], rootURL: rootURL)
    try write("title\nlocal\n", to: rootURL.appendingPathComponent(path))
    try runGit(["commit", "-q", "-am", "local"], rootURL: rootURL)
    XCTAssertThrowsError(try runGit(["merge", "feature"], rootURL: rootURL))
    return rootURL
  }

  private func makeModifyDeleteConflictRepository(binary: Bool) throws -> URL {
    let rootURL = try makeTemporaryRepository()
    try runGit(["init", "-q", "-b", "main"], rootURL: rootURL)
    try configureTestAuthor(rootURL: rootURL)
    let path = binary ? "static/image.bin" : "content/posts/article.md"
    let fileURL = rootURL.appendingPathComponent(path)
    if binary {
      try writeData(Data([0, 1, 2]), to: fileURL)
    } else {
      try write("base\n", to: fileURL)
    }
    try runGit(["add", "--", path], rootURL: rootURL)
    try runGit(["commit", "-q", "-m", "base"], rootURL: rootURL)

    try runGit(["switch", "-q", "-c", "feature"], rootURL: rootURL)
    if binary {
      try writeData(Data([0, 3, 4]), to: fileURL)
    } else {
      try write("remote modification\n", to: fileURL)
    }
    try runGit(["commit", "-q", "-am", "modify"], rootURL: rootURL)
    try runGit(["switch", "-q", "main"], rootURL: rootURL)
    try runGit(["rm", "-q", "--", path], rootURL: rootURL)
    try runGit(["commit", "-q", "-m", "delete"], rootURL: rootURL)
    XCTAssertThrowsError(try runGit(["merge", "feature"], rootURL: rootURL))
    return rootURL
  }

  private func configureTestAuthor(rootURL: URL) throws {
    try runGit(["config", "user.name", "Conflict Test"], rootURL: rootURL)
    try runGit(["config", "user.email", "conflict@example.invalid"], rootURL: rootURL)
  }

  private func conflict(
    path: String,
    entries: [RepositoryMergeConflictIndexEntry]
  ) -> RepositoryMergeConflict {
    RepositoryMergeConflict(
      repositoryPath: path,
      base: .text("base\n"),
      ours: .text("ours\n"),
      theirs: .missing(),
      final: .text("ours\n"),
      stageEntries: entries,
      workingTreeContentSHA: "working-tree-sha"
    )
  }

  private func indexEntry(
    _ stage: RepositoryMergeConflictStage,
    path: String,
    mode: String
  ) -> RepositoryMergeConflictIndexEntry {
    RepositoryMergeConflictIndexEntry(
      mode: mode,
      objectSHA: "object-\(stage.rawValue)",
      stage: stage,
      repositoryPath: path
    )
  }

  private func makeTemporaryRepository() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "RepositoryMergeConflictTests-" + UUID().uuidString, isDirectory: true)
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
  private func runGit(
    _ arguments: [String],
    rootURL: URL,
    input: String? = nil
  ) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", rootURL.path] + arguments
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let inputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    if input != nil {
      process.standardInput = inputPipe
    }
    try process.run()
    if let input {
      inputPipe.fileHandleForWriting.write(Data(input.utf8))
      try inputPipe.fileHandleForWriting.close()
    }
    process.waitUntilExit()
    let output =
      String(
        data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    guard process.terminationStatus == 0 else {
      let error =
        String(
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
