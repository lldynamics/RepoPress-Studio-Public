import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsVisibilitySection: View {
  let masksPrivateContent: Binding<Bool>

  var body: some View {
    Section("私密内容") {
      Toggle(
        String(localized: "遮挡私密文章内容和路径（标题仍显示）"),
        isOn: masksPrivateContent
      )
      .accessibilityLabel("遮挡私密文章内容和路径，标题仍显示")
      .accessibilityValue(masksPrivateContent.wrappedValue ? "开启" : "关闭")
    }
  }
}
