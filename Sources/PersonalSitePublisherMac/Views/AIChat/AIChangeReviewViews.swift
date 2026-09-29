import SwiftUI

/// A consistent before/after presentation used by chat and inline reviews.
/// The compact layout keeps the same terminology when the available width is narrow.
struct AIChangeComparisonView: View {
  let before: String
  let after: String

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 12) {
        valueColumn("修改前", before, isAfter: false).frame(minWidth: 200)
        valueColumn("建议修改", after, isAfter: true).frame(minWidth: 200)
      }
      VStack(alignment: .leading, spacing: 6) {
        valueColumn("修改前", before, isAfter: false)
        valueColumn("建议修改", after, isAfter: true)
      }
    }
  }

  private func valueColumn(_ title: LocalizedStringKey, _ value: String, isAfter: Bool) -> some View
  {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value.isEmpty ? (isAfter ? String(localized: "清空") : String(localized: "未设置")) : value)
        .font(.callout)
        .foregroundStyle(isAfter ? WorkbenchTheme.primary : .secondary)
        .strikethrough(!isAfter && !value.isEmpty)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
