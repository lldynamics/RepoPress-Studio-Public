import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsLockSection: View {
  let requiresUnlockOnLaunch: Binding<Bool>
  let locksWhenInactive: Binding<Bool>

  var body: some View {
    Section("隐私界面遮罩") {
      Toggle(
        "启动时显示遮罩",
        isOn: requiresUnlockOnLaunch
      )
      .accessibilityLabel("启动时显示隐私界面遮罩")
      .accessibilityValue(requiresUnlockOnLaunch.wrappedValue ? "开启" : "关闭")

      Toggle(
        "切到后台时自动显示遮罩",
        isOn: locksWhenInactive
      )
      .accessibilityLabel("切到后台时自动显示隐私界面遮罩")
      .accessibilityValue(locksWhenInactive.wrappedValue ? "开启" : "关闭")
    }
  }
}
