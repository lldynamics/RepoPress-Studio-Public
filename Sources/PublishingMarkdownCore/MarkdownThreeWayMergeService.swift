import Foundation

/// A deliberately conservative three-way merge engine for Markdown documents.
///
/// It only treats a small, round-trippable subset of YAML/TOML front matter as
/// structured data. Everything else is rejected so callers can retain the
/// original source editor rather than silently rewriting content they cannot
/// faithfully preserve.
public struct MarkdownThreeWayMergeService: Sendable {
  public static let maximumTextByteCount = 512 * 1024
  public static let maximumLineCount = 800
  public static let maximumFrontMatterFieldCount = 128

  public init() {}

  public func analyze(
    base: String,
    local: String,
    remote: String
  ) -> MarkdownThreeWayMergeResult {
    guard base.utf8.count <= Self.maximumTextByteCount,
      local.utf8.count <= Self.maximumTextByteCount,
      remote.utf8.count <= Self.maximumTextByteCount
    else {
      return .unsupported(.documentTooLarge)
    }

    guard let lineEnding = compatibleLineEnding(base: base, local: local, remote: remote) else {
      return .unsupported(.inconsistentLineEndings)
    }

    let parsed = [base, local, remote].map { parseDocument($0, lineEnding: lineEnding) }
    guard case .success(let baseDocument) = parsed[0],
      case .success(let localDocument) = parsed[1],
      case .success(let remoteDocument) = parsed[2]
    else {
      for result in parsed {
        if case .failure(let reason) = result {
          return .unsupported(reason)
        }
      }
      return .unsupported(.malformedFrontMatter)
    }

    let headerKinds = Set([
      baseDocument.header?.delimiter, localDocument.header?.delimiter,
      remoteDocument.header?.delimiter,
    ])
    if headerKinds.count > 1 || (headerKinds.count == 2 && headerKinds.contains(nil)) {
      return .unsupported(.frontMatterPresenceOrDelimiterDiffers)
    }

    guard baseDocument.body.count <= Self.maximumLineCount,
      localDocument.body.count <= Self.maximumLineCount,
      remoteDocument.body.count <= Self.maximumLineCount
    else {
      return .unsupported(.tooManyLines)
    }

    let frontMatter = makeFrontMatterPlan(
      base: baseDocument.header,
      local: localDocument.header,
      remote: remoteDocument.header,
      lineEnding: lineEnding
    )
    guard case .success(let frontMatterPlan) = frontMatter else {
      if case .failure(let reason) = frontMatter {
        return .unsupported(reason)
      }
      return .unsupported(.malformedFrontMatter)
    }

    guard let localEdits = lineEdits(from: baseDocument.body, to: localDocument.body),
      let remoteEdits = lineEdits(from: baseDocument.body, to: remoteDocument.body)
    else {
      return .unsupported(.diffTooComplex)
    }

    let bodyPlan = makeBodyPlan(
      base: baseDocument.body,
      localEdits: localEdits,
      remoteEdits: remoteEdits,
      lineEnding: lineEnding
    )

    return .ready(
      MarkdownThreeWayMergePlan(
        frontMatterPlan: frontMatterPlan,
        bodyPlan: bodyPlan,
        lineEnding: lineEnding
      )
    )
  }
}

public enum MarkdownThreeWayMergeResult: Sendable {
  case ready(MarkdownThreeWayMergePlan)
  case unsupported(MarkdownThreeWayMergeUnsupportedReason)
}

public enum MarkdownThreeWayMergeUnsupportedReason: Error, Equatable, Sendable {
  case documentTooLarge
  case inconsistentLineEndings
  case tooManyLines
  case diffTooComplex
  case frontMatterPresenceOrDelimiterDiffers
  case malformedFrontMatter
  case unsupportedFrontMatterSyntax
  case unsupportedFrontMatterKey(String)
  case duplicateFrontMatterKey(String)
  case tooManyFrontMatterFields
}

public enum MarkdownThreeWayMergeFieldChoice: Equatable, Sendable {
  case local
  case remote
}

public enum MarkdownThreeWayMergeBodyChoice: Equatable, Sendable {
  case local
  case remote
  case both
}

public struct MarkdownThreeWayMergeFieldConflict: Identifiable, Equatable, Sendable {
  public let id: String
  public let key: String
  public let base: String?
  public let local: String?
  public let remote: String?

