import Foundation

public enum MarkdownTableEditingCommand: Equatable, Sendable {
  case navigateForward
  case navigateBackward
  case format
  case insertRowAbove
  case insertRowBelow
  case deleteRow
  case insertColumnBefore
  case insertColumnAfter
  case deleteColumn
}

public struct MarkdownTableEditingContext: Equatable, Sendable {
  public let rowIndex: Int
  public let columnIndex: Int
  public let isSeparatorRow: Bool
  public let canDeleteRow: Bool
  public let canDeleteColumn: Bool

  public init(
    rowIndex: Int,
    columnIndex: Int,
    isSeparatorRow: Bool,
    canDeleteRow: Bool,
    canDeleteColumn: Bool
  ) {
    self.rowIndex = rowIndex
    self.columnIndex = columnIndex
    self.isSeparatorRow = isSeparatorRow
    self.canDeleteRow = canDeleteRow
    self.canDeleteColumn = canDeleteColumn
  }
}

public struct MarkdownTableEditingService: Sendable {
  public init() {}

  public func context(
    in markdown: String,
    selectedRange: NSRange
  ) -> MarkdownTableEditingContext? {
    guard let table = table(in: markdown, selectedRange: selectedRange) else { return nil }
    return MarkdownTableEditingContext(
      rowIndex: table.selectedRowIndex,
      columnIndex: table.selectedColumnIndex,
      isSeparatorRow: table.selectedRowIndex == table.separatorRowIndex,
      canDeleteRow: table.selectedRowIndex > table.separatorRowIndex,
      canDeleteColumn: table.columnCount > 1
    )
  }

  public func edit(
    in markdown: String,
    selectedRange: NSRange,
    command: MarkdownTableEditingCommand
  ) -> MarkdownSmartEdit? {
    guard var table = table(in: markdown, selectedRange: selectedRange) else { return nil }

    switch command {
    case .navigateForward:
      return navigationEdit(in: table, direction: .forward)
    case .navigateBackward:
      return navigationEdit(in: table, direction: .backward)
    case .format:
      return renderedEdit(
        for: table,
        targetRow: table.selectedRowIndex,
        targetColumn: table.selectedColumnIndex,
        caretOffset: table.selectedCellCaretOffset
      )
    case .insertRowAbove:
      let insertionIndex = rowInsertionIndex(in: table, isBelow: false)
      table.rows.insert(blankRow(columnCount: table.columnCount), at: insertionIndex)
      return renderedEdit(
        for: table,
        targetRow: insertionIndex,
        targetColumn: table.selectedColumnIndex
      )
    case .insertRowBelow:
      let insertionIndex = rowInsertionIndex(in: table, isBelow: true)
      table.rows.insert(blankRow(columnCount: table.columnCount), at: insertionIndex)
      return renderedEdit(
        for: table,
        targetRow: insertionIndex,
        targetColumn: table.selectedColumnIndex
      )
    case .deleteRow:
      guard table.selectedRowIndex > table.separatorRowIndex else { return nil }
      table.rows.remove(at: table.selectedRowIndex)
      let targetRow = min(
        max(table.separatorRowIndex + 1, table.selectedRowIndex - 1),
        max(0, table.rows.count - 1)
      )
      return renderedEdit(
        for: table,
        targetRow: targetRow,
        targetColumn: table.selectedColumnIndex
      )
    case .insertColumnBefore:
      return insertingColumn(in: table, at: table.selectedColumnIndex)
    case .insertColumnAfter:
      return insertingColumn(in: table, at: table.selectedColumnIndex + 1)
    case .deleteColumn:
      guard table.columnCount > 1 else { return nil }
      let removedColumn = table.selectedColumnIndex
      for rowIndex in table.rows.indices where rowIndex != table.separatorRowIndex {
        table.rows[rowIndex].cells = paddedCells(
          table.rows[rowIndex].cells,
          count: table.columnCount
        )
        table.rows[rowIndex].cells.remove(at: removedColumn)
      }
      table.alignments = paddedAlignments(table.alignments, count: table.columnCount)
      table.alignments.remove(at: removedColumn)
      return renderedEdit(
        for: table,
        targetRow: table.selectedRowIndex,
        targetColumn: min(removedColumn, max(0, table.columnCount - 1))
      )
    }
  }

