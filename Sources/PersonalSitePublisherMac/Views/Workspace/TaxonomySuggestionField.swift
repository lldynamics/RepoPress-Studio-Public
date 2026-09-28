import Foundation
import SwiftUI

struct TaxonomySuggestionField: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let title: String
  @Binding var values: [String]
  let suggestions: [String]

  var body: some View {
    let visibleSuggestions = Self.visibleSuggestions(values: values, suggestions: suggestions)

    VStack(alignment: .leading, spacing: 6) {
      Text(LocalizedStringKey(title))
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField(LocalizedStringKey(title), text: textBinding)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(LocalizedStringKey(title))
        .accessibilityValue(
          values.isEmpty ? String(localized: "未填写") : values.joined(separator: ", "))

      if !visibleSuggestions.isEmpty {
        WorkbenchFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
          ForEach(visibleSuggestions, id: \.self) { suggestion in
            let selected = isSelected(suggestion)
            Button {
              if selected {
                remove(suggestion)
              } else {
                append(suggestion)
              }
            } label: {
              HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark.circle.fill" : "tag")
                  .font(.workbenchMetadata)
                Text(suggestion)
                  .font(.caption.weight(.medium))
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(
                selected ? workbenchAccentColor.opacity(0.18) : Color.primary.opacity(0.06),
                in: Capsule()
              )
              .foregroundStyle(selected ? workbenchAccentColor : Color.primary)
              .overlay(
                Capsule()
                  .stroke(
                    selected ? workbenchAccentColor.opacity(0.4) : Color.primary.opacity(0.12),
                    lineWidth: 1)
              )
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.vertical, 2)
      }
    }
  }

  private var textBinding: Binding<String> {
    Binding(
      get: { values.joined(separator: ", ") },
      set: { values = parse($0) }
    )
  }

  private func isSelected(_ suggestion: String) -> Bool {
    values.contains(where: { $0.lowercased() == suggestion.lowercased() })
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

  static func visibleSuggestions(values: [String], suggestions: [String]) -> [String] {
    let selected = TaxonomySuggestionRanking.uniqueValues(values)
    let selectedKeys = Set(selected.map(TaxonomySuggestionRanking.key(for:)))
    let additional = TaxonomySuggestionRanking.uniqueValues(suggestions)
      .filter { !selectedKeys.contains(TaxonomySuggestionRanking.key(for: $0)) }

    return selected + Array(additional.prefix(TaxonomySuggestionRanking.additionalSuggestionLimit))
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
