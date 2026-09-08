import SwiftUI

struct PrivacySettingsVisibilitySection: View {
  let masksPrivateContent: Binding<Bool>
  let subsectionAnchor: SettingsSubsection?

  init(
    masksPrivateContent: Binding<Bool>,
    subsectionAnchor: SettingsSubsection? = nil
  ) {
    self.masksPrivateContent = masksPrivateContent
    self.subsectionAnchor = subsectionAnchor
  }

  var body: some View {
    Section {
      Toggle(
        String(localized: "遮挡私密文章内容和路径（标题仍显示）"),
        isOn: masksPrivateContent
      )
      .accessibilityLabel("遮挡私密文章内容和路径，标题仍显示")
      .accessibilityValue(masksPrivateContent.wrappedValue ? "开启" : "关闭")
    } header: {
      Text("私密内容")
        .settingsSubsectionAnchor(subsectionAnchor)
    }
  }
}
