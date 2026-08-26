import Foundation

public enum MarkdownCompletionKind: Equatable, Sendable {
  case slashCommand
  case internalLink
  case codeLanguage
}

public struct MarkdownCompletionArticle: Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var slug: String
  public var destination: String

  public init(id: UUID, title: String, slug: String, destination: String) {
    self.id = id
    self.title = title
    self.slug = slug
    self.destination = destination
  }
}

public struct MarkdownCodeLanguageCompletion: Equatable, Sendable {
  public var identifier: String
  public var displayName: String
  public var aliases: [String]

  public init(identifier: String, displayName: String, aliases: [String] = []) {
    self.identifier = identifier
    self.displayName = displayName
    self.aliases = aliases
  }
}

public struct MarkdownCompletionCandidate: Equatable, Sendable, Identifiable {
  public var id: String
  public var kind: MarkdownCompletionKind
  public var title: String
  public var detail: String
  public var replacementRange: NSRange
  public var expectedText: String
  public var replacement: String
  public var selectedRangeAfterApplying: NSRange

  public init(
    id: String,
    kind: MarkdownCompletionKind,
    title: String,
    detail: String,
    replacementRange: NSRange,
    expectedText: String,
    replacement: String,
    selectedRangeAfterApplying: NSRange
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.detail = detail
    self.replacementRange = replacementRange
    self.expectedText = expectedText
    self.replacement = replacement
    self.selectedRangeAfterApplying = selectedRangeAfterApplying
  }

  public var edit: MarkdownSmartEdit {
    MarkdownSmartEdit(
      replacedRange: replacementRange,
      replacement: replacement,
      selectedRange: selectedRangeAfterApplying
    )
  }
}

public struct MarkdownCompletionContext: Equatable, Sendable {
  public var kind: MarkdownCompletionKind
  public var query: String
  public var triggerRange: NSRange
  public var candidates: [MarkdownCompletionCandidate]

  public init(
    kind: MarkdownCompletionKind,
    query: String,
    triggerRange: NSRange,
    candidates: [MarkdownCompletionCandidate]
  ) {
    self.kind = kind
    self.query = query
    self.triggerRange = triggerRange
    self.candidates = candidates
  }
}

public struct MarkdownCursorCompletionService: Sendable {
  public static let defaultCodeLanguages: [MarkdownCodeLanguageCompletion] = [
    MarkdownCodeLanguageCompletion(identifier: "swift", displayName: "Swift"),
    MarkdownCodeLanguageCompletion(
      identifier: "javascript", displayName: "JavaScript", aliases: ["js"]),
    MarkdownCodeLanguageCompletion(
      identifier: "typescript", displayName: "TypeScript", aliases: ["ts"]),
    MarkdownCodeLanguageCompletion(identifier: "python", displayName: "Python", aliases: ["py"]),
    MarkdownCodeLanguageCompletion(identifier: "json", displayName: "JSON"),
    MarkdownCodeLanguageCompletion(identifier: "yaml", displayName: "YAML", aliases: ["yml"]),
    MarkdownCodeLanguageCompletion(
      identifier: "bash", displayName: "Bash", aliases: ["sh", "shell"]),
    MarkdownCodeLanguageCompletion(identifier: "html", displayName: "HTML"),
    MarkdownCodeLanguageCompletion(identifier: "css", displayName: "CSS"),
    MarkdownCodeLanguageCompletion(
      identifier: "markdown", displayName: "Markdown", aliases: ["md"]),
    MarkdownCodeLanguageCompletion(identifier: "sql", displayName: "SQL"),
    MarkdownCodeLanguageCompletion(identifier: "rust", displayName: "Rust"),
    MarkdownCodeLanguageCompletion(identifier: "go", displayName: "Go"),
    MarkdownCodeLanguageCompletion(identifier: "kotlin", displayName: "Kotlin", aliases: ["kt"]),
    MarkdownCodeLanguageCompletion(identifier: "java", displayName: "Java"),
    MarkdownCodeLanguageCompletion(identifier: "ruby", displayName: "Ruby", aliases: ["rb"]),
    MarkdownCodeLanguageCompletion(identifier: "php", displayName: "PHP"),
    MarkdownCodeLanguageCompletion(identifier: "c", displayName: "C"),
    MarkdownCodeLanguageCompletion(identifier: "cpp", displayName: "C++", aliases: ["c++"]),
    MarkdownCodeLanguageCompletion(
      identifier: "objective-c", displayName: "Objective-C", aliases: ["objc"]),
  ]

