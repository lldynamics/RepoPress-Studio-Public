import SwiftUI

struct AIWritingStyleEditor: View {
  let title: String
  let text: Binding<String>
  let accessibilityValue: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      TextEditor(text: text)
        .font(.body)
        .frame(minHeight: 58, idealHeight: 72, maxHeight: 96)
        .padding(5)
        .background(
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .accessibilityLabel("AI \(title)")
        .accessibilityValue(accessibilityValue)
    }
  }
}
