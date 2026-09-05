import XCTest

@testable import PublishingMarkdownCore

final class MarkdownThreeWayMergeServiceTests: XCTestCase {
  private let service = MarkdownThreeWayMergeService()

  func testAutomaticallyMergesDifferentYAMLFieldsWithoutRewritingTheBody() throws {
    let base = "---\ntitle: Base\ndescription: Old\n---\n\nBody\n"
    let local = "---\ntitle: Local\ndescription: Old\n---\n\nBody\n"
    let remote = "---\ntitle: Base\ndescription: Remote\n---\n\nBody\n"
    let plan = try ready(base: base, local: local, remote: remote)

    XCTAssertTrue(plan.frontMatterConflicts.isEmpty)
    XCTAssertEqual(
      plan.resolvedDocument(frontMatterChoices: [:], bodyChoices: [:]),
      "---\ntitle: Local\ndescription: Remote\n---\n\nBody\n"
    )
  }

  func testMakesSameFieldConflictExplicitAndSupportsAddDelete() throws {
    let base = "---\ntitle: Base\ndescription: Delete me\n---\nBody"
    let local = "---\ntitle: Local\n---\nBody"
    let remote = "---\ntitle: Remote\ndescription: Delete me\n---\nBody"
    let plan = try ready(base: base, local: local, remote: remote)

    XCTAssertEqual(plan.frontMatterConflicts.map(\.key), ["title"])
    XCTAssertNil(plan.resolvedDocument(frontMatterChoices: [:], bodyChoices: [:]))
    XCTAssertEqual(
      plan.resolvedDocument(frontMatterChoices: ["title": .remote], bodyChoices: [:]),
      "---\ntitle: Remote\n---\nBody"
    )
  }

  func testMakesDeleteVersusModifyFieldConflictExplicit() throws {
    let base = "---\ntitle: Base\ndescription: Old\n---\nBody"
    let local = "---\ntitle: Base\n---\nBody"
    let remote = "---\ntitle: Base\ndescription: Remote\n---\nBody"
    let plan = try ready(base: base, local: local, remote: remote)
    let conflict = try XCTUnwrap(plan.frontMatterConflicts.first)

    XCTAssertEqual(conflict.key, "description")
    XCTAssertNil(conflict.local)
    XCTAssertEqual(
      plan.resolvedDocument(
        frontMatterChoices: [conflict.id: .local],
        bodyChoices: [:]
      ),
      "---\ntitle: Base\n---\nBody"
    )
    XCTAssertEqual(
      plan.resolvedDocument(
        frontMatterChoices: [conflict.id: .remote],
        bodyChoices: [:]
      ),
      remote
    )
  }

  func testAutomaticallyMergesIndependentFieldAdditionsAndTOML() throws {
    let base = "+++\ntitle = \"Base\"\n+++\nText"
    let local = "+++\ntitle = \"Base\"\ndescription = \"Local\"\n+++\nText"
    let remote = "+++\ntitle = \"Base\"\ntags = [\"swift\", \"macos\"]\n+++\nText"
    let plan = try ready(base: base, local: local, remote: remote)

    XCTAssertEqual(
      plan.resolvedDocument(frontMatterChoices: [:], bodyChoices: [:]),
      "+++\ntitle = \"Base\"\ndescription = \"Local\"\ntags = [\"swift\", \"macos\"]\n+++\nText"
    )
  }

  func testRejectsUnsafeOrAmbiguousFrontMatter() {
    assertUnsupported(
      "---\ntitle: Base # comment\n---\nBody", reason: .unsupportedFrontMatterSyntax)
    assertUnsupported(
      "---\nunknown: value\n---\nBody", reason: .unsupportedFrontMatterKey("unknown"))
    assertUnsupported(
      "---\ntitle: One\ntitle: Two\n---\nBody", reason: .duplicateFrontMatterKey("title"))
    assertUnsupported(
      "---\ntitle: Base\n---\nBody", local: "+++\ntitle = \"Base\"\n+++\nBody",
      reason: .frontMatterPresenceOrDelimiterDiffers)
  }

  func testAutomaticallyMergesNonOverlappingBodyEdits() throws {
    let plan = try ready(
      base: "one\ntwo\nthree\n",
      local: "local one\ntwo\nthree\n",
      remote: "one\ntwo\nremote three\n"
    )

    XCTAssertTrue(plan.bodyConflicts.isEmpty)
    XCTAssertEqual(
      plan.resolvedDocument(frontMatterChoices: [:], bodyChoices: [:]),
      "local one\ntwo\nremote three\n")
  }

  func testAutomaticallyMergesIdenticalOverlappingBodyEdit() throws {
    let plan = try ready(base: "one\ntwo\n", local: "one\nshared\n", remote: "one\nshared\n")

    XCTAssertTrue(plan.bodyConflicts.isEmpty)
    XCTAssertEqual(
      plan.resolvedDocument(frontMatterChoices: [:], bodyChoices: [:]), "one\nshared\n")
  }

