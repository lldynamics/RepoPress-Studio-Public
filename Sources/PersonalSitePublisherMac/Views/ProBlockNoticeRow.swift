import PublishingWorkbenchCore
import SwiftUI

struct ProBlockNoticeRow: View {
  let notice: ProFeatureBlockNotice

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("刚才受限：\(notice.feature.localizedDisplayName)", systemImage: notice.feature.systemImage)
        .font(.workbenchCardTitle)
        .foregroundStyle(WorkbenchTheme.warning)

      Text(notice.message)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Text(notice.nextStep)
        .font(.workbenchSupporting)
        .foregroundStyle(WorkbenchTheme.warning)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchTheme.warning.opacity(WorkbenchOpacity.selectionBackground), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}