  public init(id: String, key: String, base: String?, local: String?, remote: String?) {
    self.id = id
    self.key = key
    self.base = base
    self.local = local
    self.remote = remote
  }
}

public struct MarkdownThreeWayMergeBodyConflict: Identifiable, Equatable, Sendable {
  public let id: Int
  public let baseStartLine: Int
  public let baseEndLine: Int
  public let base: String
  public let local: String
  public let remote: String

  public init(
    id: Int,
    baseStartLine: Int,
    baseEndLine: Int,
    base: String,
    local: String,
    remote: String
  ) {
    self.id = id
    self.baseStartLine = baseStartLine
    self.baseEndLine = baseEndLine
    self.base = base
    self.local = local
    self.remote = remote
  }
}

public struct MarkdownThreeWayMergePlan: Sendable {
  public let frontMatterConflicts: [MarkdownThreeWayMergeFieldConflict]
  public let bodyConflicts: [MarkdownThreeWayMergeBodyConflict]
  public let autoMergedFrontMatterFieldCount: Int
  public let autoMergedBodyHunkCount: Int

  fileprivate let frontMatterPlan: FrontMatterPlan
  fileprivate let bodyPlan: BodyPlan
  fileprivate let lineEnding: String

  fileprivate init(frontMatterPlan: FrontMatterPlan, bodyPlan: BodyPlan, lineEnding: String) {
    self.frontMatterPlan = frontMatterPlan
    self.bodyPlan = bodyPlan
    self.lineEnding = lineEnding
    frontMatterConflicts = frontMatterPlan.conflicts.map(\.publicConflict)
    bodyConflicts = bodyPlan.conflicts.map(\.publicConflict)
    autoMergedFrontMatterFieldCount = frontMatterPlan.autoMergedCount
    autoMergedBodyHunkCount = bodyPlan.autoMergedCount
  }

  /// Returns `nil` until every reported conflict has an explicit choice.
  /// Choices not associated with a reported conflict are ignored.
  public func resolvedDocument(
    frontMatterChoices: [String: MarkdownThreeWayMergeFieldChoice],
    bodyChoices: [Int: MarkdownThreeWayMergeBodyChoice]
  ) -> String? {
    guard let header = frontMatterPlan.render(choices: frontMatterChoices, lineEnding: lineEnding),
      let body = bodyPlan.render(choices: bodyChoices, lineEnding: lineEnding)
    else {
      return nil
    }
    let result = header + body
    guard result.utf8.count <= MarkdownThreeWayMergeService.maximumTextByteCount else { return nil }
    return result
  }
}

private enum ParsedDocumentResult {
  case success(ParsedDocument)
  case failure(MarkdownThreeWayMergeUnsupportedReason)
}

private struct ParsedDocument {
  let header: ParsedFrontMatter?
  let body: [MergeLine]
}

private struct ParsedFrontMatter {
  let delimiter: FrontMatterDelimiter
  let fields: [String: String]
  let fieldOrder: [String]
}

private enum MergeLine: Hashable {
  case content(String)
  case trailingNewline
}

private struct LineEdit {
  let range: Range<Int>
  let replacement: [MergeLine]
}

private struct FrontMatterPlan {
  let delimiter: FrontMatterDelimiter?
  let orderedKeys: [String]
  let resolved: [String: String?]
  let conflicts: [FieldConflict]
  let autoMergedCount: Int

  func render(
    choices: [String: MarkdownThreeWayMergeFieldChoice],
    lineEnding: String
  ) -> String? {
    guard let delimiter else { return "" }
    var values = resolved
    for conflict in conflicts {
      guard let choice = choices[conflict.id] else { return nil }
      values[conflict.key] = choice == .local ? conflict.local : conflict.remote
    }

    let lines = orderedKeys.compactMap { values[$0] ?? nil }
    if lines.isEmpty {
      return delimiter.rawValue + lineEnding + delimiter.rawValue
    }
    return ([delimiter.rawValue] + lines + [delimiter.rawValue]).joined(separator: lineEnding)
  }
}

private struct FieldConflict {
  let id: String
  let key: String
  let base: String?
  let local: String?
  let remote: String?

  var publicConflict: MarkdownThreeWayMergeFieldConflict {
    MarkdownThreeWayMergeFieldConflict(id: id, key: key, base: base, local: local, remote: remote)
  }
}