  private enum NavigationDirection {
    case forward
    case backward
  }

  private func navigationEdit(
    in table: MarkdownTable,
    direction: NavigationDirection
  ) -> MarkdownSmartEdit? {
    let editableCells = table.rows.indices
      .filter { $0 != table.separatorRowIndex }
      .flatMap { rowIndex in
        (0 ..< table.columnCount).map { (row: rowIndex, column: $0) }
      }

    let current = (row: table.selectedRowIndex, column: table.selectedColumnIndex)
    let currentIndex = editableCells.firstIndex {
      $0.row == current.row && $0.column == current.column
    }

    switch direction {
    case .forward:
      if table.selectedRowIndex == table.separatorRowIndex {
        if let firstDataCell = editableCells.first(where: { $0.row > table.separatorRowIndex }) {
          return selectionEdit(for: firstDataCell, in: table)
        }
        return appendingDataRow(to: table)
      }

      if let currentIndex, currentIndex + 1 < editableCells.count {
        return selectionEdit(for: editableCells[currentIndex + 1], in: table)
      }
      return appendingDataRow(to: table)
    case .backward:
      if table.selectedRowIndex == table.separatorRowIndex {
        guard let lastHeaderCell = editableCells.last(where: { $0.row < table.separatorRowIndex }) else {
          return nil
        }
        return selectionEdit(for: lastHeaderCell, in: table)
      }

      guard let currentIndex else { return nil }
      let targetIndex = max(0, currentIndex - 1)
      return selectionEdit(for: editableCells[targetIndex], in: table)
    }
  }

  private func appendingDataRow(to table: MarkdownTable) -> MarkdownSmartEdit? {
    var updated = table
    updated.rows.append(blankRow(columnCount: table.columnCount))
    return renderedEdit(
      for: updated,
      targetRow: updated.rows.count - 1,
      targetColumn: 0
    )
  }

  private func selectionEdit(
    for target: (row: Int, column: Int),
    in table: MarkdownTable
  ) -> MarkdownSmartEdit? {
    guard target.row >= 0,
          target.row < table.rows.count,
          target.column >= 0,
          target.column < table.columnCount else {
      return nil
    }
    guard target.column < table.rows[target.row].sourceCells.count else {
      return renderedEdit(
        for: table,
        targetRow: target.row,
        targetColumn: target.column
      )
    }
    let cell = table.rows[target.row].sourceCells[target.column]
    return MarkdownSmartEdit(
      replacedRange: NSRange(location: cell.contentRange.location, length: 0),
      replacement: "",
      selectedRange: cell.contentRange
    )
  }

  private func insertingColumn(
    in table: MarkdownTable,
    at proposedIndex: Int
  ) -> MarkdownSmartEdit? {
    var updated = table
    let insertionIndex = min(max(0, proposedIndex), table.columnCount)
    for rowIndex in updated.rows.indices where rowIndex != updated.separatorRowIndex {
      updated.rows[rowIndex].cells = paddedCells(
        updated.rows[rowIndex].cells,
        count: table.columnCount
      )
      updated.rows[rowIndex].cells.insert("", at: insertionIndex)
    }
    updated.alignments = paddedAlignments(updated.alignments, count: table.columnCount)
    updated.alignments.insert(.none, at: insertionIndex)
    return renderedEdit(
      for: updated,
      targetRow: table.selectedRowIndex,
      targetColumn: insertionIndex
    )
  }

  private func rowInsertionIndex(in table: MarkdownTable, isBelow: Bool) -> Int {
    guard table.selectedRowIndex > table.separatorRowIndex else {
      return table.separatorRowIndex + 1
    }
    return isBelow
      ? table.selectedRowIndex + 1
      : table.selectedRowIndex
  }

