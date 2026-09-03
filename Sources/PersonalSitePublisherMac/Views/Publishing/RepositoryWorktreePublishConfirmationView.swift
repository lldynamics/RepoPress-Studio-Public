import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// Final user-visible boundary for the default repository-wide publish.
/// Nothing is staged until the user confirms this exact frozen snapshot.
struct RepositoryWorktreePublishConfirmationView: View {
  let confirmation: RepositoryWorktreePublishConfirmation
  let isPublishing: Bool
  let cancelAction: () -> Void
  let confirmAction: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          targetCard
          preflightCard
          if !confirmation.safetyReport.warnings.isEmpty {
            safetyWarningsCard
          }
          fileList
          safetyNote
        }
        .padding(WorkbenchSpacing.spacious)
      }
      Divider()
      footer
    }
    .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 650)
    .accessibilityIdentifier("publish-worktree-confirmation")
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "shippingbox.and.arrow.backward.fill")
        .font(.title2)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 3) {
        Text("确认发布仓库全部文件")
          .font(.headline)
        Text("确认后会再次检查站点，再提交、非强制推送，并继续验证部署与文章页面。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(WorkbenchSpacing.spacious)
  }

  private var targetCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("发布目标", systemImage: "arrow.triangle.branch")
        .font(.headline)
      LabeledContent("分支", value: "origin/\(confirmation.snapshot.branch)")
      LabeledContent("当前提交", value: String(confirmation.snapshot.headSHA.prefix(12)))
      LabeledContent("提交说明", value: confirmation.commitMessage)
      LabeledContent(
        "完整清单",
        value: String(
          format: String(localized: "%d 个文件路径"),
          confirmation.snapshot.paths.count
        )
      )
      if let articleTarget = confirmation.articleVerificationTarget {
        LabeledContent("线上文章验证", value: articleTarget.title)
      } else {
        LabeledContent("线上文章验证", value: String(localized: "未冻结具体文章目标"))
      }
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private var preflightCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("站点发布前检查", systemImage: preflightIcon)
        .font(.headline)
        .foregroundStyle(preflightColor)
      Text(confirmation.sitePreflightResult?.message ?? "尚未生成站点检查证据。")
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(confirmation.sitePreflightResult?.diagnostics ?? [], id: \.self) { diagnostic in
        Text(diagnostic)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityIdentifier("publish-worktree-preflight")
  }

  private var safetyWarningsCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("需要重点复核", systemImage: "exclamationmark.triangle.fill")
        .font(.headline)
        .foregroundStyle(WorkbenchTheme.warning)
      ForEach(confirmation.safetyReport.warnings) { warning in
        VStack(alignment: .leading, spacing: 3) {
          Text(warning.title)
            .font(.callout.weight(.semibold))
          Text(warning.message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchTheme.warning.opacity(0.08),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private var fileList: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("全部待推送文件", systemImage: "list.bullet.rectangle")
        .font(.headline)

      ForEach(confirmation.snapshot.entries) { entry in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(entry.kind.localizedName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color(for: entry.kind))
            .frame(width: 52, alignment: .leading)

          VStack(alignment: .leading, spacing: 2) {
            Text(entry.path)
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
            if let sourcePath = entry.sourcePath {
              Text("原路径：\(sourcePath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
          }

          Spacer(minLength: 10)

          if entry.kind != .deleted {
            Text(Self.byteCount(entry.byteSize))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.kind.localizedName)，\(entry.path)")

        if entry.id != confirmation.snapshot.entries.last?.id {
          Divider()
        }
      }
    }
    .padding(WorkbenchSpacing.section)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityIdentifier("publish-worktree-file-list")
  }

  private var safetyNote: some View {
    Label(
      "提交前会重新运行站点检查，并核对每个文件、HEAD 和远端 SHA。Git 推送只是中间状态；只有部署归因及文章内容与 canonical/og:url 验证通过，才会显示发布成功。",
      systemImage: "lock.shield"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Button("取消", action: cancelAction)
        .keyboardShortcut(.cancelAction)
        .disabled(isPublishing)

      Spacer()

      if isPublishing {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在提交并推送全部文件")
      }

      Button("确认并发布全部文件", action: confirmAction)
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(isPublishing)
        .accessibilityIdentifier("publish-worktree-confirm")
        .accessibilityHint("重新检查站点，提交并推送全部路径，然后验证部署和文章页面")
    }
    .padding(WorkbenchSpacing.spacious)
  }

  private var preflightIcon: String {
    switch confirmation.sitePreflightResult?.outcome {
    case .passed:
      "checkmark.shield.fill"
    case .skipped:
      "minus.circle"
    case .failed, nil:
      "xmark.shield.fill"
    }
  }

  private var preflightColor: Color {
    switch confirmation.sitePreflightResult?.outcome {
    case .passed:
      WorkbenchTheme.success
    case .skipped:
      .secondary
    case .failed, nil:
      WorkbenchTheme.risk
    }
  }

  private func color(for kind: RepositoryWorktreePublishEntryKind) -> Color {
    switch kind {
    case .added, .copied:
      WorkbenchTheme.success
    case .modified, .renamed, .typeChanged:
      WorkbenchTheme.warning
    case .deleted:
      WorkbenchTheme.risk
    }
  }

  private static func byteCount(_ value: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    return formatter.string(fromByteCount: value)
  }
}
