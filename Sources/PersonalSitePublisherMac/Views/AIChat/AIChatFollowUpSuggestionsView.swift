import PublishingWorkbenchCore
import SwiftUI

struct AIChatFollowUpSuggestionsView: View {
  let suggestions: [AIChatFollowUpSuggestion]
  let isChatRunning: Bool
  let draft: ArticleDraft
  let onSelect: (AIChatFollowUpSuggestion) -> Void

  var body: some View {
    if !suggestions.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 4) {
          Image(systemName: "sparkles")
            .font(.workbenchMetadata.weight(.semibold))
            .foregroundStyle(.workbenchSecondary)
          Text(String(localized: "建议下一步："))
            .font(.workbenchMetadata.weight(.medium))
            .foregroundStyle(.workbenchSecondary)
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(suggestions) { suggestion in
              Button {
                onSelect(suggestion)
              } label: {
                HStack(spacing: 5) {
                  if let icon = suggestion.icon {
                    Image(systemName: icon)
                      .font(.workbenchMetadata)
                  }
                  Text(suggestion.title)
                    .font(.workbenchMetadata.weight(.medium))
                }
                .padding(.horizontal, WorkbenchSpacing.control)
                .padding(.vertical, WorkbenchSpacing.tight)
                .background(
                  Color.primary.opacity(suggestion.kind == .toolAction ? 0.08 : 0.05),
                  in: Capsule()
                )
                .overlay {
                  Capsule()
                    .stroke(
                      Color.primary.opacity(suggestion.kind == .toolAction ? 0.18 : 0.1),
                      lineWidth: 1
                    )
                }
              }
              .buttonStyle(.plain)
              .disabled(isChatRunning)
              .help(suggestion.prompt)
              .accessibilityLabel(suggestion.title)
              .accessibilityHint(suggestion.prompt)
            }
          }
          .padding(.vertical, 2)
        }
      }
      .padding(.top, WorkbenchSpacing.tight)
    }
  }
}