  private func blankRow(columnCount: Int) -> MarkdownTableRow {
    MarkdownTableRow(
      cells: Array(repeating: "", count: columnCount),
      sourceCells: []
    )
  }

  private func renderedEdit(
    for table: MarkdownTable,
    targetRow: Int,
    targetColumn: Int,
    caretOffset: Int? = nil
  ) -> MarkdownSmartEdit? {
    let rendered = render(table)
    guard targetRow >= 0,
          targetRow < rendered.cellRanges.count,
          targetColumn >= 0,
          targetColumn < rendered.cellRanges[targetRow].count else {
      return nil
    }

    let cellRange = rendered.cellRanges[targetRow][targetColumn]
    let relativeSelection: NSRange
    if let caretOffset {
      relativeSelection = NSRange(
        location: cellRange.location + min(max(0, caretOffset), cellRange.length),
        length: 0
      )
    } else {
      relativeSelection = cellRange
    }

    return MarkdownSmartEdit(
      replacedRange: table.range,
      replacement: rendered.markdown,
      selectedRange: NSRange(
        location: table.range.location + relativeSelection.location,
        length: relativeSelection.length
      )
    )
  }

  private func render(_ table: MarkdownTable) -> RenderedMarkdownTable {
    let columnCount = table.columnCount
    let normalizedRows = table.rows.enumerated().map { rowIndex, row in
      rowIndex == table.separatorRowIndex
        ? Array(repeating: "", count: columnCount)
        : paddedCells(row.cells, count: columnCount)
    }
    let alignments = paddedAlignments(table.alignments, count: columnCount)
    let widths = (0 ..< columnCount).map { columnIndex in
      max(
        3,
        normalizedRows.enumerated()
          .filter { $0.offset != table.separatorRowIndex }
          .map { displayWidth(of: $0.element[columnIndex]) }
          .max() ?? 0
      )
    }

    var markdown = ""
    var cellRanges: [[NSRange]] = []
    for rowIndex in normalizedRows.indices {
      if rowIndex > 0 {
        markdown += table.lineEnding
      }

      markdown += "| "
      var ranges: [NSRange] = []
      for columnIndex in 0 ..< columnCount {
        let token: String
        let contentLength: Int
        if rowIndex == table.separatorRowIndex {
          token = separatorToken(alignment: alignments[columnIndex], width: widths[columnIndex])
          contentLength = (token as NSString).length
        } else {
          let content = normalizedRows[rowIndex][columnIndex]
          token = content + String(
            repeating: " ",
            count: max(0, widths[columnIndex] - displayWidth(of: content))
          )
          contentLength = (content as NSString).length
        }

        let location = (markdown as NSString).length
        markdown += token
        ranges.append(NSRange(location: location, length: contentLength))
        markdown += " |"
        if columnIndex + 1 < columnCount {
          markdown += " "
        }
      }
      cellRanges.append(ranges)
    }

    return RenderedMarkdownTable(markdown: markdown, cellRanges: cellRanges)
  }

  private func separatorToken(
    alignment: MarkdownTableAlignment,
    width: Int
  ) -> String {
    let normalizedWidth = max(3, width)
    switch alignment {
    case .none:
      return String(repeating: "-", count: normalizedWidth)
    case .left:
      return ":" + String(repeating: "-", count: normalizedWidth - 1)
    case .center:
      return ":" + String(repeating: "-", count: normalizedWidth - 2) + ":"
    case .right:
      return String(repeating: "-", count: normalizedWidth - 1) + ":"
    }
  }

  private func displayWidth(of value: String) -> Int {
    value.reduce(into: 0) { width, character in
      let isNarrow = character.unicodeScalars.allSatisfy { scalar in
        scalar.value < 0x80 || CharacterSet.nonBaseCharacters.contains(scalar)
      }
      width += isNarrow ? 1 : 2
    }
  }

  private func paddedCells(_ cells: [String], count: Int) -> [String] {
    if cells.count >= count {
      return Array(cells.prefix(count))
    }
    return cells + Array(repeating: "", count: count - cells.count)
  }

