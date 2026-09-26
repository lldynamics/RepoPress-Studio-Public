import Foundation
@testable import RepoPressCore
import Testing

struct ImportedFrontMatterTests {
  @Test func tomlDelimiterInsideMultilineStringDoesNotSplitTheEnvelope() throws {
    let raw = "+++\ntitle = 'Original'\nnotes = \"\"\"\n+++\nliteral content\n\"\"\"\n+++"
    let split = ImportedFrontMatter.split(raw + "\n\nBody")
    let original = try #require(split.frontMatter)
    #expect(original.rawBlock == raw)
    #expect(split.body == "\nBody")
    #expect(try original.replacing([:]) == raw)
    #expect(try original.replacing(["title": "\"Changed\""])
      == raw.replacingOccurrences(of: "'Original'", with: "\"Changed\""))
  }

  @Test func yamlPlainScalarHashQuotesAndBracketsAreNotSyntax() throws {
    for value in ["Original#keep", "https://example.test/page#section", "Father's [notes]"] {
      let raw = "---\ntitle: \(value) # actual comment\ncustom: keep\n---"
      let original = try #require(ImportedFrontMatter.split(raw).frontMatter)
      #expect(original.string(for: "title") == value)
      #expect(try original.replacing(["title": "\"Changed\""])
        == "---\ntitle: \"Changed\" # actual comment\ncustom: keep\n---")
    }
  }

  @Test func yamlTitleEditPreservesNestedFieldsCommentsBlockScalarAndArrays() throws {
    let source = """
    ---
    # original order
    params:
      title: nested
      flags: [one, two]
      object: {color: blue}
    title: 'Original' # title note
    description: |-
      First paragraph.
      title: not metadata
    custom:
      - name: item
        enabled: true
    ---

    Original body
    """
    let split = ImportedFrontMatter.split(source)
    let original = try #require(split.frontMatter)
    #expect(original.string(for: "title") == "Original")
    #expect(original.string(for: "description") == nil)
    #expect(try original.replacing([:]) == original.rawBlock)
    #expect(try original.replacing(["title": ImportedFrontMatter.quoted("Changed 中文")])
      == original.rawBlock.replacingOccurrences(of: "'Original'", with: "\"Changed 中文\""))
    #expect(throws: FrontMatterPreservationError.self) {
      try original.replacing(["description": "\"replacement\""])
    }
  }

  @Test func tomlTablesAreScopedAndUnknownExtraRemainsExact() throws {
    let tripleQuoted = "\"\"\"\n[not_a_table]\ntitle = fake\n\"\"\""
    let source = """
    +++
    title = "Original" # keep
    [extra]
    title = "Nested"
    flags = ["a", "b"]
    text = \(tripleQuoted)
    [taxonomies]
    tags = ["one", "two"] # retain
    categories = ["writing"]
    +++
    Body
    """
    let original = try #require(ImportedFrontMatter.split(source).frontMatter)
    #expect(original.string(for: "title") == "Original")
    #expect(original.strings(for: "taxonomies.tags") == ["one", "two"])
    let rendered = try original.replacing(["title": "\"Changed\"", "taxonomies.tags": "[\"new\"]"])
    #expect(rendered == original.rawBlock
      .replacingOccurrences(of: "title = \"Original\"", with: "title = \"Changed\"")
      .replacingOccurrences(of: "[\"one\", \"two\"]", with: "[\"new\"]"))
  }

  @Test func inlineTaxonomiesRetainCustomMembersAndQuotedCommas() throws {
    let source = "+++\ntitle = \"Hello\"\ntaxonomies = { tags = [\"a,b\", \"c\"], custom = [\"keep\"], categories = [\"x\"] } # note\n+++"
    let original = try #require(ImportedFrontMatter.split(source).frontMatter)
    #expect(original.strings(for: "taxonomies.tags") == ["a,b", "c"])
    #expect(try original.replacing(["taxonomies.tags": "[\"new\"]"])
      == source.replacingOccurrences(of: "[\"a,b\", \"c\"]", with: "[\"new\"]"))
  }

  @Test func delimiterMustOccupyWholeLineAndCRLFIsPreserved() throws {
    let source = "---\r\ntitle: \"原文\" # 保留\r\n---suffix\r\n---\r\nBody"
    let original = try #require(ImportedFrontMatter.split(source).frontMatter)
    #expect(original.rawBlock.contains("---suffix"))
    #expect(throws: FrontMatterPreservationError.self) { try original.replacing([:]) }
    let valid = try #require(ImportedFrontMatter.split("---\r\ntitle: \"原文\" # 保留\r\n---\r\nBody").frontMatter)
    #expect(try valid.replacing(["title": "\"Changed\""])
      == "---\r\ntitle: \"Changed\" # 保留\r\n---\r")
  }

  @Test func invalidDuplicateAndUnclosedInputsRetainOriginalButBlock() throws {
    for raw in ["---\ntitle: a\ntitle: b\n---", "+++\ntitle = \"unclosed\n+++", "---\ntitle: a"] {
      let original = try #require(ImportedFrontMatter.split(raw).frontMatter)
      #expect(original.rawBlock == raw)
      #expect(throws: FrontMatterPreservationError.self) { try original.replacing([:]) }
    }
  }

  @Test func absentFieldsDoNotMaterializeUntilExplicitlyEdited() throws {
    let original = ImportedFrontMatter(rawBlock: "+++\n[extra]\ntitle = 'nested'\n+++", syntax: .toml)
    #expect(original.string(for: "title") == nil)
    #expect(try original.replacing([:]) == original.rawBlock)
    #expect(try original.replacing(["title": "\"New\""])
      == "+++\ntitle = \"New\"\n[extra]\ntitle = 'nested'\n+++")
    let empty = ImportedFrontMatter(rawBlock: "", syntax: .yaml)
    #expect(try empty.replacing([:]) == "")
    #expect(try empty.replacing(["title": "\"New\""]) == "---\ntitle: \"New\"\n---")
  }

  @Test func quotedAndDottedCustomKeysDoNotBlockUnrelatedEdits() throws {
    for source in [
      "---\n\"custom:key\": value\ntitle: Original\n---",
      "+++\n\"custom=key\".nested = 'keep'\ntitle = 'Original'\n+++"
    ] {
      let original = try #require(ImportedFrontMatter.split(source).frontMatter)
      let rendered = try original.replacing(["title": ImportedFrontMatter.quoted("https://example.test/a")])
      #expect(rendered.contains("https://example.test/a"))
      #expect(!rendered.contains("\\/"))
    }
  }

  @Test func yamlTaxonomyDepthAndBlockListsRemainDistinct() throws {
    let source = "---\ntitle: Original\nauthors:\n  - 'One'\n  - 'Two'\ntaxonomies:\n  custom:\n    tags: [keep]\n  tags: [actual]\n---"
    let original = try #require(ImportedFrontMatter.split(source).frontMatter)
    #expect(original.strings(for: "authors") == ["One", "Two"])
    #expect(original.strings(for: "taxonomies.tags") == ["actual"])
    #expect(try original.replacing(["taxonomies.tags": "[new]"])
      == source.replacingOccurrences(of: "[actual]", with: "[new]"))
  }

  @Test func byteOrderMarkIsPartOfPreservedEnvelope() throws {
    let source = "\u{FEFF}---\ntitle: Original\n---\nBody"
    let original = try #require(ImportedFrontMatter.split(source).frontMatter)
    #expect(try original.replacing(["title": "Changed"]) == "\u{FEFF}---\ntitle: Changed\n---")
  }

  @Test func complexKnownValuesAndPlainMultilineScalarsCannotBeSilentlyFlattened() throws {
    for raw in ["---\ntitle: {en: Original, zh: 原文}\n---", "---\ntitle: First line\n  second line\n---"] {
      let original = try #require(ImportedFrontMatter.split(raw).frontMatter)
      #expect(try original.replacing([:]) == raw)
      #expect(throws: FrontMatterPreservationError.self) { try original.replacing(["title": "\"Changed\""]) }
    }
  }

  @Test func metadataRoundTripsWithoutChangingRawSourceOrBaseline() throws {
    let original = ImportedFrontMatter(rawBlock: "---\ncustom: value\n---", syntax: .yaml,
                                      baseline: ["title": "Fallback", "tags": "[]"])
    let restored = try JSONDecoder().decode(ImportedFrontMatter.self, from: JSONEncoder().encode(original))
    #expect(restored == original)
  }
}
