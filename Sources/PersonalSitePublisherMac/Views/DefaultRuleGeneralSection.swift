import PublishingWorkbenchCore
import SwiftUI

struct DefaultRuleGeneralSection: View {
  @Binding var defaultShowsInspector: Bool
  let autoRunPreflightBinding: Binding<Bool>
  @Binding var scanRepositoryOnLaunch: Bool

  var body: some View {
    Section("工作台默认") {
      Toggle("启动时显示 Inspector", isOn: $defaultShowsInspector)
        .accessibilityLabel("启动时显示 Inspector")
        .accessibilityValue(defaultShowsInspector ? "开启" : "关闭")

      Toggle("编辑后自动刷新发布检查", isOn: autoRunPreflightBinding)
        .accessibilityLabel("编辑后自动刷新发布检查")
        .accessibilityValue(autoRunPreflightBinding.wrappedValue ? "开启" : "关闭")

      Toggle("启动时自动扫描仓库", isOn: $scanRepositoryOnLaunch)
        .accessibilityLabel("启动时自动扫描仓库")
        .accessibilityValue(scanRepositoryOnLaunch ? "开启" : "关闭")
    }
  }
}