private struct BodyPlan {
  let base: [MergeLine]
  let segments: [BodySegment]
  let conflicts: [BodyConflict]
  let autoMergedCount: Int

  func render(
    choices: [Int: MarkdownThreeWayMergeBodyChoice],
    lineEnding: String
  ) -> String? {
    var result: [MergeLine] = []
    var cursor = 0
    for segment in segments {
      guard cursor <= segment.range.lowerBound else { return nil }
      result += base[cursor..<segment.range.lowerBound]
      switch segment.content {
      case .fixed(let lines):
        result += lines
      case .conflict(let conflict):
        guard let choice = choices[conflict.id] else { return nil }
        switch choice {
        case .local: result += conflict.local
        case .remote: result += conflict.remote
        case .both:
          result += combineMergeLines(
            local: conflict.local,
            remote: conflict.remote,
            lineEnding: lineEnding
          )
        }
      }
      cursor = segment.range.upperBound
    }
    guard cursor <= base.count else { return nil }
    result += base[cursor...]
    return renderMergeLines(result, lineEnding: lineEnding)
  }
}

private struct BodySegment {
  enum Content {
    case fixed([MergeLine])
    case conflict(BodyConflict)
  }

  let range: Range<Int>
  let content: Content
}

private struct BodyConflict {
  let id: Int
  let range: Range<Int>
  let base: [MergeLine]
  let local: [MergeLine]
  let remote: [MergeLine]
  let lineEnding: String

  var publicConflict: MarkdownThreeWayMergeBodyConflict {
    MarkdownThreeWayMergeBodyConflict(
      id: id,
      baseStartLine: range.lowerBound + 1,
      baseEndLine: range.upperBound,
      base: renderMergeLines(base, lineEnding: lineEnding),
      local: renderMergeLines(local, lineEnding: lineEnding),
      remote: renderMergeLines(remote, lineEnding: lineEnding)
    )
  }
}

extension MarkdownThreeWayMergeService {
  fileprivate static let canonicalFrontMatterKeys: Set<String> = [
    "title", "date", "created", "slug", "description", "authors", "tags", "categories",
    "aliases", "permalink", "draft", "status",
  ]

  fileprivate func compatibleLineEnding(base: String, local: String, remote: String) -> String? {
    let detections = [base, local, remote].map(detectedLineEnding)
    guard !detections.contains(.mixed) else { return nil }
    let endings = detections.compactMap { detection -> String? in
      guard case .ending(let value) = detection else { return nil }
      return value
    }
    guard Set(endings).count <= 1 else { return nil }
    return endings.first ?? "\n"
  }

  fileprivate func detectedLineEnding(in source: String) -> LineEndingDetection {
    var endings = Set<String>()
    let bytes = Array(source.utf8)
    var index = 0
    while index < bytes.count {
      switch bytes[index] {
      case 13:
        if index + 1 < bytes.count, bytes[index + 1] == 10 {
          endings.insert("\r\n")
          index += 2
        } else {
          endings.insert("\r")
          index += 1
        }
      case 10:
        endings.insert("\n")
        index += 1
      default:
        index += 1
      }
      if endings.count > 1 { return .mixed }
    }
    return endings.first.map(LineEndingDetection.ending) ?? .none
  }

  fileprivate func parseDocument(_ source: String, lineEnding: String) -> ParsedDocumentResult {
    let lines = source.components(separatedBy: lineEnding)
    let first = lines.first ?? ""
    guard let delimiter = FrontMatterDelimiter(rawValue: first) else {
      return .success(ParsedDocument(header: nil, body: tokenize(source, lineEnding: lineEnding)))
    }
    guard let closingIndex = lines.dropFirst().firstIndex(of: delimiter.rawValue) else {
      return .failure(.malformedFrontMatter)
    }

    var fields: [String: String] = [:]
    var fieldOrder: [String] = []
    let frontMatterLines = lines[1..<closingIndex]
    guard frontMatterLines.count <= Self.maximumFrontMatterFieldCount else {
      return .failure(.tooManyFrontMatterFields)
    }
    for line in frontMatterLines {
      guard let field = parseFrontMatterField(line, delimiter: delimiter) else {
        return .failure(.unsupportedFrontMatterSyntax)
      }
      guard Self.canonicalFrontMatterKeys.contains(field.key) else {
        return .failure(.unsupportedFrontMatterKey(field.key))
      }
      guard fields[field.key] == nil else {
        return .failure(.duplicateFrontMatterKey(field.key))
      }
      fields[field.key] = field.raw
      fieldOrder.append(field.key)
    }

    let header = ParsedFrontMatter(delimiter: delimiter, fields: fields, fieldOrder: fieldOrder)
    let bodyStart = lines.index(after: closingIndex)
    let bodyRaw: String
    if bodyStart < lines.endIndex {
      // The line ending after the closing delimiter belongs to the body suffix:
      // keeping it is what lets `header + body` reconstruct the original source.
      bodyRaw = lineEnding + lines[bodyStart...].joined(separator: lineEnding)
    } else {
      bodyRaw = ""
    }
    let body = tokenize(bodyRaw, lineEnding: lineEnding)
    return .success(ParsedDocument(header: header, body: body))
  }

