import PublishingWorkbenchCore
import SwiftUI

struct DraftOwnershipTransferConfirmationView: View {
  let plan: DraftOwnershipTransferPlan
  let onConfirm: (DraftOwnershipTransferPlan) -> Bool

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if !plan.conflicts.isEmpty {
            conflictSummary
          }

          ForEach(plan.items) { item in
            transferItem(item)
          }

          Label(
            String(localized: "归属变更只更新工作台中的草稿，不会修改或删除原站点仓库文件。"),
            systemImage: "externaldrive.badge.checkmark"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
      }

      Divider()

      HStack(spacing: 10) {
        Spacer()

        Button(String(localized: "取消"), role: .cancel) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button(confirmButtonTitle) {
          if onConfirm(plan) {
            dismiss()
          }
        }
        .keyboardShortcut(.defaultAction)
        .workbenchProminentActionStyle()
        .disabled(!plan.canApply)
        .help(plan.canApply ? confirmButtonHelp : String(localized: "请先处理冲突后重新打开此面板"))
      }
      .padding(16)
    }
    .frame(minWidth: 640, idealWidth: 700, minHeight: 480, idealHeight: 620)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: headerSystemImage)
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(plan.conflicts.isEmpty ? Color.accentColor : WorkbenchTheme.risk)
        .frame(width: 42, height: 42)
        .background(
          (plan.conflicts.isEmpty ? Color.accentColor : WorkbenchTheme.risk)
            .opacity(WorkbenchOpacity.accentBackground),
          in: RoundedRectangle(cornerRadius: 10)
        )

      VStack(alignment: .leading, spacing: 5) {
        Text(panelTitle)
          .font(.title2.weight(.semibold))

        Text(panelSummary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(20)
  }

  private var conflictSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        Text("发现 \(plan.conflicts.count) 项冲突，当前操作不会执行")
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      .font(.headline)
      .foregroundStyle(WorkbenchTheme.risk)

      Text("修改重复文章的 slug 或日期后，再重新选择目标站点。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchTheme.risk.opacity(WorkbenchOpacity.accentBackground), in: RoundedRectangle(cornerRadius: 10))
  }

  private func transferItem(_ item: DraftOwnershipTransferItem) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        transferValueRow(
          label: String(localized: "归属"),
          source: item.sourceProfileName,
          target: item.targetProfileName
        )
        transferValueRow(
          label: String(localized: "Markdown 路径"),
          source: item.sourceMarkdownPath ?? String(localized: "不绑定站点"),
          target: item.targetMarkdownPath ?? String(localized: "不再生成站点路径")
        )
        transferValueRow(
          label: String(localized: "永久链接"),
          source: item.sourcePermalink ?? String(localized: "不绑定站点"),
          target: item.targetPermalink ?? String(localized: "不再生成站点永久链接")
        )

        ForEach(item.conflicts) { conflict in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(conflict.title)
                .font(.caption.weight(.semibold))
              Text(conflict.message)
                .font(.caption)
            }
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
          }
          .foregroundStyle(WorkbenchTheme.risk)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.vertical, 4)
    } label: {
      Text(item.title)
        .font(.headline)
        .lineLimit(2)
    }
  }

  private func transferValueRow(label: String, source: String, target: String) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
      GridRow {
        Text(label)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 108, alignment: .leading)

        Text(source)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      GridRow {
        Text("")
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "arrow.down")
            .foregroundStyle(.secondary)
          Text(target)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var panelTitle: String {
    switch plan.operation {
    case .moveToSite:
      return plan.isBatch ? String(localized: "批量移动到站点") : String(localized: "移动到站点")
    case .copyToSite:
      return plan.isBatch ? String(localized: "批量复制到站点") : String(localized: "复制到站点")
    case .moveToGeneral:
      return plan.isBatch ? String(localized: "批量转为通用草稿") : String(localized: "转为通用草稿")
    }
  }

  private var panelSummary: String {
    switch plan.operation {
    case .moveToSite:
      return String(localized: "原稿将改为归属目标站点，并重置发布状态与仓库关联。")
    case .copyToSite:
      return String(localized: "原稿保持不变，在目标站点创建一份可独立编辑的新草稿。")
    case .moveToGeneral:
      return String(localized: "文章将解除站点归属并保留正文，之后不能直接发布。")
    }
  }

  private var headerSystemImage: String {
    switch plan.operation {
    case .moveToSite:
      return "arrow.right.doc.on.clipboard"
    case .copyToSite:
      return "doc.on.doc"
    case .moveToGeneral:
      return "tray.and.arrow.down"
    }
  }

  private var confirmButtonTitle: String {
    switch plan.operation {
    case .moveToSite:
      return plan.isBatch ? String(localized: "确认批量移动") : String(localized: "确认移动")
    case .copyToSite:
      return plan.isBatch ? String(localized: "确认批量复制") : String(localized: "确认复制")
    case .moveToGeneral:
      return plan.isBatch ? String(localized: "确认批量转换") : String(localized: "确认转换")
    }
  }

  private var confirmButtonHelp: String {
    plan.isBatch
      ? String(localized: "执行后可撤销本次批量归属变更")
      : String(localized: "执行后可撤销本次归属变更")
  }
}
