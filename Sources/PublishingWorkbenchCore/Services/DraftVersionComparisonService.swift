import Foundation

public enum DraftVersionEditableField: String, CaseIterable, Sendable {
  case title
  case date
  case slug
  case tags
  case categories
  case authors
  case draftState
  case visibility
  case summary
  case cover
  case attachments
}

public struct DraftVersionFieldChange: Hashable, Sendable {
  public var field: DraftVersionEditableField
  public var previousValue: String
  public var currentValue: String

  public init(
    field: DraftVersionEditableField,
    previousValue: String,
    currentValue: String
  ) {
    self.field = field
    self.previousValue = previousValue
    self.currentValue = currentValue
  }
}

public enum DraftVersionLineDiffKind: String, Sendable {
  case unchanged
  case removed
  case added
  case skipped
}

public struct DraftVersionLineDiff: Identifiable, Hashable, Sendable {
  public var id: Int
  public var kind: DraftVersionLineDiffKind
  public var text: String
  public var previousLineNumber: Int?
  public var currentLineNumber: Int?
  public var skippedLineCount: Int

  public init(
    id: Int,
    kind: DraftVersionLineDiffKind,
    text: String,
    previousLineNumber: Int? = nil,
    currentLineNumber: Int? = nil,
    skippedLineCount: Int = 0
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.previousLineNumber = previousLineNumber
    self.currentLineNumber = currentLineNumber
    self.skippedLineCount = skippedLineCount
  }
}

public struct DraftVersionComparison: Hashable, Sendable {
  public var fieldChanges: [DraftVersionFieldChange]
  public var bodyLineDiffs: [DraftVersionLineDiff]
  public var addedLineCount: Int
  public var removedLineCount: Int

  public init(
    fieldChanges: [DraftVersionFieldChange],
    bodyLineDiffs: [DraftVersionLineDiff],
    addedLineCount: Int,
    removedLineCount: Int
  ) {
    self.fieldChanges = fieldChanges
    self.bodyLineDiffs = bodyLineDiffs
    self.addedLineCount = addedLineCount
    self.removedLineCount = removedLineCount
  }

  public var hasChanges: Bool {
    !fieldChanges.isEmpty || addedLineCount > 0 || removedLineCount > 0
  }
}

public struct DraftVersionComparisonService: Sendable {
  public init() {}

  public func compare(
    previous: ArticleDraft,
    current: ArticleDraft,
    contextLineCount: Int = 3
  ) -> DraftVersionComparison {
    let fieldChanges = editableFieldChanges(previous: previous, current: current)
    let allBodyLines = bodyLineDiff(previous: previous.bodyMarkdown, current: current.bodyMarkdown)
    let addedLineCount = allBodyLines.count { $0.kind == .added }
    let removedLineCount = allBodyLines.count { $0.kind == .removed }

    return DraftVersionComparison(
      fieldChanges: fieldChanges,
      bodyLineDiffs: collapsed(
        allBodyLines,
        contextLineCount: max(0, contextLineCount)
      ),
      addedLineCount: addedLineCount,
      removedLineCount: removedLineCount
    )
  }

  /// Restores only author-controlled article content. Repository identity and
  /// publication bookkeeping stay on the current draft so an old snapshot
  /// cannot silently weaken the next optimistic-concurrency publish check.
  public func restoringContent(
    from snapshot: ArticleDraft,
    into current: ArticleDraft,
    restoredAt: Date = Date()
  ) -> ArticleDraft {
    var restored = current
    restored.title = snapshot.title
    restored.date = snapshot.date
    restored.slug = snapshot.slug
    restored.tags = snapshot.tags
    restored.categories = snapshot.categories
    restored.authors = snapshot.authors
    restored.draft = snapshot.draft
    restored.visibility = snapshot.visibility
    restored.summary = snapshot.summary
    restored.bodyMarkdown = snapshot.bodyMarkdown
    restored.attachments = snapshot.attachments
    restored.coverAttachmentID = snapshot.coverAttachmentID.flatMap { coverID in
      snapshot.attachments.contains(where: { $0.id == coverID }) ? coverID : nil
    }
    restored.reusedFromSourceSnapshot = snapshot.reusedFromSourceSnapshot
    restored.updatedAt = restoredAt
    return restored
  }

  private func editableFieldChanges(
    previous: ArticleDraft,
    current: ArticleDraft
  ) -> [DraftVersionFieldChange] {
    var changes: [DraftVersionFieldChange] = []

    appendChange(.title, previous.title, current.title, to: &changes)
    appendChange(
      .date,
      previous.date.formatted(date: .numeric, time: .shortened),
      current.date.formatted(date: .numeric, time: .shortened),
      to: &changes
    )
    appendChange(.slug, previous.slug, current.slug, to: &changes)
    appendChange(.tags, listValue(previous.tags), listValue(current.tags), to: &changes)
    appendChange(.categories, listValue(previous.categories), listValue(current.categories), to: &changes)
    appendChange(.authors, listValue(previous.authors), listValue(current.authors), to: &changes)
    appendChange(
      .draftState,
      previous.draft ? CoreL10n.text("草稿") : CoreL10n.text("正式文章"),
      current.draft ? CoreL10n.text("草稿") : CoreL10n.text("正式文章"),
      to: &changes
    )
    appendChange(
      .visibility,
      previous.visibility == .private ? CoreL10n.text("私密") : CoreL10n.text("公开"),
      current.visibility == .private ? CoreL10n.text("私密") : CoreL10n.text("公开"),
      to: &changes
    )
    appendChange(.summary, previous.summary, current.summary, to: &changes)
    appendChange(
      .cover,
      coverValue(for: previous),
      coverValue(for: current),
      to: &changes
    )
    appendChange(
      .attachments,
      attachmentValue(for: previous),
      attachmentValue(for: current),
      to: &changes
    )
    return changes
  }

