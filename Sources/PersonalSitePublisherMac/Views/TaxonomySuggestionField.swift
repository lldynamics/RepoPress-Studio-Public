import SwiftUI

struct TaxonomySuggestionField: View {
  let title: String
  @Binding var values: [String]
  let suggestions: [String]
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField(title, text: textBinding)
      .focused($isFocused)
      .accessibilityLabel("文章\(title)")
      .accessibilityValue(values.isEmpty ? "未填写" : values.joined(separator: "，"))
      .popover(isPresented: suggestionsPresented, arrowEdge: .trailing) {
        VStack(alignment: .leading, spacing: 7) {
          Text("建议\(title)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ForEach(filteredSuggestions.prefix(10), id: \.self) { suggestion in
            Button {
              append(suggestion)
            } label: {
              Label(suggestion, systemImage: "plus.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(12)
        .frame(width: 230)
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

  private func append(_ suggestion: String) {
    guard !values.contains(where: { $0.caseInsensitiveCompare(suggestion) == .orderedSame }) else { return }
    values.append(suggestion)
  }

  private func parse(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0 == "，" })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
