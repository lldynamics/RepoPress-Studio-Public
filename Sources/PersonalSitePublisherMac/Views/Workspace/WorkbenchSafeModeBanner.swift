import AppKit
import SwiftUI

struct WorkbenchSafeModeBanner: View {
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Label("安全模式", systemImage: "wrench.and.screwdriver")
        .font(.workbenchBody.weight(.semibold))

      Text("自动预检、预览和后台维护已暂停；关闭应用后重新打开即可退出安全模式。")
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
        .lineLimit(2)

      Spacer(minLength: 8)

      Button("退出安全模式") {
        NSApp.terminate(nil)
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("退出安全模式并关闭应用")
    }
    .padding(.horizontal, WorkbenchSpacing.content)
    .padding(.vertical, WorkbenchSpacing.control)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchTheme.warning.opacity(0.12))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(WorkbenchTheme.warning.opacity(0.35))
        .frame(height: 1)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("安全模式")
    .accessibilityValue(String(localized: "自动预检、预览和后台维护已暂停"))
  }
}
