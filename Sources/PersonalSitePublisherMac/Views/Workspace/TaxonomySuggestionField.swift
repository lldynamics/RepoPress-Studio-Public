import Foundation
import SwiftUI

/// Selected values appear once, as removable chips; the text field only adds
/// values, and unselected suggestions are offered separately.
struct TaxonomySuggestionField: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let title: String
  let addPrompt: LocalizedStringKey
  @Binding var values: [String]
  let suggestions: [String]
  @State private var entryText = ""
  @FocusState private var isEntryFocused: Bool

  var body: some View {
    let selected = Self.selectedValues(values)
    let additional = Self.additionalSuggestions(values: values, suggestions: suggestions)

    VStack(alignment: .leading, spacing: 6) {
      Text(LocalizedStringKey(title))
        .font(.caption)
        .foregroundStyle(.secondary)

      if !selected.isEmpty {
        WorkbenchFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
          ForEach(selected, id: \.self) { value in
            selectedChip(value)
          }
        }
      }

      TextField(LocalizedStringKey(title), text: $entryText, prompt: Text(addPrompt))
        .textFieldStyle(.roundedBorder)
        .focused($isEntryFocused)
        .onSubmit(commitEntry)
        .onChange(of: isEntryFocused) { _, isFocused in
          // Typed text is kept when focus leaves, as the old free-text field did.
          if !isFocused { commitEntry() }
        }
        .accessibilityLabel(LocalizedStringKey(title))
        .accessibilityValue(
          values.isEmpty
            ? String(localized: "未填写") : values.joined(separator: ", ")
        )
        .accessibilityHint("输入后按回车添加，可用逗号分隔多个")

      if !additional.isEmpty {
        WorkbenchFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
          ForEach(additional, id: \.self) { suggestion in
            suggestionChip(suggestion)
          }
        }
        .padding(.vertical, 2)
      }
    }
  }

  private func selectedChip(_ value: String) -> some View {
    HStack(spacing: 4) {
      Text(value)
        .font(.caption.weight(.medium))
      Button {
        remove(value)
      } label: {
        Image(systemName: "xmark")
          .font(.workbenchMetadata.weight(.semibold))
      }
      .buttonStyle(.plain)
      .help("移除")
      .accessibilityLabel(String(localized: "移除“\(value)”"))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(workbenchAccentColor.opacity(0.18), in: Capsule())
    .foregroundStyle(workbenchAccentColor)
    .overlay(Capsule().stroke(workbenchAccentColor.opacity(0.4), lineWidth: 1))
    .accessibilityElement(children: .contain)
  }

  private func suggestionChip(_ suggestion: String) -> some View {
    Button {
      append(suggestion)
    } label: {
      HStack(spacing: 3) {
        Image(systemName: "plus")
          .font(.workbenchMetadata)
        Text(suggestion)
          .font(.caption)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .foregroundStyle(.secondary)
      .overlay(
        Capsule()
          .strokeBorder(
            Color.primary.opacity(0.22),
            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
          )
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(String(localized: "添加“\(suggestion)”"))
  }

  private func commitEntry() {
    let entries = parse(entryText)
    guard !entries.isEmpty else { return }
    for entry in entries {
      append(entry)
    }
    entryText = ""
  }

  private func append(_ suggestion: String) {
    guard !values.contains(where: { $0.lowercased() == suggestion.lowercased() }) else { return }
    values.append(suggestion)
  }

  private func remove(_ suggestion: String) {
    values.removeAll(where: { $0.lowercased() == suggestion.lowercased() })
  }

  private func parse(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0 == "，" })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  static func selectedValues(_ values: [String]) -> [String] {
    TaxonomySuggestionRanking.uniqueValues(values)
  }

  static func additionalSuggestions(values: [String], suggestions: [String]) -> [String] {
    let selectedKeys = Set(selectedValues(values).map(TaxonomySuggestionRanking.key(for:)))
    let additional = TaxonomySuggestionRanking.uniqueValues(suggestions)
      .filter { !selectedKeys.contains(TaxonomySuggestionRanking.key(for: $0)) }
    return Array(additional.prefix(TaxonomySuggestionRanking.additionalSuggestionLimit))
  }
}

enum TaxonomySuggestionRanking {
  static let additionalSuggestionLimit = 12

  static func suggestions(
    selectedValues: [String],
    draftValues: [(siteProfileID: UUID?, values: [String])],
    siteProfileID: UUID
  ) -> [String] {
    let selected = uniqueValues(selectedValues)
    let selectedKeys = Set(selected.map(key(for:)))
    var frequencyByKey: [String: Int] = [:]
    var displayValueByKey: [String: String] = [:]

    for draft in draftValues where draft.siteProfileID == siteProfileID {
      var valuesInDraft = Set<String>()
      for value in draft.values {
        guard let value = normalizedValue(value) else { continue }
        let normalizedKey = key(for: value)
        if let existingValue = displayValueByKey[normalizedKey] {
          if compare(value, existingValue) == .orderedAscending {
            displayValueByKey[normalizedKey] = value
          }
        } else {
          displayValueByKey[normalizedKey] = value
        }
        valuesInDraft.insert(normalizedKey)
      }
      for normalizedKey in valuesInDraft {
        frequencyByKey[normalizedKey, default: 0] += 1
      }
    }

    let remainingKeys = frequencyByKey.keys.filter { !selectedKeys.contains($0) }
    let rankedRemaining = remainingKeys.sorted { lhs, rhs in
      let lhsFrequency = frequencyByKey[lhs, default: 0]
      let rhsFrequency = frequencyByKey[rhs, default: 0]
      if lhsFrequency != rhsFrequency {
        return lhsFrequency > rhsFrequency
      }
      return compare(displayValueByKey[lhs, default: lhs], displayValueByKey[rhs, default: rhs])
        == .orderedAscending
    }
    .compactMap { displayValueByKey[$0] }

    return selected
      + Array(rankedRemaining.prefix(additionalSuggestionLimit))
  }

  static func uniqueValues(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap(normalizedValue).filter { seen.insert(key(for: $0)).inserted }
  }

  static func key(for value: String) -> String {
    value.lowercased(with: stableLocale)
  }

  private static func normalizedValue(_ value: String) -> String? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let insensitive = lhs.compare(
      rhs,
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      range: nil,
      locale: stableLocale
    )
    guard insensitive == .orderedSame else { return insensitive }
    let exact = lhs.compare(rhs, options: [], range: nil, locale: stableLocale)
    guard exact == .orderedSame else { return exact }
    guard lhs != rhs else { return .orderedSame }
    return lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars)
      ? .orderedAscending
      : .orderedDescending
  }

  private static let stableLocale = Locale(identifier: "en_US_POSIX")
}
