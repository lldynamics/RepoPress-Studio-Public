import PublishingWorkbenchCore
import SwiftUI

struct SiteKindChangeConfirmationView: View {
  let currentProfile: SiteProfile
  let targetKind: SiteKind
  let cancelAction: () -> Void
  let confirmAction: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Label("预览站点类型变化", systemImage: "arrow.left.arrow.right")
          .font(.title3.weight(.semibold))
        Text("从 \(currentProfile.siteKind.localizedDisplayName) 切换到 \(targetKind.localizedDisplayName) 会更新以下发布规则。仓库、访问令牌、作者和默认标签不会改变。")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if changes.isEmpty {
            Label("当前规则已经与目标站点类型一致。", systemImage: "checkmark.circle")
              .foregroundStyle(.secondary)
          } else {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
              GridRow {
                Text("规则").font(.caption.weight(.semibold))
                Text("当前值").font(.caption.weight(.semibold))
                Text("应用后").font(.caption.weight(.semibold))
              }
              .foregroundStyle(.secondary)

              Divider().gridCellColumns(3)

              ForEach(changes) { change in
                GridRow(alignment: .firstTextBaseline) {
                  Text(change.title)
                    .font(.callout.weight(.medium))
                  Text(change.before)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                  Text(change.after)
                    .font(.caption.monospaced())
                    .foregroundStyle(WorkbenchTheme.primary)
                    .textSelection(.enabled)
                }
              }
            }
            .padding(14)
            .background(
              WorkbenchBackgroundStyle.card,
              in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
            )
          }
        }
        .padding(20)
      }

      Divider()

      HStack {
        Button("取消", action: cancelAction)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Text("将更新 \(changes.count) 项发布规则")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button {
          confirmAction()
        } label: {
          Label("应用站点类型", systemImage: "checkmark.circle")
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(changes.isEmpty)
      }
      .padding(16)
    }
    .frame(minWidth: 660, idealWidth: 760, minHeight: 520, idealHeight: 620)
    .workbenchGlassContainer(material: .regularMaterial)
  }

  private var proposedProfile: SiteProfile {
    var profile = currentProfile
    profile.applyPublishingDefaults(for: targetKind)
    return profile
  }

  private var changes: [SiteKindRuleChange] {
    let proposed = proposedProfile
    return [
      SiteKindRuleChange(title: "站点类型", before: currentProfile.siteKind.localizedDisplayName, after: proposed.siteKind.localizedDisplayName),
      SiteKindRuleChange(title: "文章头信息", before: currentProfile.frontMatterStyle.localizedDisplayName, after: proposed.frontMatterStyle.localizedDisplayName),
      SiteKindRuleChange(title: "内容目录", before: currentProfile.contentRoot, after: proposed.contentRoot),
      SiteKindRuleChange(title: "资源目录", before: currentProfile.assetRoot, after: proposed.assetRoot),
      SiteKindRuleChange(title: "文章路径", before: currentProfile.markdownPathPattern, after: proposed.markdownPathPattern),
      SiteKindRuleChange(title: "图片路径", before: currentProfile.imagePathPattern, after: proposed.imagePathPattern),
      SiteKindRuleChange(title: "公开图片路径", before: currentProfile.publicImagePathPattern, after: proposed.publicImagePathPattern),
      SiteKindRuleChange(title: "日期格式", before: currentProfile.dateFormat, after: proposed.dateFormat),
      SiteKindRuleChange(title: "包含 draft 字段", before: enabledText(currentProfile.includeDraftFlagInFrontMatter), after: enabledText(proposed.includeDraftFlagInFrontMatter)),
      SiteKindRuleChange(title: "包含封面图字段", before: enabledText(currentProfile.includeCoverInFrontMatter), after: enabledText(proposed.includeCoverInFrontMatter)),
      SiteKindRuleChange(title: "Slug 规则", before: currentProfile.slugValidationRule.localizedDisplayName, after: proposed.slugValidationRule.localizedDisplayName),
    ]
    .filter { $0.before != $0.after }
  }

  private func enabledText(_ isEnabled: Bool) -> String {
    isEnabled ? String(localized: "开启") : String(localized: "关闭")
  }
}

private struct SiteKindRuleChange: Identifiable {
  let id = UUID()
  let title: LocalizedStringKey
  let before: String
  let after: String
}
