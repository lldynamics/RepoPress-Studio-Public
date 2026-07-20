import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsAutoLockSection: View {
  @Binding var locksWhenInactive: Bool
  @Binding var inactivityLockDelayMinutes: Int

  var body: some View {
    Section(String(localized: "自动锁定")) {
      Toggle(String(localized: "无操作时自动锁定软件"), isOn: $locksWhenInactive)
        .accessibilityValue(locksWhenInactive ? "开启" : "关闭")

      if locksWhenInactive {
        Stepper(
          value: $inactivityLockDelayMinutes,
          in: Self.inactivityLockDelayRange
        ) {
          LabeledContent(String(localized: "无操作时间")) {
            Text(formattedDelay)
              .monospacedDigit()
          }
        }
        .accessibilityLabel(String(localized: "自动锁定前的无操作时间"))
        .accessibilityValue(formattedDelay)

        Text(String(localized: "最少 1 分钟，最多 240 分钟。切换到其他应用后也会继续计时。"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      LabeledContent(String(localized: "立即锁定快捷键")) {
        Text(verbatim: "⌃⌘L")
          .font(.body.monospaced())
      }
    }
  }

  private var formattedDelay: String {
    String.localizedStringWithFormat(
      String(localized: "%@ 分钟"),
      String(inactivityLockDelayMinutes)
    )
  }

  private static let minimumDelay = PrivacyProtectionSettings.minimumInactivityLockDelayMinutes
  private static let maximumDelay = PrivacyProtectionSettings.maximumInactivityLockDelayMinutes
  private static let inactivityLockDelayRange = minimumDelay...maximumDelay
}