  public init() {}

  /// Returns whether the current line can contain a completion trigger.  The
  /// check intentionally stays line-local; the expensive code-range scan is
  /// deferred until `completion` is actually requested.
  public func shouldBuildCompletion(
    in markdown: String,
    selectedRange: NSRange
  ) -> Bool {
    let source = markdown as NSString
    guard selectedRange.length == 0,
      selectedRange.location > 0,
      selectedRange.location <= source.length
    else {
      return false
    }

    let lineRange = source.lineRange(
      for: NSRange(location: selectedRange.location, length: 0)
    )
    let prefixRange = NSRange(
      location: lineRange.location,
      length: selectedRange.location - lineRange.location
    )
    let prefix = source.substring(with: prefixRange)
    let indentation = prefix.prefix { $0 == " " || $0 == "\t" }
    let content = String(prefix.dropFirst(indentation.count))
    if content.hasPrefix("/") || content.contains("[[") {
      return !content.contains(where: \.isWhitespace)
        || content.contains("[[")
    }
    guard content.count >= 3 else { return false }
    guard let marker = content.first,
      marker == "`" || marker == "~",
      content.prefix(while: { $0 == marker }).count >= 3
    else {
      return false
    }
    return true
  }

  public func completion(
    in markdown: String,
    selectedRange: NSRange,
    articles: [MarkdownCompletionArticle] = [],
    codeLanguages: [MarkdownCodeLanguageCompletion] = Self.defaultCodeLanguages,
    snippets: [MarkdownSnippet] = []
  ) -> MarkdownCompletionContext? {
    completion(
      in: markdown,
      selectedRange: selectedRange,
      context: nil,
      articles: articles,
      codeLanguages: codeLanguages,
      snippets: snippets
    )
  }

  /// Computes completion only when the caller's cached cursor snapshot still
  /// describes this selection. Expensive code-range scanning remains behind
  /// the caller's trigger gate rather than running for ordinary cursor moves.
  public func completion(
    in markdown: String,
    selectedRange: NSRange,
    context: MarkdownCursorContextSnapshot?,
    articles: [MarkdownCompletionArticle] = [],
    codeLanguages: [MarkdownCodeLanguageCompletion] = Self.defaultCodeLanguages,
    snippets: [MarkdownSnippet] = []
  ) -> MarkdownCompletionContext? {
    if let context, context.selectedRange != selectedRange {
      return nil
    }
    let source = markdown as NSString
    guard selectedRange.length == 0,
      selectedRange.location >= 0,
      selectedRange.location <= source.length
    else {
      return nil
    }

    let codeRanges = MarkdownCodeRangeScanner.scan(markdown)
    if let language = codeLanguageCompletion(
      in: markdown,
      cursor: selectedRange.location,
      languages: codeLanguages,
      blockRanges: codeRanges.blockRanges
    ) {
      return language
    }

    guard
      !codeRanges.allRanges.contains(where: { range in
        selectedRange.location >= range.location
          && selectedRange.location < NSMaxRange(range)
      })
    else {
      return nil
    }
    if let link = internalLinkCompletion(
      in: markdown,
      cursor: selectedRange.location,
      articles: articles
    ) {
      return link
    }
    return slashCommandCompletion(
      in: markdown,
      cursor: selectedRange.location,
      snippets: snippets
    )
  }

  public func edit(
    applying candidate: MarkdownCompletionCandidate,
    in markdown: String
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    guard candidate.replacementRange.location >= 0,
      NSMaxRange(candidate.replacementRange) <= source.length,
      source.substring(with: candidate.replacementRange) == candidate.expectedText
    else {
      return nil
    }
    return candidate.edit
  }

  public func automaticShortcutCandidate(
    in markdown: String,
    selectedRange: NSRange,
    snippets: [MarkdownSnippet]
  ) -> MarkdownCompletionCandidate? {
    guard !snippets.isEmpty else { return nil }
    let source = markdown as NSString
    guard selectedRange.length == 0,
      selectedRange.location >= 0,
      selectedRange.location <= source.length,
      hasSlashCommandPrefix(source: source, cursor: selectedRange.location),
      !isInsideCode(in: markdown, cursor: selectedRange.location),
      let context = slashCommandCompletion(
        in: markdown,
        cursor: selectedRange.location,
        snippets: snippets
      )
    else {
      return nil
    }
    guard
      let snippet = snippets.first(where: {
        MarkdownSnippetLibraryService.normalizedShortcut($0.shortcut)
          == MarkdownSnippetLibraryService.normalizedShortcut(context.query)
      }),
      MarkdownSnippetLibraryService.normalizedShortcut(snippet.shortcut) != nil
    else {
      return nil
    }
    return context.candidates.first(where: { $0.id == "snippet-\(snippet.id)" })
  }