  private func paddedAlignments(
    _ alignments: [MarkdownTableAlignment],
    count: Int
  ) -> [MarkdownTableAlignment] {
    if alignments.count >= count {
      return Array(alignments.prefix(count))
    }
    return alignments + Array(repeating: .none, count: count - alignments.count)
  }

  private func table(
    in markdown: String,
    selectedRange: NSRange
  ) -> MarkdownTable? {
    let source = markdown as NSString
    guard let selection = clamped(selectedRange, length: source.length) else { return nil }
    let lines = lines(in: source)
    guard let selectedLineIndex = lineIndex(
      containing: selection.location,
      sourceLength: source.length,
      lines: lines
    ) else { return nil }

    for separatorLineIndex in 1 ..< lines.count {
      let headerLineIndex = separatorLineIndex - 1
      guard !isInsideFencedCodeBlock(lines: lines, before: headerLineIndex),
            let header = parsedRow(in: source, line: lines[headerLineIndex]),
            let separator = parsedRow(in: source, line: lines[separatorLineIndex]),
            header.cells.count == separator.cells.count,
            !header.cells.isEmpty,
            let alignments = separatorAlignments(for: separator.cells) else {
        continue
      }

      var parsedRows = [header, separator]
      var lastLineIndex = separatorLineIndex
      var nextLineIndex = separatorLineIndex + 1
      while nextLineIndex < lines.count,
            !lines[nextLineIndex].content.trimmingCharacters(in: .whitespaces).isEmpty,
            let row = parsedRow(in: source, line: lines[nextLineIndex]) {
        parsedRows.append(row)
        lastLineIndex = nextLineIndex
        nextLineIndex += 1
      }

      guard selectedLineIndex >= headerLineIndex,
            selectedLineIndex <= lastLineIndex else {
        continue
      }

      let selectedRowIndex = selectedLineIndex - headerLineIndex
      let selectedRow = parsedRows[selectedRowIndex]
      let selectedColumnIndex = columnIndex(
        at: selection.location,
        cells: selectedRow.cells
      )
      let selectedCell = selectedRow.cells[selectedColumnIndex]
      let tableRange = NSRange(
        location: lines[headerLineIndex].contentRange.location,
        length: NSMaxRange(lines[lastLineIndex].contentRange)
          - lines[headerLineIndex].contentRange.location
      )
      let lineEnding = detectedLineEnding(
        in: source,
        after: lines[headerLineIndex]
      )

      return MarkdownTable(
        range: tableRange,
        rows: parsedRows.map { row in
          MarkdownTableRow(
            cells: row.cells.map(\.content),
            sourceCells: row.cells
          )
        },
        alignments: alignments,
        separatorRowIndex: 1,
        selectedRowIndex: selectedRowIndex,
        selectedColumnIndex: selectedColumnIndex,
        selectedCellCaretOffset: min(
          max(0, selection.location - selectedCell.contentRange.location),
          selectedCell.contentRange.length
        ),
        lineEnding: lineEnding
      )
    }

    return nil
  }

  private func lines(in source: NSString) -> [MarkdownSourceLine] {
    guard source.length > 0 else { return [] }
    var result: [MarkdownSourceLine] = []
    var location = 0
    while location < source.length {
      let fullRange = source.lineRange(for: NSRange(location: location, length: 0))
      var contentEnd = NSMaxRange(fullRange)
      while contentEnd > fullRange.location {
        let character = source.character(at: contentEnd - 1)
        guard character == 10 || character == 13 else { break }
        contentEnd -= 1
      }
      let contentRange = NSRange(
        location: fullRange.location,
        length: contentEnd - fullRange.location
      )
      result.append(
        MarkdownSourceLine(
          content: source.substring(with: contentRange),
          contentRange: contentRange,
          fullRange: fullRange
        )
      )
      location = NSMaxRange(fullRange)
    }
    if source.length > 0 {
      let lastCharacter = source.character(at: source.length - 1)
      if lastCharacter == 10 || lastCharacter == 13 {
        let emptyRange = NSRange(location: source.length, length: 0)
        result.append(
          MarkdownSourceLine(
            content: "",
            contentRange: emptyRange,
            fullRange: emptyRange
          )
        )
      }
    }
    return result
  }

