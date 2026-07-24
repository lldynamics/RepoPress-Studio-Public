import PublishingWorkbenchCore
import SwiftUI

struct AIWritingStyleSection: View {
  let presetBinding: Binding<AIWritingStylePreset>
  let presetDisplayName: String
  let toneText: Binding<String>
  let audienceText: Binding<String>
  let summaryGuidanceText: Binding<String>
  let tagGuidanceText: Binding<String>
  let seoGuidanceText: Binding<String>
  @State private var showsCustomRules = false

  var body: some View {
    Section("写作风格") {
      Picker("预设", selection: presetBinding) {
        ForEach(AIWritingStylePreset.allCases) { preset in
          Text(preset.localizedDisplayName).tag(preset)
        }
      }
      .accessibilityLabel("AI 写作风格预设")
      .accessibilityValue(presetDisplayName)

      DisclosureGroup(String(localized: "自定义写作规则"), isExpanded: $showsCustomRules) {
        AIWritingStyleEditor(
          title: "语气",
          text: toneText,
          accessibilityValue: toneText.wrappedValue
        )

        AIWritingStyleEditor(
          title: "目标读者",
          text: audienceText,
          accessibilityValue: audienceText.wrappedValue
        )

        AIWritingStyleEditor(
          title: "摘要规则",
          text: summaryGuidanceText,
          accessibilityValue: summaryGuidanceText.wrappedValue
        )

        AIWritingStyleEditor(
          title: "标签规则",
          text: tagGuidanceText,
          accessibilityValue: tagGuidanceText.wrappedValue
        )

        AIWritingStyleEditor(
          title: "SEO 检查重点",
          text: seoGuidanceText,
          accessibilityValue: seoGuidanceText.wrappedValue
        )

        Text("这些规则会随当前站点配置进入 AI 聊天、元数据建议、发布检查、选区编辑和图片替代文本/说明建议。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}