  private func hasSlashCommandPrefix(source: NSString, cursor: Int) -> Bool {
    let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
    var location = lineRange.location
    while location < cursor {
      let character = source.character(at: location)
      guard character == 32 || character == 9 else { break }
      location += 1
    }
    return location < cursor && source.character(at: location) == 47
  }

  private func slashCommandCompletion(
    in markdown: String,
    cursor: Int,
    snippets: [MarkdownSnippet]
  ) -> MarkdownCompletionContext? {
    let source = markdown as NSString
    let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
    let prefixRange = NSRange(location: lineRange.location, length: cursor - lineRange.location)
    let prefix = source.substring(with: prefixRange)
    let indentationLength = (prefix as NSString).range(
      of: #"^[ \t]*"#,
      options: .regularExpression
    ).length
    let commandStart = lineRange.location + indentationLength
    guard commandStart < cursor,
      source.substring(with: NSRange(location: commandStart, length: 1)) == "/"
    else {
      return nil
    }

    let commandRange = NSRange(location: commandStart, length: cursor - commandStart)
    let expected = source.substring(with: commandRange)
    let query = String(expected.dropFirst())
    guard !query.contains(where: \.isWhitespace) else { return nil }

    let definitions = slashCommandDefinitions(in: markdown, snippets: snippets)
    let normalizedQuery = query.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: .current
    )
    let candidates = definitions.compactMap { definition -> MarkdownCompletionCandidate? in
      let searchable = ([definition.command, definition.title] + definition.aliases)
        .map {
          $0.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
          )
        }
      guard
        normalizedQuery.isEmpty
          || searchable.contains(where: { $0.contains(normalizedQuery) })
      else {
        return nil
      }