  fileprivate func parseFrontMatterField(_ line: String, delimiter: FrontMatterDelimiter) -> (
    key: String, raw: String
  )? {
    guard !line.isEmpty, !line.contains("#"), !line.contains("\t") else { return nil }
    let separator: Character = delimiter == .yaml ? ":" : "="
    guard let separatorIndex = line.firstIndex(of: separator) else { return nil }
    let rawKey = String(line[..<separatorIndex])
    let keySource =
      delimiter == .toml
      ? rawKey.trimmingCharacters(in: .whitespaces)
      : rawKey
    let key = keySource.lowercased()
    guard keySource == key,
      key.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil
    else {
      return nil
    }
    let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(
      in: .whitespaces)
    guard isSimpleFrontMatterValue(value, delimiter: delimiter) else { return nil }
    return (key, line)
  }

  fileprivate func isSimpleFrontMatterValue(_ value: String, delimiter: FrontMatterDelimiter)
    -> Bool
  {
    if value.isEmpty { return true }
    if (value.hasPrefix("\"") && value.hasSuffix("\""))
      || (value.hasPrefix("'") && value.hasSuffix("'"))
    {
      return value.count >= 2 && !value.dropFirst().dropLast().contains("\n")
    }
    if value.hasPrefix("[") && value.hasSuffix("]") {
      let contents = value.dropFirst().dropLast()
      guard !contents.contains(where: { "[]{}#&*!|>\t\n\r".contains($0) }) else { return false }
      if delimiter == .toml {
        return contents.split(separator: ",", omittingEmptySubsequences: false).allSatisfy { item in
          let value = item.trimmingCharacters(in: .whitespaces)
          return value.isEmpty || (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
        }
      }
      return true
    }
    let disallowed = "{}#&*!|>\t\n\r"
    guard !value.contains(where: { disallowed.contains($0) }) else { return false }
    if delimiter == .yaml, value.hasPrefix("-") { return false }
    return true
  }

  fileprivate func makeFrontMatterPlan(
    base: ParsedFrontMatter?,
    local: ParsedFrontMatter?,
    remote: ParsedFrontMatter?,
    lineEnding: String
  ) -> Result<FrontMatterPlan, MarkdownThreeWayMergeUnsupportedReason> {
    guard let base, let local, let remote else {
      return .success(
        FrontMatterPlan(
          delimiter: nil, orderedKeys: [], resolved: [:], conflicts: [], autoMergedCount: 0))
    }
    guard base.delimiter == local.delimiter, local.delimiter == remote.delimiter else {
      return .failure(.frontMatterPresenceOrDelimiterDiffers)
    }

    var orderedKeys = base.fieldOrder
    for key in local.fieldOrder + remote.fieldOrder where !orderedKeys.contains(key) {
      orderedKeys.append(key)
    }

    var resolved: [String: String?] = [:]
    var conflicts: [FieldConflict] = []
    var automatic = 0
    for key in orderedKeys {
      let baseValue = base.fields[key]
      let localValue = local.fields[key]
      let remoteValue = remote.fields[key]
      let changed = localValue != baseValue || remoteValue != baseValue
      if localValue == baseValue {
        resolved[key] = remoteValue
        if changed { automatic += 1 }
      } else if remoteValue == baseValue || localValue == remoteValue {
        resolved[key] = localValue
        if changed { automatic += 1 }
      } else {
        conflicts.append(
          FieldConflict(id: key, key: key, base: baseValue, local: localValue, remote: remoteValue))
      }
    }
    return .success(
      FrontMatterPlan(
        delimiter: base.delimiter,
        orderedKeys: orderedKeys,
        resolved: resolved,
        conflicts: conflicts,
        autoMergedCount: automatic
      )
    )
  }

  fileprivate func tokenize(_ source: String, lineEnding: String) -> [MergeLine] {
    guard !source.isEmpty else { return [] }
    let hasTrailing = source.hasSuffix(lineEnding)
    var lines = source.components(separatedBy: lineEnding)
    if hasTrailing { lines.removeLast() }
    var result = lines.map(MergeLine.content)
    if hasTrailing { result.append(.trailingNewline) }
    return result
  }

  fileprivate func lineEdits(from base: [MergeLine], to side: [MergeLine]) -> [LineEdit]? {
    let rowCount = base.count + 1
    let columnCount = side.count + 1
    guard rowCount <= Self.maximumLineCount + 1,
      columnCount <= Self.maximumLineCount + 1
    else { return nil }
    let cellCount = rowCount * columnCount
    guard cellCount <= (Self.maximumLineCount + 1) * (Self.maximumLineCount + 1) else { return nil }

    var table = Array(repeating: UInt16(0), count: cellCount)
    func offset(_ row: Int, _ column: Int) -> Int { row * columnCount + column }
    if !base.isEmpty, !side.isEmpty {
      for row in stride(from: base.count - 1, through: 0, by: -1) {
        for column in stride(from: side.count - 1, through: 0, by: -1) {
          if base[row] == side[column] {
            table[offset(row, column)] = table[offset(row + 1, column + 1)] + 1
          } else {
            table[offset(row, column)] = max(
              table[offset(row + 1, column)], table[offset(row, column + 1)])
          }
        }
      }
    }

    var edits: [LineEdit] = []
    var baseIndex = 0
    var sideIndex = 0
    var editStart: Int?
    var replacement: [MergeLine] = []
    func flush() {
      guard let editStart else { return }
      edits.append(LineEdit(range: editStart..<baseIndex, replacement: replacement))
      replacement = []
    }

    while baseIndex < base.count || sideIndex < side.count {
      if baseIndex < base.count, sideIndex < side.count, base[baseIndex] == side[sideIndex] {
        if editStart != nil {
          flush()
          editStart = nil
        }
        baseIndex += 1
        sideIndex += 1
      } else if sideIndex < side.count,
        baseIndex == base.count
          || table[offset(baseIndex, sideIndex + 1)] >= table[offset(baseIndex + 1, sideIndex)]
      {
        if editStart == nil { editStart = baseIndex }
        replacement.append(side[sideIndex])
        sideIndex += 1
      } else {
        if editStart == nil { editStart = baseIndex }
        baseIndex += 1
      }
    }
    if editStart != nil { flush() }
    return edits
  }

  fileprivate func makeBodyPlan(
    base: [MergeLine],
    localEdits: [LineEdit],
    remoteEdits: [LineEdit],
    lineEnding: String
  ) -> BodyPlan {
    let changes =
      localEdits.map { TaggedEdit(side: .local, edit: $0) }
      + remoteEdits.map { TaggedEdit(side: .remote, edit: $0) }
    guard !changes.isEmpty else {
      return BodyPlan(base: base, segments: [], conflicts: [], autoMergedCount: 0)
    }

    var parent = Array(0..<changes.count)
    func root(_ value: Int) -> Int {
      var current = value
      while parent[current] != current { current = parent[current] }
      return current
    }
    func join(_ left: Int, _ right: Int) {
      let leftRoot = root(left)
      let rightRoot = root(right)
      if leftRoot != rightRoot { parent[rightRoot] = leftRoot }
    }
    for left in changes.indices {
      for right in changes.indices where right > left {
        guard changes[left].side != changes[right].side,
          editsIntersect(changes[left].edit.range, changes[right].edit.range)
        else { continue }
        join(left, right)
      }
    }

    var groups: [Int: [TaggedEdit]] = [:]
    for index in changes.indices {
      groups[root(index), default: []].append(changes[index])
    }
    let sortedGroups = groups.values.sorted {
      groupRange($0).lowerBound < groupRange($1).lowerBound
    }

    var segments: [BodySegment] = []
    var conflicts: [BodyConflict] = []
    var automatic = 0
    for group in sortedGroups {
      let range = groupRange(group)
      let local = group.filter { $0.side == .local }.map(\.edit)
      let remote = group.filter { $0.side == .remote }.map(\.edit)
      if local.isEmpty {
        segments.append(
          BodySegment(
            range: range,
            content: .fixed(
              applying(localEdits: remote, to: Array(base[range]), rangeStart: range.lowerBound))))
        automatic += 1
      } else if remote.isEmpty {
        segments.append(
          BodySegment(
            range: range,
            content: .fixed(
              applying(localEdits: local, to: Array(base[range]), rangeStart: range.lowerBound))))
        automatic += 1
      } else {
        let localVersion = applying(
          localEdits: local, to: Array(base[range]), rangeStart: range.lowerBound)
        let remoteVersion = applying(
          localEdits: remote, to: Array(base[range]), rangeStart: range.lowerBound)
        if localVersion == remoteVersion {
          segments.append(BodySegment(range: range, content: .fixed(localVersion)))
          automatic += 1
        } else {
          let conflict = BodyConflict(
            id: conflicts.count,
            range: range,
            base: Array(base[range]),
            local: localVersion,
            remote: remoteVersion,
            lineEnding: lineEnding
          )
          conflicts.append(conflict)
          segments.append(BodySegment(range: range, content: .conflict(conflict)))
        }
      }
    }
    return BodyPlan(
      base: base, segments: segments, conflicts: conflicts, autoMergedCount: automatic)
  }

  fileprivate func applying(localEdits edits: [LineEdit], to base: [MergeLine], rangeStart: Int)
    -> [MergeLine]
  {
    var result: [MergeLine] = []
    var cursor = rangeStart
    for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
      result += base[(cursor - rangeStart)..<(edit.range.lowerBound - rangeStart)]
      result += edit.replacement
      cursor = edit.range.upperBound
    }
    result += base[(cursor - rangeStart)...]
    return result
  }

