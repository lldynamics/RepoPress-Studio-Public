import SwiftUI

struct TaxonomySuggestionField: View {
  let title: String
  @Binding var values: [String]
  let suggestions: [String]
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField(title, text: textBinding)
        .focused($isFocused)
        .accessibilityLabel("文章\(title)")
        .accessibilityValue(values.isEmpty ? "未填写" : values.joined(separator: "，"))

      if !suggestions.isEmpty {
        ScrollView(.horizontal, showsIndicators: true) {
          HStack(spacing: 6) {
            ForEach(suggestions.prefix(12), id: \.self) { suggestion in
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
                  selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                  in: Capsule()
                )
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .overlay(
                  Capsule()
                    .stroke(selected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.12), lineWidth: 1)
                )
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.vertical, 2)
        }
      }
    }
  }

  private var textBinding: Binding<String> {
    Binding(
      get: { values.joined(separator: ", ") },
      set: { values = parse($0) }
    )
  }

  private var suggestionsPresented: Binding<Bool> {
    Binding(
      get: { isFocused && !filteredSuggestions.isEmpty },
      set: { if !$0 { isFocused = false } }
    )
  }

  private var activeQuery: String {
    textBinding.wrappedValue
      .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "，" })
      .last
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private var filteredSuggestions: [String] {
    suggestions
      .filter { suggestion in
        !values.contains(where: { $0.caseInsensitiveCompare(suggestion) == .orderedSame })
          && (activeQuery.isEmpty || suggestion.localizedStandardContains(activeQuery))
      }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
}
