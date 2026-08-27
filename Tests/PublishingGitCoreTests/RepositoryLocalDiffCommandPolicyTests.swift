import Testing

@testable import PublishingGitCore

struct RepositoryLocalDiffCommandPolicyTests {
  private let policy = RepositoryLocalDiffCommandPolicy()

  @Test(arguments: trackedKindCases)
  fileprivate func trackedSingleKindsUseStagedThenUnstagedLiteralCommands(
    for scenario: ChangeKindCase
  ) {
    let path = "content/posts/文章.md"
    let file = RepositoryChangedFile(status: "", path: path, kind: scenario.kind)

    #expect(
      policy.plan(for: file)?.argumentsInExecutionOrder == expectedTrackedArguments(for: path)
    )
  }

  @Test(arguments: renameAndCopyCases)
  fileprivate func renameAndCopyKeepSourceThenDestinationForBothCommands(
    for scenario: RenameCopyCase
  ) {
    let file = RepositoryChangedFile(
      status: scenario.status,
      sourcePath: scenario.source,
      destinationPath: scenario.destination,
      kind: scenario.kind
    )

    #expect(
      policy.plan(for: file)?.argumentsInExecutionOrder
        == expectedPairArguments(source: scenario.source, destination: scenario.destination)
    )
  }

  @Test(arguments: specialTrackedPaths)
  fileprivate func trackedPathsPreserveSpecialCharactersWithoutTrimming(
    for scenario: SpecialPathCase
  ) throws {
    let file = RepositoryChangedFile(status: " M", path: scenario.path, kind: .modified)
    let arguments = try #require(policy.plan(for: file)?.argumentsInExecutionOrder)

    #expect(arguments[0].last == ":(literal)\(scenario.path)")
    #expect(arguments[1].last == ":(literal)\(scenario.path)")
  }

  @Test
  func untrackedUsesRawFilesystemPathWithoutLiteralMagic() {
    let path = "content/posts/*?[]: \"未跟踪\" \\文件\n.md"
    let file = RepositoryChangedFile(status: "??", path: path, kind: .untracked)

    #expect(
      policy.plan(for: file)?.argumentsInExecutionOrder
        == [["diff", "--no-index", "--", "/dev/null", path]]
    )
  }

  @Test(arguments: invalidChangedFileCases)
  fileprivate func rejectsInvalidChangedFileShapes(for scenario: InvalidChangedFileCase) {
    #expect(policy.plan(for: scenario.file) == nil)
  }

  @Test(arguments: invalidUntrackedPaths)
  fileprivate func rejectsAbsoluteAndDotTraversalUntrackedPathsWithoutTrimming(
    for path: String
  ) {
    #expect(
      policy.plan(for: RepositoryChangedFile(status: "??", path: path, kind: .untracked)) == nil
    )
  }

  @Test
  func untrackedLeadingSpaceRemainsUntrimmed() {
    let leadingSpace = " content/posts/file.md "

    #expect(
      policy.plan(
        for: RepositoryChangedFile(status: "??", path: leadingSpace, kind: .untracked)
      )?.argumentsInExecutionOrder
        == [["diff", "--no-index", "--", "/dev/null", leadingSpace]]
    )
  }

  @Test
  func legacyRenameDisplayAndOrdinaryArrowFilenameRemainCompatible() {
    let rename = RepositoryChangedFile(
      status: "R100",
      path: "content/old.md -> content/new.md",
      kind: .renamed
    )
    let literalArrowFilename = RepositoryChangedFile(
      status: " M",
      path: "content/posts/name -> literal.md",
      kind: .modified
    )

    #expect(rename.sourcePath == "content/old.md")
    #expect(rename.destinationPath == "content/new.md")
    #expect(
      policy.plan(for: rename)?.argumentsInExecutionOrder[0].suffix(2)
        == [":(literal)content/old.md", ":(literal)content/new.md"]
    )
    #expect(
      policy.plan(for: literalArrowFilename)?.argumentsInExecutionOrder[0].last
        == ":(literal)content/posts/name -> literal.md"
    )
  }

  @Test
  func lineDiffDoesNotAffectPlanValueSemantics() throws {
    let file = RepositoryChangedFile(status: " M", path: "README.md", kind: .modified)
    var withDiff = file
    withDiff.lineDiff = "-old\n+new"

    let first = try #require(policy.plan(for: file))
    let second = try #require(policy.plan(for: withDiff))
    #expect(first == second)
    #expect(first.hashValue == second.hashValue)
    #expect(
      first
        == RepositoryLocalDiffCommandPlan(
          argumentsInExecutionOrder: first.argumentsInExecutionOrder)
    )
  }
}

