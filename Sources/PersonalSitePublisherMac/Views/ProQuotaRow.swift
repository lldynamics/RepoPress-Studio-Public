import SwiftUI

struct ProQuotaRow: View {
  let title: String
  let used: Int
  let remaining: Int
  let systemImage: String

  var body: some View {
    HStack {
      Label(title, systemImage: systemImage)
      Spacer()
      Text("已用 \(used) · 剩余 \(remaining)")
        .foregroundStyle(remaining > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
    }
  }
}
