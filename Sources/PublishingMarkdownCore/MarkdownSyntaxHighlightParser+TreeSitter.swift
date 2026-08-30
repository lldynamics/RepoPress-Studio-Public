import Foundation
import SwiftTreeSitter
import SwiftTreeSitterLayer
import TreeSitterMarkdown
import TreeSitterMarkdownInline

final class MarkdownTreeSitterEngine {
  private let layer: LanguageLayer
  private var source = ""
  private var sourceRevision: UInt64?
  private var lineIndex = MarkdownTreeSitterLineIndex(text: "")
  private(set) var initialParseCount = 0
  private(set) var incrementalParseCount = 0
  private(set) var editHintParseCount = 0
  private(set) var lastChangedRange: NSRange?

  init() throws {
    let markdown = try Self.languageConfiguration(
      Language(tree_sitter_markdown()),
      name: "Markdown",
      bundleName: "TreeSitterMarkdown_TreeSitterMarkdown"
    )
    let configuration = LanguageLayer.Configuration(
      maximumLanguageDepth: 1,
      languageProvider: { name in
        guard name == "markdown_inline" else { return nil }
        return try? Self.languageConfiguration(
          Language(tree_sitter_markdown_inline()),
          name: "MarkdownInline",
          bundleName: "TreeSitterMarkdown_TreeSitterMarkdownInline"
        )
      }
    )
    layer = try LanguageLayer(
      languageConfig: markdown,
      configuration: configuration
    )
  }

  private static func languageConfiguration(
    _ language: Language,
    name: String,
    bundleName: String
  ) throws -> LanguageConfiguration {
    let fileManager = FileManager.default
    let bundleDirectoryName = "\(bundleName).bundle"
    var searchRoots: [URL] = []
    let bundles =
      [Bundle.main, Bundle(for: MarkdownTreeSitterBundleMarker.self)]
      + Bundle.allBundles + Bundle.allFrameworks
    for bundle in bundles {
      searchRoots.append(bundle.bundleURL)
      if let resourceURL = bundle.resourceURL {
        searchRoots.append(resourceURL)
      }
      var ancestor = bundle.bundleURL.deletingLastPathComponent()
      for _ in 0..<4 {
        searchRoots.append(ancestor)
        ancestor.deleteLastPathComponent()
      }
    }

    for root in searchRoots {
      let bundleRoot = root.appendingPathComponent(bundleDirectoryName, isDirectory: true)
      for relativePath in ["queries", "Contents/Resources/queries"] {
        let queriesURL = bundleRoot.appendingPathComponent(relativePath, isDirectory: true)
        var queries: [Query.Definition: Query] = [:]
        for definition in [Query.Definition.injections, .highlights] {
          let queryURL = queriesURL.appendingPathComponent(definition.filename)
          guard fileManager.isReadableFile(atPath: queryURL.path) else { continue }
          queries[definition] = try Query(language: language, url: queryURL)
        }
        if !queries.isEmpty {
          return LanguageConfiguration(language, name: name, queries: queries)
        }
      }
    }
    return try LanguageConfiguration(language, name: name, bundleName: bundleName)
  }

  func highlights(
    in newSource: String,
    source newSourceUTF16: NSString,
    range: NSRange,
    revision: UInt64?,
    edit: MarkdownSyntaxHighlightEdit?
  ) throws -> [NamedRange] {
    try updateSource(
      to: newSource,
      source: newSourceUTF16,
      revision: revision,
      edit: edit
    )
    return try layer.highlights(
      in: range,
      provider: Self.textProvider(for: newSourceUTF16)
    )
  }

  func synchronize(
    in newSource: String,
    source newSourceUTF16: NSString,
    revision: UInt64?,
    edit: MarkdownSyntaxHighlightEdit?
  ) throws {
    try updateSource(
      to: newSource,
      source: newSourceUTF16,
      revision: revision,
      edit: edit
    )
  }

