import SwiftUI

struct DefaultRuleGeneralSection: View {
  let autoRunPreflightBinding: Binding<Bool>
  @Binding var scanRepositoryOnLaunch: Bool
  let subsectionAnchor: SettingsSubsection?

  init(
    autoRunPreflightBinding: Binding<Bool>,
    scanRepositoryOnLaunch: Binding<Bool>,
    subsectionAnchor: SettingsSubsection? = nil
  ) {
    self.autoRunPreflightBinding = autoRunPreflightBinding
    _scanRepositoryOnLaunch = scanRepositoryOnLaunch
    self.subsectionAnchor = subsectionAnchor
  }

  var body: some View {
    Section {
      Toggle("编辑后自动刷新发布检查", isOn: autoRunPreflightBinding)
        .accessibilityLabel("编辑后自动刷新发布检查")
        .accessibilityValue(autoRunPreflightBinding.wrappedValue ? "开启" : "关闭")

      Toggle("启动时自动扫描仓库", isOn: $scanRepositoryOnLaunch)
        .accessibilityLabel("启动时自动扫描仓库")
        .accessibilityValue(scanRepositoryOnLaunch ? "开启" : "关闭")
    } header: {
      Text("工作台行为")
        .settingsSubsectionAnchor(subsectionAnchor)
    }
  }
}