  private func lineIndex(
    containing location: Int,
    sourceLength: Int,
    lines: [MarkdownSourceLine]
  ) -> Int? {
    if location == sourceLength {
      return lines.indices.last
    }
    return lines.firstIndex { NSLocationInRange(location, $0.fullRange) }
  }

  private func parsedRow(
    in source: NSString,
    line: MarkdownSourceLine
  ) -> ParsedMarkdownTableRow? {
    let value = line.content as NSString
    let pipeLocations = structuralPipeLocations(in: value)
    guard !pipeLocations.isEmpty else { return nil }

    let firstNonWhitespace = firstNonWhitespaceLocation(in: value)
    let lastNonWhitespace = lastNonWhitespaceLocation(in: value)
    let hasLeadingPipe = firstNonWhitespace.map { value.character(at: $0) == 124 } ?? false
    let hasTrailingPipe = lastNonWhitespace.map { value.character(at: $0) == 124 } ?? false

    var separators = pipeLocations
    var segmentStart = 0
    if hasLeadingPipe, let firstPipe = separators.first {
      segmentStart = firstPipe + 1
      separators.removeFirst()
    }
    var finalEnd = value.length
    if hasTrailingPipe, let lastPipe = separators.last {
      finalEnd = lastPipe
      separators.removeLast()
    }

    var segmentEnds = separators
    segmentEnds.append(finalEnd)
    var cells: [ParsedMarkdownTableCell] = []
    for segmentEnd in segmentEnds where segmentEnd >= segmentStart {
      let rawRange = NSRange(location: segmentStart, length: segmentEnd - segmentStart)
      let trimmedRange = trimmedWhitespaceRange(in: value, range: rawRange)
      cells.append(
        ParsedMarkdownTableCell(
          content: value.substring(with: trimmedRange),
          contentRange: NSRange(
            location: line.contentRange.location + trimmedRange.location,
            length: trimmedRange.length
          )
        )
      )
      segmentStart = segmentEnd + 1
    }

    guard !cells.isEmpty else { return nil }
    return ParsedMarkdownTableRow(cells: cells)
  }

  private func structuralPipeLocations(in value: NSString) -> [Int] {
    var locations: [Int] = []
    var activeBacktickCount = 0
    var index = 0
    while index < value.length {
      let character = value.character(at: index)
      if character == 92 {
        index += min(2, value.length - index)
        continue
      }
      if character == 96 {
        var runLength = 1
        while index + runLength < value.length,
              value.character(at: index + runLength) == 96 {
          runLength += 1
        }
        if activeBacktickCount == 0 {
          activeBacktickCount = runLength
        } else if activeBacktickCount == runLength {
          activeBacktickCount = 0
        }
        index += runLength
        continue
      }
      if character == 124, activeBacktickCount == 0 {
        locations.append(index)
      }
      index += 1
    }
    return locations
  }

  private func separatorAlignments(
    for cells: [ParsedMarkdownTableCell]
  ) -> [MarkdownTableAlignment]? {
    var alignments: [MarkdownTableAlignment] = []
    for cell in cells {
      var token = cell.content.trimmingCharacters(in: .whitespaces)
      let isLeft = token.hasPrefix(":")
      let isRight = token.hasSuffix(":")
      if isLeft { token.removeFirst() }
      if isRight, !token.isEmpty { token.removeLast() }
      guard token.count >= 3, token.allSatisfy({ $0 == "-" }) else { return nil }
      switch (isLeft, isRight) {
      case (true, true):
        alignments.append(.center)
      case (true, false):
        alignments.append(.left)
      case (false, true):
        alignments.append(.right)
      case (false, false):
        alignments.append(.none)
      }
    }
    return alignments
  }