private struct ChangeKindCase: Sendable, CustomStringConvertible {
  let name: String
  let kind: RepositoryChangeKind

  var description: String { name }
}

private let trackedKindCases = [
  ChangeKindCase(name: "modified", kind: .modified),
  ChangeKindCase(name: "added", kind: .added),
  ChangeKindCase(name: "deleted", kind: .deleted),
]

private struct RenameCopyCase: Sendable, CustomStringConvertible {
  let name: String
  let status: String
  let source: String
  let destination: String
  let kind: RepositoryChangeKind

  var description: String { name }
}

private let renameAndCopyCases = [
  RenameCopyCase(
    name: "renamed",
    status: "R100",
    source: "内容/旧 -> 源 \"稿\".md",
    destination: "内容/新 -> 目标\n稿.md",
    kind: .renamed
  ),
  RenameCopyCase(
    name: "copied",
    status: "C100",
    source: "内容/旧 -> 源 \"稿\".md",
    destination: "内容/新 -> 目标\n稿.md",
    kind: .other
  ),
]

private struct SpecialPathCase: Sendable, CustomStringConvertible {
  let name: String
  let path: String

  var description: String { name }
}

private let specialTrackedPaths = [
  SpecialPathCase(
    name: "unicode spaces quotes newline globs colon backslash",
    path: "内容/空 格/引号\"/换\n行 *?[]: \\文件.md"
  ),
  SpecialPathCase(name: "leading dash", path: "-leading.md"),
  SpecialPathCase(name: "absolute-looking", path: "/absolute-looking.md"),
  SpecialPathCase(name: "dot segments", path: "./dot/../literal.md"),
]

private struct InvalidChangedFileCase: Sendable, CustomStringConvertible {
  let name: String
  let file: RepositoryChangedFile

  var description: String { name }
}

private let invalidChangedFileCases = [
  InvalidChangedFileCase(
    name: "empty tracked path",
    file: RepositoryChangedFile(status: " M", path: "", kind: .modified)
  ),
  InvalidChangedFileCase(
    name: "tracked path containing NUL",
    file: RepositoryChangedFile(status: " M", path: "bad\0path", kind: .modified)
  ),
  InvalidChangedFileCase(
    name: "untracked source and destination pair",
    file: RepositoryChangedFile(
      status: "??",
      sourcePath: "old.md",
      destinationPath: "new.md",
      kind: .untracked
    )
  ),
  InvalidChangedFileCase(
    name: "renamed source path containing NUL",
    file: RepositoryChangedFile(
      status: "R",
      sourcePath: "old\0.md",
      destinationPath: "new.md",
      kind: .renamed
    )
  ),
]

private let invalidUntrackedPaths = [
  "/tmp/file.md",
  "./file.md",
  "content/./file.md",
  "content/../file.md",
  "content/posts/..",
]

private func expectedTrackedArguments(for path: String) -> [[String]] {
  [
    ["diff", "-M", "-C", "--cached", "--", ":(literal)\(path)"],
    ["diff", "-M", "-C", "--", ":(literal)\(path)"],
  ]
}

private func expectedPairArguments(source: String, destination: String) -> [[String]] {
  [
    [
      "diff", "-M", "-C", "--cached", "--",
      ":(literal)\(source)", ":(literal)\(destination)",
    ],
    [
      "diff", "-M", "-C", "--",
      ":(literal)\(source)", ":(literal)\(destination)",
    ],
  ]
}