  func testBodyConflictRequiresChoiceAndCanKeepBothInAnExplicitOrder() throws {
    let plan = try ready(base: "one\ntwo\n", local: "one\nlocal\n", remote: "one\nremote\n")
    let conflict = try XCTUnwrap(plan.bodyConflicts.first)

    XCTAssertNil(plan.resolvedDocument(frontMatterChoices: [:], bodyChoices: [:]))
    XCTAssertEqual(
      plan.resolvedDocument(frontMatterChoices: [:], bodyChoices: [conflict.id: .local]),
      "one\nlocal\n")
    XCTAssertEqual(
      plan.resolvedDocument(frontMatterChoices: [:], bodyChoices: [conflict.id: .remote]),
      "one\nremote\n")
    XCTAssertEqual(
      plan.resolvedDocument(frontMatterChoices: [:], bodyChoices: [conflict.id: .both]),
      "one\nlocal\nremote\n")
  }

  func testPreservesSetextUnicodeAndTrailingNewline() throws {
    let source = "标题\n=====\n\n你好，世界\n"
    let plan = try ready(base: source, local: source, remote: source)

    XCTAssertEqual(plan.autoMergedFrontMatterFieldCount, 0)
    XCTAssertEqual(plan.resolvedDocument(frontMatterChoices: [:], bodyChoices: [:]), source)
  }

  func testPreservesAnUnchangedFrontMatterDocumentByteForByte() throws {
    let source = "---\ntitle: Base\ntags: [swift, macos]\n---\n\nBody\n"
    let plan = try ready(base: source, local: source, remote: source)

    XCTAssertEqual(plan.resolvedDocument(frontMatterChoices: [:], bodyChoices: [:]), source)
  }

  func testMakesSameAnchorAndEOFInsertionsExplicit() throws {
    let insertion = try ready(base: "base\n", local: "local\nbase\n", remote: "remote\nbase\n")
    let insertionConflict = try XCTUnwrap(insertion.bodyConflicts.first)
    XCTAssertEqual(
      insertion.resolvedDocument(
        frontMatterChoices: [:], bodyChoices: [insertionConflict.id: .both]),
      "local\nremote\nbase\n"
    )

    let eof = try ready(base: "base\n", local: "base\nlocal\n", remote: "base\nremote\n")
    let eofConflict = try XCTUnwrap(eof.bodyConflicts.first)
    XCTAssertEqual(
      eof.resolvedDocument(frontMatterChoices: [:], bodyChoices: [eofConflict.id: .both]),
      "base\nlocal\nremote\n"
    )
  }

  func testBothPreservesExistingHunkBoundariesWithoutInventingNewlines() throws {
    let leadingRemoteNewline = try ready(base: "", local: "local", remote: "\nremote")
    let leadingConflict = try XCTUnwrap(leadingRemoteNewline.bodyConflicts.first)
    XCTAssertEqual(
      leadingRemoteNewline.resolvedDocument(
        frontMatterChoices: [:],
        bodyChoices: [leadingConflict.id: .both]
      ),
      "local\nremote"
    )

    let localTrailingNewline = try ready(base: "", local: "local\n", remote: "remote")
    let trailingConflict = try XCTUnwrap(localTrailingNewline.bodyConflicts.first)
    XCTAssertEqual(
      localTrailingNewline.resolvedDocument(
        frontMatterChoices: [:],
        bodyChoices: [trailingConflict.id: .both]
      ),
      "local\nremote"
    )

    let crlf = try ready(base: "", local: "local\r\n", remote: "remote")
    let crlfConflict = try XCTUnwrap(crlf.bodyConflicts.first)
    XCTAssertEqual(
      crlf.resolvedDocument(
        frontMatterChoices: [:],
        bodyChoices: [crlfConflict.id: .both]
      ),
      "local\r\nremote"
    )
  }

  func testPreservesConsistentCRLFAndRejectsInconsistentLineEndings() throws {
    let source = "one\r\ntwo\r\n"
    let plan = try ready(base: source, local: source, remote: source)
    XCTAssertEqual(plan.resolvedDocument(frontMatterChoices: [:], bodyChoices: [:]), source)

    assertUnsupported("one\ntwo\n", local: "one\r\ntwo\r\n", reason: .inconsistentLineEndings)
  }

  func testRejectsSizeAndLineComplexityBoundaries() {
    assertUnsupported(
      String(repeating: "a", count: MarkdownThreeWayMergeService.maximumTextByteCount + 1),
      reason: .documentTooLarge
    )
    let tooManyLines = Array(
      repeating: "x", count: MarkdownThreeWayMergeService.maximumLineCount + 1
    ).joined(separator: "\n")
    assertUnsupported(tooManyLines, reason: .tooManyLines)
  }

  private func ready(base: String, local: String, remote: String) throws
    -> MarkdownThreeWayMergePlan
  {
    switch service.analyze(base: base, local: local, remote: remote) {
    case .ready(let plan): return plan
    case .unsupported(let reason): throw TestFailure.unexpectedUnsupported(reason)
    }
  }

  private func assertUnsupported(
    _ base: String,
    local: String? = nil,
    remote: String? = nil,
    reason: MarkdownThreeWayMergeUnsupportedReason
  ) {
    switch service.analyze(base: base, local: local ?? base, remote: remote ?? base) {
    case .ready:
      XCTFail("Expected unsupported result")
    case .unsupported(let actual):
      XCTAssertEqual(actual, reason)
    }
  }
}

private enum TestFailure: Error {
  case unexpectedUnsupported(MarkdownThreeWayMergeUnsupportedReason)
}
