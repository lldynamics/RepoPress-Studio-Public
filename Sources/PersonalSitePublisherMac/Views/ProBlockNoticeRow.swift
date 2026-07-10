import PublishingWorkbenchCore
import SwiftUI

struct ProBlockNoticeRow: View {
  let notice: ProFeatureBlockNotice

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("刚才受限：\(notice.feature.displayName)", systemImage: notice.feature.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)

      Text(notice.message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)

      Text(notice.nextStep)
        .font(.caption)
        .foregroundStyle(.orange)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.orange.opacity(WorkbenchOpacity.selectionBackground), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}
