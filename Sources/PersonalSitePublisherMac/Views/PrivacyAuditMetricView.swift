import SwiftUI

struct PrivacyAuditMetricView: View {
  let title: String
  let value: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(value)")
        .font(.title3.weight(.semibold))
        .monospacedDigit()

      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