  private func updateSource(
    to newSource: String,
    source newSourceUTF16: NSString,
    revision: UInt64?,
    edit: MarkdownSyntaxHighlightEdit?
  ) throws {
    if let revision, revision == sourceRevision {
      lastChangedRange = nil
      return
    }
    if revision == nil, newSource == source {
      lastChangedRange = nil
      return
    }
    if initialParseCount == 0 {
      let newIndex = MarkdownTreeSitterLineIndex(text: newSource)
      let changed = layer.replaceContent(
        with: newSource,
        transformer: { newIndex.point(at: $0) }
      )
      source = newSource
      sourceRevision = revision
      lineIndex = newIndex
      initialParseCount += 1
      lastChangedRange = Self.coveringRange(changed)
      return
    }

    let revisionMatchedEdit: MarkdownSyntaxHighlightEdit?
    if let edit, let previousRevision = edit.previousRevision {
      revisionMatchedEdit = previousRevision == sourceRevision ? edit : nil
    } else {
      revisionMatchedEdit = edit
    }
    let editRange: (oldRange: NSRange, newRange: NSRange)
    if let hintedRange = Self.editRange(
      from: source,
      to: newSource,
      edit: revisionMatchedEdit
    ) {
      editRange = hintedRange
      editHintParseCount += 1
    } else {
      editRange = Self.singleEditRange(from: source, to: newSource)
    }
    let previousIndex = lineIndex
    let oldSourceUTF16 = source as NSString
    let editTouchesLineBreak =
      Self.containsLineBreak(oldSourceUTF16, in: editRange.oldRange)
      || Self.containsLineBreak(newSourceUTF16, in: editRange.newRange)
    let lineOffsetsAreUnchanged =
      editRange.oldRange.length == editRange.newRange.length
      && !editTouchesLineBreak
    let newIndex =
      lineOffsetsAreUnchanged
      ? previousIndex
      : previousIndex.applying(
        replacedRange: editRange.oldRange,
        insertedLength: editRange.newRange.length,
        newText: newSource
      )
    let inputEdit = InputEdit(
      startByte: editRange.oldRange.location * 2,
      oldEndByte: NSMaxRange(editRange.oldRange) * 2,
      newEndByte: NSMaxRange(editRange.newRange) * 2,
      startPoint: previousIndex.point(at: editRange.oldRange.location),
      oldEndPoint: previousIndex.point(at: NSMaxRange(editRange.oldRange)),
      newEndPoint: newIndex.point(at: NSMaxRange(editRange.newRange))
    )
    let changed = layer.didChangeContent(
      Self.content(for: newSourceUTF16),
      using: inputEdit,
      resolveSublayers: !lineOffsetsAreUnchanged
    )
    source = newSource
    sourceRevision = revision
    lineIndex = newIndex
    incrementalParseCount += 1
    if !editTouchesLineBreak {
      lastChangedRange = newSourceUTF16.lineRange(for: editRange.newRange)
    } else {
      lastChangedRange = Self.coveringRange(changed)
    }
  }

  /// SwiftTreeSitter's default String reader converts UTF-16 byte offsets back
  /// through `String.Index` for every chunk. That lookup grows with the offset
  /// in a large document. NSTextView already speaks UTF-16, so use NSString's
  /// direct coordinates for both parser reads and query predicate slices.
  private static func content(for source: NSString) -> LanguageLayer.Content {
    let readHandler: Parser.ReadBlock = { byteOffset, _ in
      let location = byteOffset / MemoryLayout<unichar>.size
      guard byteOffset.isMultiple(of: MemoryLayout<unichar>.size),
        location >= 0,
        location < source.length
      else {
        return nil
      }
      let length = min(1_024, source.length - location)
      var characters = [unichar](repeating: 0, count: length)
      source.getCharacters(
        &characters,
        range: NSRange(location: location, length: length)
      )
      return characters.withUnsafeBytes { Data($0) }
    }
    return LanguageLayer.Content(
      readHandler: readHandler,
      textProvider: textProvider(for: source)
    )
  }

  private static func textProvider(
    for source: NSString
  ) -> SwiftTreeSitter.Predicate.TextProvider {
    { range, _ in
      guard range.location != NSNotFound,
        range.location >= 0,
        range.length >= 0,
        range.location <= source.length,
        range.length <= source.length - range.location
      else {
        return nil
      }
      return source.substring(with: range)
    }
  }

  private static func containsLineBreak(_ source: NSString, in range: NSRange) -> Bool {
    guard range.length > 0 else { return false }
    return source.range(
      of: "\n",
      options: [],
      range: range
    ).location != NSNotFound
      || source.range(
        of: "\r",
        options: [],
        range: range
      ).location != NSNotFound
  }

  private static func editRange(
    from oldText: String,
    to newText: String,
    edit: MarkdownSyntaxHighlightEdit?
  ) -> (oldRange: NSRange, newRange: NSRange)? {
    guard let edit else { return nil }
    if edit.previousRevision == nil {
      guard edit.previousText == oldText else { return nil }
    }
    let oldLength = (oldText as NSString).length
    let newLength = (newText as NSString).length
    let oldRange = edit.replacedRange
    guard oldRange.location != NSNotFound,
      oldRange.location >= 0,
      oldRange.length >= 0,
      oldRange.location <= oldLength,
      oldRange.length <= oldLength - oldRange.location
    else {
      return nil
    }
    let insertedLength = newLength - (oldLength - oldRange.length)
    guard insertedLength >= 0 else { return nil }
    return (
      oldRange,
      NSRange(location: oldRange.location, length: insertedLength)
    )
  }

