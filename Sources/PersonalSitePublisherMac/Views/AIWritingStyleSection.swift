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
    Group {
      Section("行内 AI 续写") {
        Text("在编辑器正文中按 Option + 反斜杠主动请求续写；生成后按 Tab 采纳，按 Esc 丢弃。停顿、输入和移动光标都不会自动发送请求。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Section("写作风格") {
        VStack(alignment: .leading, spacing: 6) {
          Text("场景模板：")
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(AIWritingStylePreset.allCases.filter { $0 != .custom }) { preset in
                Button {
                  presetBinding.wrappedValue = preset
                } label: {
                  Text(preset.localizedDisplayName)
                    .font(.caption.weight(presetBinding.wrappedValue == preset ? .bold : .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                      presetBinding.wrappedValue == preset
                        ? WorkbenchTheme.brand.opacity(0.15)
                        : Color.primary.opacity(0.06),
                      in: RoundedRectangle(cornerRadius: 6)
                    )
                    .foregroundStyle(
                      presetBinding.wrappedValue == preset ? WorkbenchTheme.brand : Color.primary
                    )
                }
                .buttonStyle(.plain)
              }
            }
          }
        }
        .padding(.vertical, 2)

        Picker("预设", selection: presetBinding) {
          ForEach(AIWritingStylePreset.allCases) { preset in
            Text(preset.localizedDisplayName).tag(preset)
          }
        }
        .accessibilityLabel("AI 写作风格预设")
        .accessibilityValue(presetDisplayName)

        DisclosureGroup(String(localized: "自定义写作规则"), isExpanded: $showsCustomRules) {
          VStack(alignment: .leading, spacing: 6) {
            Text("常用语气预设：")
              .font(.workbenchMetadata)
              .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: true) {
              HStack(spacing: 6) {
                ForEach(["专业严谨", "极简干货", "幽默风趣", "亲切随笔"], id: \.self) { pill in
                  Button {
                    if toneText.wrappedValue.isEmpty {
                      toneText.wrappedValue = pill
                    } else if !toneText.wrappedValue.contains(pill) {
                      toneText.wrappedValue += "，\(pill)"
                    }
                  } label: {
                    Text(pill)
                      .font(.workbenchMetadata.weight(.medium))
                      .padding(.horizontal, 8)
                      .padding(.vertical, 3)
                      .background(Color.primary.opacity(0.06), in: Capsule())
                  }
                  .buttonStyle(.plain)
                }
              }
            }
          }
          .padding(.vertical, 2)

          AIWritingStyleEditor(
            title: "语气",
            text: toneText,
            accessibilityValue: toneText.wrappedValue
          )

          VStack(alignment: .leading, spacing: 6) {
            Text("常用读者预设：")
              .font(.workbenchMetadata)
              .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: true) {
              HStack(spacing: 6) {
                ForEach(["开发者与程序员", "技术小白与初学者", "独立博主与创作者"], id: \.self) { pill in
                  Button {
                    if audienceText.wrappedValue.isEmpty {
                      audienceText.wrappedValue = pill
                    } else if !audienceText.wrappedValue.contains(pill) {
                      audienceText.wrappedValue += "，\(pill)"
                    }
                  } label: {
                    Text(pill)
                      .font(.workbenchMetadata.weight(.medium))
                      .padding(.horizontal, 8)
                      .padding(.vertical, 3)
                      .background(Color.primary.opacity(0.06), in: Capsule())
                  }
                  .buttonStyle(.plain)
                }
              }
            }
          }
          .padding(.vertical, 2)

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
}
