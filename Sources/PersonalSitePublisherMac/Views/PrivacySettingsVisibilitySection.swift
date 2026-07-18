import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsVisibilitySection: View {
  let masksPrivateContent: Binding<Bool>

  var body: some View {
    Section("私密内容") {
      Toggle(
        "在列表和概览中遮挡私密文章",
        isOn: masksPrivateContent
      )
      .accessibilityLabel("在列表和概览中遮挡私密文章")
      .accessibilityValue(masksPrivateContent.wrappedValue ? "开启" : "关闭")
    }
  }
}