  private func columnIndex(
    at location: Int,
    cells: [ParsedMarkdownTableCell]
  ) -> Int {
    if let index = cells.firstIndex(where: {
      location >= $0.contentRange.location && location <= NSMaxRange($0.contentRange)
    }) {
      return index
    }
    if let index = cells.lastIndex(where: { location > NSMaxRange($0.contentRange) }) {
      return min(index + 1, cells.count - 1)
    }
    return 0
  }

  private func trimmedWhitespaceRange(in value: NSString, range: NSRange) -> NSRange {
    var start = range.location
    var end = NSMaxRange(range)
    while start < end, isHorizontalWhitespace(value.character(at: start)) {
      start += 1
    }
    while end > start, isHorizontalWhitespace(value.character(at: end - 1)) {
      end -= 1
    }
    return NSRange(location: start, length: end - start)
  }

  private func firstNonWhitespaceLocation(in value: NSString) -> Int? {
    (0 ..< value.length).first { !isHorizontalWhitespace(value.character(at: $0)) }
  }

  private func lastNonWhitespaceLocation(in value: NSString) -> Int? {
    (0 ..< value.length).reversed().first {
      !isHorizontalWhitespace(value.character(at: $0))
    }
  }

  private func isHorizontalWhitespace(_ character: unichar) -> Bool {
    character == 32 || character == 9
  }

  private func isInsideFencedCodeBlock(
    lines: [MarkdownSourceLine],
    before lineIndex: Int
  ) -> Bool {
    var activeFence: (character: Character, count: Int)?
    for line in lines.prefix(lineIndex) {
      let trimmed = line.content.trimmingCharacters(in: .whitespaces)
      guard let first = trimmed.first, first == "`" || first == "~" else { continue }
      let count = trimmed.prefix { $0 == first }.count
      guard count >= 3 else { continue }
      if let currentFence = activeFence {
        if currentFence.character == first, count >= currentFence.count {
          activeFence = nil
        }
      } else {
        activeFence = (first, count)
      }
    }
    return activeFence != nil
  }

  private func detectedLineEnding(
    in source: NSString,
    after line: MarkdownSourceLine
  ) -> String {
    let endingRange = NSRange(
      location: NSMaxRange(line.contentRange),
      length: max(0, NSMaxRange(line.fullRange) - NSMaxRange(line.contentRange))
    )
    let ending = source.substring(with: endingRange)
    return ending.isEmpty ? "\n" : ending
  }

  private func clamped(_ range: NSRange, length: Int) -> NSRange? {
    guard range.location >= 0, range.location <= length, range.length >= 0 else { return nil }
    return NSRange(
      location: range.location,
      length: min(range.length, length - range.location)
    )
  }
}

private struct MarkdownTable: Sendable {
  let range: NSRange
  var rows: [MarkdownTableRow]
  var alignments: [MarkdownTableAlignment]
  let separatorRowIndex: Int
  let selectedRowIndex: Int
  let selectedColumnIndex: Int
  let selectedCellCaretOffset: Int
  let lineEnding: String

  var columnCount: Int {
    max(
      alignments.count,
      rows.enumerated()
        .filter { $0.offset != separatorRowIndex }
        .map { $0.element.cells.count }
        .max() ?? 0
    )
  }
}

private struct MarkdownTableRow: Sendable {
  var cells: [String]
  let sourceCells: [ParsedMarkdownTableCell]
}

private struct ParsedMarkdownTableRow: Sendable {
  let cells: [ParsedMarkdownTableCell]
}

private struct ParsedMarkdownTableCell: Sendable {
  let content: String
  let contentRange: NSRange
}

private struct MarkdownSourceLine: Sendable {
  let content: String
  let contentRange: NSRange
  let fullRange: NSRange
}

private enum MarkdownTableAlignment: Sendable {
  case none
  case left
  case center
  case right
}

private struct RenderedMarkdownTable: Sendable {
  let markdown: String
  let cellRanges: [[NSRange]]
}