      let selection = definition.selectionRange(in: definition.replacement)
      return MarkdownCompletionCandidate(
        id: definition.sourceSnippetID.map { "snippet-\($0)" } ?? "slash-\(definition.id)",
        kind: .slashCommand,
        title: definition.title,
        detail: definition.sourceSnippetID == nil
          ? "/\(definition.command)"
          : "/\(definition.command) · 组件/片段",
        replacementRange: commandRange,
        expectedText: expected,
        replacement: definition.replacement,
        selectedRangeAfterApplying: NSRange(
          location: commandRange.location + selection.location,
          length: selection.length
        )
      )
    }
    guard !candidates.isEmpty else { return nil }
    return MarkdownCompletionContext(
      kind: .slashCommand,
      query: query,
      triggerRange: commandRange,
      candidates: candidates
    )
  }

  private func internalLinkCompletion(
    in markdown: String,
    cursor: Int,
    articles: [MarkdownCompletionArticle]
  ) -> MarkdownCompletionContext? {
    guard !articles.isEmpty else { return nil }
    let source = markdown as NSString
    let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
    let prefixRange = NSRange(location: lineRange.location, length: cursor - lineRange.location)
    let prefix = source.substring(with: prefixRange) as NSString
    let localOpeningRange = prefix.range(of: "[[", options: .backwards)
    guard localOpeningRange.location != NSNotFound else { return nil }

    let afterOpeningRange = NSRange(
      location: NSMaxRange(localOpeningRange),
      length: prefix.length - NSMaxRange(localOpeningRange)
    )
    let afterOpening = prefix.substring(with: afterOpeningRange)
    let query: String
    var triggerEnd = cursor
    if let closing = afterOpening.range(of: "]]") {
      guard closing.upperBound == afterOpening.endIndex else { return nil }
      query = String(afterOpening[..<closing.lowerBound])
    } else {
      query = afterOpening
      let lineContentsEnd = contentsEnd(in: source, lineRange: lineRange)
      if cursor + 2 <= lineContentsEnd,
        source.substring(with: NSRange(location: cursor, length: 2)) == "]]"
      {
        triggerEnd += 2
      }
    }
    guard !query.contains("\n"), !query.contains("\r") else { return nil }

    let triggerStart = lineRange.location + localOpeningRange.location
    let triggerRange = NSRange(location: triggerStart, length: triggerEnd - triggerStart)
    let expected = source.substring(with: triggerRange)
    let normalizedQuery = normalizedSearchValue(query)
    let candidates =
      articles
      .filter { article in
        guard !normalizedQuery.isEmpty else { return true }
        return [article.title, article.slug, article.destination]
          .map(normalizedSearchValue)
          .contains(where: { $0.contains(normalizedQuery) })
      }
      .sorted { lhs, rhs in
        let lhsPrefix = normalizedSearchValue(lhs.title).hasPrefix(normalizedQuery)
        let rhsPrefix = normalizedSearchValue(rhs.title).hasPrefix(normalizedQuery)
        if lhsPrefix != rhsPrefix { return lhsPrefix }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
      }
      .map { article in
        let replacement = "[\(article.title)](\(article.destination))"
        return MarkdownCompletionCandidate(
          id: "article-\(article.id.uuidString)",
          kind: .internalLink,
          title: article.title,
          detail: article.destination,
          replacementRange: triggerRange,
          expectedText: expected,
          replacement: replacement,
          selectedRangeAfterApplying: NSRange(
            location: triggerRange.location + (replacement as NSString).length,
            length: 0
          )
        )
      }
    guard !candidates.isEmpty else { return nil }
    return MarkdownCompletionContext(
      kind: .internalLink,
      query: query,
      triggerRange: triggerRange,
      candidates: candidates
    )
  }

  private func codeLanguageCompletion(
    in markdown: String,
    cursor: Int,
    languages: [MarkdownCodeLanguageCompletion],
    blockRanges: [NSRange]? = nil
  ) -> MarkdownCompletionContext? {
    let source = markdown as NSString
    let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
    guard
      (blockRanges ?? MarkdownCodeRangeScanner.scan(markdown).blockRanges).contains(where: {
        $0.location == lineRange.location
      })
    else {
      return nil
    }

    let prefixRange = NSRange(location: lineRange.location, length: cursor - lineRange.location)
    let prefix = source.substring(with: prefixRange) as NSString
    var localCursor = 0
    var indentation = 0
    while localCursor < prefix.length,
      prefix.character(at: localCursor) == 32,
      indentation < 4
    {
      indentation += 1
      localCursor += 1
    }
    guard indentation <= 3, localCursor < prefix.length else { return nil }
    let marker = prefix.character(at: localCursor)
    guard marker == 96 || marker == 126 else { return nil }
    while localCursor < prefix.length, prefix.character(at: localCursor) == marker {
      localCursor += 1
    }
    guard localCursor - indentation >= 3 else { return nil }
    while localCursor < prefix.length,
      prefix.character(at: localCursor) == 32
        || prefix.character(at: localCursor) == 9
    {
      localCursor += 1
    }

    let queryStart = lineRange.location + localCursor
    let queryRange = NSRange(location: queryStart, length: cursor - queryStart)
    let query = source.substring(with: queryRange)
    guard query.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
      return nil
    }

    let lineContentsEnd = contentsEnd(in: source, lineRange: lineRange)
    var replacementEnd = cursor
    while replacementEnd < lineContentsEnd {
      let character = source.character(at: replacementEnd)
      let scalar = UnicodeScalar(character)
      guard let scalar,
        CharacterSet.alphanumerics.contains(scalar)
          || character == 45
          || character == 95
          || character == 43
      else {
        break
      }
      replacementEnd += 1
    }
    let replacementRange = NSRange(
      location: queryRange.location,
      length: replacementEnd - queryRange.location
    )
    let expected = source.substring(with: replacementRange)
    let normalizedQuery = normalizedSearchValue(query)
    let candidates =
      languages
      .filter { language in
        normalizedQuery.isEmpty
          || ([language.identifier, language.displayName] + language.aliases)
            .map(normalizedSearchValue)
            .contains(where: { $0.hasPrefix(normalizedQuery) })
      }
      .map { language in
        MarkdownCompletionCandidate(
          id: "language-\(language.identifier)",
          kind: .codeLanguage,
          title: language.displayName,
          detail: language.identifier,
          replacementRange: replacementRange,
          expectedText: expected,
          replacement: language.identifier,
          selectedRangeAfterApplying: NSRange(
            location: replacementRange.location + (language.identifier as NSString).length,
            length: 0
          )
        )
      }
    guard !candidates.isEmpty else { return nil }
    return MarkdownCompletionContext(
      kind: .codeLanguage,
      query: query,
      triggerRange: replacementRange,
      candidates: candidates
    )
  }

  private func slashCommandDefinitions(
    in markdown: String,
    snippets: [MarkdownSnippet]
  ) -> [SlashCommandDefinition] {
    let footnoteID = nextFootnoteIdentifier(in: markdown)
    let builtInDefinitions: [SlashCommandDefinition] = [
      SlashCommandDefinition(
        id: "table",
        command: "表格",
        title: "插入表格",
        aliases: ["table"],
        replacement: "| 列 1 | 列 2 |\n| --- | --- |\n| 内容 | 内容 |",
        selectionToken: "列 1"
      ),
      SlashCommandDefinition(
        id: "code",
        command: "代码",
        title: "插入代码块",
        aliases: ["code"],
        replacement: "```\n\n```",
        caretUTF16Offset: 4
      ),
      SlashCommandDefinition(
        id: "image",
        command: "图片",
        title: "插入图片",
        aliases: ["image"],
        replacement: "![图片说明](images/)",
        selectionToken: "图片说明"
      ),
      SlashCommandDefinition(
        id: "footnote",
        command: "脚注",
        title: "插入脚注",
        aliases: ["footnote"],
        replacement: "[^\(footnoteID)]\n\n[^\(footnoteID)]: ",
        caretUTF16Offset: nil
      ),
    ]

    let snippetDefinitions = snippets.compactMap { snippet -> SlashCommandDefinition? in
      guard let shortcut = MarkdownSnippetLibraryService.normalizedShortcut(snippet.shortcut) else {
        return nil
      }
      return SlashCommandDefinition(
        id: snippet.id,
        command: shortcut,
        title: snippet.title,
        aliases: [],
        replacement: snippet.markdown,
        selectionToken: snippet.selectionToken,
        sourceSnippetID: snippet.id
      )
    }

    var seenCommands = Set<String>()
    return (snippetDefinitions + builtInDefinitions).filter { definition in
      seenCommands.insert(definition.command.lowercased()).inserted
    }
  }

  private func nextFootnoteIdentifier(in markdown: String) -> Int {
    guard let expression = try? NSRegularExpression(pattern: #"\[\^([0-9]+)\]"#) else {
      return 1
    }
    let source = markdown as NSString
    let matches = expression.matches(
      in: markdown,
      range: NSRange(location: 0, length: source.length)
    )
    let maximum =
      matches.compactMap { match -> Int? in
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return Int(source.substring(with: range))
      }
      .max() ?? 0
    let (next, overflow) = maximum.addingReportingOverflow(1)
    return overflow ? 1 : next
  }

  private func normalizedSearchValue(_ value: String) -> String {
    value
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: .current
      )
      .lowercased()
  }

  private func isInsideCode(in markdown: String, cursor: Int) -> Bool {
    MarkdownCodeRangeScanner.scan(markdown).allRanges.contains { range in
      cursor >= range.location && cursor < NSMaxRange(range)
    }
  }

  private func contentsEnd(in source: NSString, lineRange: NSRange) -> Int {
    var lineStart = 0
    var lineEnd = 0
    var contentsEnd = 0
    source.getLineStart(
      &lineStart,
      end: &lineEnd,
      contentsEnd: &contentsEnd,
      for: lineRange
    )
    return contentsEnd
  }

  private struct SlashCommandDefinition {
    var id: String
    var command: String
    var title: String
    var aliases: [String]
    var replacement: String
    var selectionToken: String?
    var caretUTF16Offset: Int?
    var sourceSnippetID: String?

    init(
      id: String,
      command: String,
      title: String,
      aliases: [String],
      replacement: String,
      selectionToken: String? = nil,
      caretUTF16Offset: Int? = nil,
      sourceSnippetID: String? = nil
    ) {
      self.id = id
      self.command = command
      self.title = title
      self.aliases = aliases
      self.replacement = replacement
      self.selectionToken = selectionToken
      self.caretUTF16Offset = caretUTF16Offset
      self.sourceSnippetID = sourceSnippetID
    }

    func selectionRange(in replacement: String) -> NSRange {
      if let selectionToken {
        let range = (replacement as NSString).range(of: selectionToken)
        if range.location != NSNotFound { return range }
      }
      let length = (replacement as NSString).length
      return NSRange(
        location: min(max(0, caretUTF16Offset ?? length), length),
        length: 0
      )
    }
  }
}
