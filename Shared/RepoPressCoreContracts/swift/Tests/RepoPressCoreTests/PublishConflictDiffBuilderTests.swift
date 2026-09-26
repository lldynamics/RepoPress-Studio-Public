import Testing

@testable import RepoPressCore

struct PublishConflictDiffBuilderTests {
  @Test
  func reportsStableRemoteAndLocalChanges() {
    let lines = PublishConflictDiffBuilder().diff(
      remote: "title\nold body\nfooter",
      local: "title\nnew body\nfooter"
    )

    #expect(lines.map(\.kind) == [.same, .remote, .local, .same])
    #expect(lines.map(\.marker) == [" ", "-", "+", " "])
    #expect(lines.map(\.text) == ["title", "old body", "new body", "footer"])
  }

  @Test
  func usesBoundedFallbackForVeryLargeInputs() {
    let remote = Array(repeating: "remote", count: 501).joined(separator: "\n")
    let local = Array(repeating: "local", count: 500).joined(separator: "\n")

    let lines = PublishConflictDiffBuilder().diff(remote: remote, local: local)

    #expect(lines.count == 1_001)
    #expect(lines.prefix(501).allSatisfy { $0.kind == .remote })
    #expect(lines.suffix(500).allSatisfy { $0.kind == .local })
  }
}