  fileprivate func editsIntersect(_ left: Range<Int>, _ right: Range<Int>) -> Bool {
    if left.isEmpty, right.isEmpty { return left.lowerBound == right.lowerBound }
    if left.isEmpty {
      return left.lowerBound >= right.lowerBound && left.lowerBound <= right.upperBound
    }
    if right.isEmpty {
      return right.lowerBound >= left.lowerBound && right.lowerBound <= left.upperBound
    }
    return left.overlaps(right)
  }

  fileprivate func groupRange(_ group: [TaggedEdit]) -> Range<Int> {
    let lower = group.map { $0.edit.range.lowerBound }.min() ?? 0
    let upper = group.map { $0.edit.range.upperBound }.max() ?? lower
    return lower..<upper
  }
}

private enum MergeSide {
  case local
  case remote
}

private struct TaggedEdit {
  let side: MergeSide
  let edit: LineEdit
}

private enum LineEndingDetection: Equatable {
  case none
  case ending(String)
  case mixed
}

private func renderMergeLines(_ lines: [MergeLine], lineEnding: String) -> String {
  var contents: [String] = []
  var trailingNewline = false
  for line in lines {
    switch line {
    case .content(let value): contents.append(value)
    case .trailingNewline: trailingNewline = true
    }
  }
  var result = contents.joined(separator: lineEnding)
  if trailingNewline { result += lineEnding }
  return result
}

private func combineMergeLines(
  local: [MergeLine],
  remote: [MergeLine],
  lineEnding: String
) -> [MergeLine] {
  let localText = renderMergeLines(local, lineEnding: lineEnding)
  let remoteText = renderMergeLines(remote, lineEnding: lineEnding)
  guard !localText.isEmpty else {
    return tokenizeMergeText(remoteText, lineEnding: lineEnding)
  }
  guard !remoteText.isEmpty else {
    return tokenizeMergeText(localText, lineEnding: lineEnding)
  }
  let separator =
    localText.hasSuffix(lineEnding) || remoteText.hasPrefix(lineEnding)
    ? ""
    : lineEnding
  return tokenizeMergeText(localText + separator + remoteText, lineEnding: lineEnding)
}

private func tokenizeMergeText(_ text: String, lineEnding: String) -> [MergeLine] {
  guard !text.isEmpty else { return [] }
  let hasTrailingNewline = text.hasSuffix(lineEnding)
  var contents = text.components(separatedBy: lineEnding)
  if hasTrailingNewline { contents.removeLast() }
  var result = contents.map(MergeLine.content)
  if hasTrailingNewline { result.append(.trailingNewline) }
  return result
}