  private static func singleEditRange(
    from oldText: String,
    to newText: String
  ) -> (oldRange: NSRange, newRange: NSRange) {
    let old = oldText as NSString
    let new = newText as NSString
    let commonLimit = min(old.length, new.length)
    var prefix = 0
    while prefix < commonLimit, old.character(at: prefix) == new.character(at: prefix) {
      prefix += 1
    }
    if prefix > 0, prefix < old.length, prefix < new.length,
      Self.isHighSurrogate(old.character(at: prefix - 1))
    {
      prefix -= 1
    }

    var suffix = 0
    while suffix < old.length - prefix,
      suffix < new.length - prefix,
      old.character(at: old.length - suffix - 1)
        == new.character(at: new.length - suffix - 1)
    {
      suffix += 1
    }
    if suffix > 0,
      old.length - suffix > prefix,
      new.length - suffix > prefix,
      Self.isLowSurrogate(old.character(at: old.length - suffix))
    {
      suffix -= 1
    }

    return (
      NSRange(location: prefix, length: old.length - prefix - suffix),
      NSRange(location: prefix, length: new.length - prefix - suffix)
    )
  }

  private static func coveringRange(_ set: IndexSet) -> NSRange? {
    guard let first = set.first, let last = set.last else { return nil }
    return NSRange(location: first, length: last - first + 1)
  }

  private static func isHighSurrogate(_ value: unichar) -> Bool {
    (0xD800...0xDBFF).contains(value)
  }

  private static func isLowSurrogate(_ value: unichar) -> Bool {
    (0xDC00...0xDFFF).contains(value)
  }
}

private final class MarkdownTreeSitterBundleMarker: NSObject {}

private struct MarkdownTreeSitterLineIndex {
  private var starts: [Int]

  init(text: String) {
    starts = Self.lineStarts(in: text as NSString)
  }

  func point(at location: Int) -> Point {
    let safeLocation = max(0, location)
    var lower = 0
    var upper = starts.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if starts[middle] <= safeLocation {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    let line = max(0, lower - 1)
    return Point(row: line, column: (safeLocation - starts[line]) * 2)
  }

  func applying(
    replacedRange: NSRange,
    insertedLength: Int,
    newText: String
  ) -> Self {
    let delta = insertedLength - replacedRange.length
    let oldEnd = NSMaxRange(replacedRange)
    let startLineIndex = max(0, starts.partitioningIndex { $0 > replacedRange.location } - 1)
    let rebuildStart = starts[startLineIndex]
    let resumeIndex = starts.partitioningIndex { $0 > oldEnd }
    let oldResume = resumeIndex < starts.count ? starts[resumeIndex] : nil
    let newResume = oldResume.map { $0 + delta }
    let text = newText as NSString
    let scanEnd = min(max(rebuildStart, newResume ?? text.length), text.length)

    var nextStarts = Array(starts[..<startLineIndex])
    nextStarts.append(rebuildStart)
    var location = rebuildStart
    while location < scanEnd {
      let newline = text.range(
        of: "\n",
        range: NSRange(location: location, length: scanEnd - location)
      )
      guard newline.location != NSNotFound else { break }
      location = NSMaxRange(newline)
      if location <= scanEnd, nextStarts.last != location {
        nextStarts.append(location)
      }
    }
    if let newResume {
      for oldStart in starts.dropFirst(resumeIndex) {
        let shifted = oldStart + delta
        if shifted >= newResume, shifted <= text.length, nextStarts.last != shifted {
          nextStarts.append(shifted)
        }
      }
    }
    var result = self
    result.starts = nextStarts
    return result
  }

  private static func lineStarts(in text: NSString) -> [Int] {
    var result = [0]
    var location = 0
    while location < text.length {
      let newline = text.range(
        of: "\n",
        range: NSRange(location: location, length: text.length - location)
      )
      guard newline.location != NSNotFound else { break }
      location = NSMaxRange(newline)
      result.append(location)
    }
    return result
  }
}

extension Array where Element == Int {
  fileprivate func partitioningIndex(where predicate: (Int) -> Bool) -> Int {
    var lower = 0
    var upper = count
    while lower < upper {
      let middle = (lower + upper) / 2
      if predicate(self[middle]) {
        upper = middle
      } else {
        lower = middle + 1
      }
    }
    return lower
  }
}