  private func appendChange(
    _ field: DraftVersionEditableField,
    _ previousValue: String,
    _ currentValue: String,
    to changes: inout [DraftVersionFieldChange]
  ) {
    guard previousValue != currentValue else { return }
    changes.append(DraftVersionFieldChange(
      field: field,
      previousValue: displayValue(previousValue),
      currentValue: displayValue(currentValue)
    ))
  }

  private func displayValue(_ value: String) -> String {
    value.trimmedForPublishing.nilIfEmpty ?? CoreL10n.text("未设置")
  }

  private func listValue(_ values: [String]) -> String {
    values
      .map(\.trimmedForPublishing)
      .filter { !$0.isEmpty }
      .joined(separator: "、")
  }

  private func coverValue(for draft: ArticleDraft) -> String {
    guard let coverID = draft.coverAttachmentID,
          let attachment = draft.attachments.first(where: { $0.id == coverID })
    else {
      return ""
    }
    return attachment.originalFilename
  }

  private func attachmentValue(for draft: ArticleDraft) -> String {
    draft.attachments
      .map { attachment in
        [
          attachment.originalFilename,
          attachment.altText,
          attachment.caption,
          attachment.relativePublishPath,
        ].joined(separator: " | ")
      }
      .joined(separator: "\n")
  }

  private func bodyLineDiff(previous: String, current: String) -> [DraftVersionLineDiff] {
    let previousLines = previous.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let currentLines = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let difference = currentLines.difference(from: previousLines)
    let removedOffsets = Set(difference.removals.compactMap { change -> Int? in
      guard case .remove(let offset, _, _) = change else { return nil }
      return offset
    })
    let addedOffsets = Set(difference.insertions.compactMap { change -> Int? in
      guard case .insert(let offset, _, _) = change else { return nil }
      return offset
    })
    var previousIndex = 0
    var currentIndex = 0
    var entries: [DraftVersionLineDiff] = []

    while previousIndex < previousLines.count || currentIndex < currentLines.count {
      if previousIndex < previousLines.count, removedOffsets.contains(previousIndex) {
        entries.append(DraftVersionLineDiff(
          id: entries.count,
          kind: .removed,
          text: previousLines[previousIndex],
          previousLineNumber: previousIndex + 1
        ))
        previousIndex += 1
        continue
      }

      if currentIndex < currentLines.count, addedOffsets.contains(currentIndex) {
        entries.append(DraftVersionLineDiff(
          id: entries.count,
          kind: .added,
          text: currentLines[currentIndex],
          currentLineNumber: currentIndex + 1
        ))
        currentIndex += 1
        continue
      }

      if previousIndex < previousLines.count,
         currentIndex < currentLines.count,
         previousLines[previousIndex] == currentLines[currentIndex] {
        entries.append(DraftVersionLineDiff(
          id: entries.count,
          kind: .unchanged,
          text: previousLines[previousIndex],
          previousLineNumber: previousIndex + 1,
          currentLineNumber: currentIndex + 1
        ))
        previousIndex += 1
        currentIndex += 1
        continue
      }

      // Defensive progress for malformed or future CollectionDifference
      // representations. Normal replacements are handled by remove + insert.
      if previousIndex < previousLines.count {
        entries.append(DraftVersionLineDiff(
          id: entries.count,
          kind: .removed,
          text: previousLines[previousIndex],
          previousLineNumber: previousIndex + 1
        ))
        previousIndex += 1
      } else if currentIndex < currentLines.count {
        entries.append(DraftVersionLineDiff(
          id: entries.count,
          kind: .added,
          text: currentLines[currentIndex],
          currentLineNumber: currentIndex + 1
        ))
        currentIndex += 1
      }
    }
    return entries
  }

  private func collapsed(
    _ lines: [DraftVersionLineDiff],
    contextLineCount: Int
  ) -> [DraftVersionLineDiff] {
    let changedIndexes = lines.indices.filter { lines[$0].kind != .unchanged }
    guard !changedIndexes.isEmpty else { return [] }

    var includedIndexes: Set<Int> = []
    for changedIndex in changedIndexes {
      let lowerBound = max(lines.startIndex, changedIndex - contextLineCount)
      let upperBound = min(lines.index(before: lines.endIndex), changedIndex + contextLineCount)
      includedIndexes.formUnion(lowerBound...upperBound)
    }

    var collapsedLines: [DraftVersionLineDiff] = []
    var skippedLineCount = 0
    for index in lines.indices {
      guard includedIndexes.contains(index) else {
        skippedLineCount += 1
        continue
      }
      if skippedLineCount > 0 {
        collapsedLines.append(DraftVersionLineDiff(
          id: collapsedLines.count,
          kind: .skipped,
          text: "",
          skippedLineCount: skippedLineCount
        ))
        skippedLineCount = 0
      }
      var line = lines[index]
      line.id = collapsedLines.count
      collapsedLines.append(line)
    }
    if skippedLineCount > 0 {
      collapsedLines.append(DraftVersionLineDiff(
        id: collapsedLines.count,
        kind: .skipped,
        text: "",
        skippedLineCount: skippedLineCount
      ))
    }
    return collapsedLines
  }
}
