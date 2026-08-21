import PublishingWorkbenchCore
import SwiftUI

struct PublishDrawerActionChoice: View {
  let title: String
  let detail: String
  let status: String
  let systemImage: String
  let tint: Color
  let isEnabled: Bool
  let isPrimary: Bool
  let actionTitle: String
  let actionSystemImage: String
  let actionIdentifier: String
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Label(status, systemImage: isEnabled ? "checkmark.circle" : "info.circle")
        .font(.caption)
        .foregroundStyle(isEnabled ? tint : .secondary)

      Spacer(minLength: 0)

      if isPrimary {
        Button(action: action) {
          Label(actionTitle, systemImage: actionSystemImage)
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(!isEnabled)
        .accessibilityIdentifier(actionIdentifier)
      } else {
        Button(action: action) {
          Label(actionTitle, systemImage: actionSystemImage)
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
        .accessibilityIdentifier(actionIdentifier)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(tint.opacity(isEnabled ? 0.35 : 0.15), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityValue(status)
  }
}

private struct PublishDrawerReadinessIssue: Identifiable {
  let id: String
  let severity: PreflightSeverity
  let title: String
  let message: String
}

private struct PublishDrawerReadinessSection: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let issues: [PublishDrawerReadinessIssue]
  let isLoading: Bool

  var errorCount: Int {
    issues.filter { $0.severity == .error }.count
  }

  var warningCount: Int {
    issues.filter { $0.severity == .warning }.count
  }

  var tint: Color {
    if errorCount > 0 {
      return WorkbenchTheme.risk
    }
    if warningCount > 0 {
      return WorkbenchTheme.warning
    }
    return WorkbenchTheme.success
  }

  var statusTitle: String {
    if isLoading {
      return "检查中"
    }
    if errorCount > 0 {
      return "\(errorCount) 个阻断"
    }
    if warningCount > 0 {
      return "\(warningCount) 个提醒"
    }
    return "通过"
  }
}

struct PublishDrawerReadinessChecklist: View {
  let preflightIssues: [PreflightIssue]
  let imageReport: ImageWorkbenchReport?
  let isImageReportLoading: Bool
  let seoReport: SEOAuditReport
  let socialSnapshot: SEOSocialPreviewSnapshot?
  let isSocialPreviewStale: Bool

  @State private var expandedSectionIDs: Set<String> = ["preflight"]

  var body: some View {
    let sections = readinessSections
    let blockingCount = sections.reduce(0) { $0 + $1.errorCount }
    let warningCount = sections.reduce(0) { $0 + $1.warningCount }
    let isLoading = sections.contains(where: \.isLoading)

    PublishDrawerCard(title: "发布就绪清单", systemImage: "checklist.checked") {
      Text("Preflight、图片、SEO 和社交卡片在同一处复核，发布前只需要看这一张清单。")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        PublishDrawerStat(
          title: "阻断",
          value: "\(blockingCount)",
          systemImage: "xmark.octagon",
          color: blockingCount == 0 ? .secondary : WorkbenchTheme.risk
        )
        PublishDrawerStat(
          title: "提醒",
          value: "\(warningCount)",
          systemImage: "exclamationmark.triangle",
          color: warningCount == 0 ? .secondary : WorkbenchTheme.warning
        )
        PublishDrawerStat(
          title: "检查项",
          value: "\(sections.count)",
          systemImage: "square.grid.2x2",
          color: .secondary
        )
      }

      Label(
        isLoading
          ? "正在准备图片或社交预览检查…"
          : blockingCount > 0
            ? "处理阻断项后再发布。"
            : warningCount > 0
              ? "可以发布，但建议先确认提醒。"
              : "四类发布检查均已通过。",
        systemImage: isLoading
          ? "arrow.clockwise"
          : blockingCount > 0
            ? "xmark.octagon"
            : warningCount > 0
              ? "exclamationmark.triangle"
              : "checkmark.circle"
      )
      .font(.caption.weight(.medium))
      .foregroundStyle(
        isLoading
          ? .secondary
          : blockingCount > 0
            ? WorkbenchTheme.risk
            : warningCount > 0
              ? WorkbenchTheme.warning
              : WorkbenchTheme.success
      )

      VStack(alignment: .leading, spacing: 6) {
        ForEach(sections) { section in
          if section.issues.isEmpty && !section.isLoading {
            readinessSectionLabel(section)
          } else {
            DisclosureGroup(isExpanded: expandedBinding(for: section.id)) {
              VStack(alignment: .leading, spacing: 7) {
                if section.isLoading {
                  Label("正在读取最新检查结果…", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ForEach(section.issues) { issue in
                  readinessIssueRow(issue)
                }
              }
              .padding(.top, 5)
            } label: {
              readinessSectionLabel(section)
            }
          }
        }
      }
    }
    .accessibilityIdentifier("publish-drawer-readiness-checklist")
  }

  private var readinessSections: [PublishDrawerReadinessSection] {
    let preflight =
      preflightIssues
      .filter { $0.severity != .info }
      .map { issue in
        PublishDrawerReadinessIssue(
          id: "preflight-\(issue.id.uuidString)",
          severity: issue.severity,
          title: issue.title,
          message: issue.message
        )
      }

    let imageIssues =
      imageReport?.issues
      .filter { !$0.isCovered(by: preflightIssues) }
      .map { issue in
        PublishDrawerReadinessIssue(
          id: "image-\(issue.id.uuidString)",
          severity: issue.severity,
          title: issue.title,
          message: issue.message
        )
      } ?? []

    let seoIssues = seoReport.findings
      .filter { $0.severity != .info }
      .map { finding in
        PublishDrawerReadinessIssue(
          id: "seo-\(finding.id.uuidString)",
          severity: finding.severity,
          title: finding.title,
          message: finding.message
        )
      }

    var socialIssues =
      socialSnapshot?.findings
      .filter { $0.severity != .info }
      .map { finding in
        PublishDrawerReadinessIssue(
          id: "social-\(finding.id.uuidString)",
          severity: finding.severity,
          title: finding.title,
          message: finding.message
        )
      } ?? []
    if socialSnapshot == nil {
      socialIssues.append(
        PublishDrawerReadinessIssue(
          id: "social-missing",
          severity: .warning,
          title: "社交预览尚未生成",
          message: "刷新社交预览后才能确认 Open Graph、Twitter/X 和 JSON-LD 字段。"
        )
      )
    } else if isSocialPreviewStale {
      socialIssues.append(
        PublishDrawerReadinessIssue(
          id: "social-stale",
          severity: .warning,
          title: "社交预览需要刷新",
          message: "文章元数据已变化，当前卡片快照不是最新版本。"
        )
      )
    }

    return [
      PublishDrawerReadinessSection(
        id: "preflight",
        title: "Preflight",
        systemImage: "shield.checkered",
        issues: preflight,
        isLoading: false
      ),
      PublishDrawerReadinessSection(
        id: "images",
        title: "图片",
        systemImage: "photo",
        issues: imageIssues,
        isLoading: isImageReportLoading && imageReport == nil
      ),
      PublishDrawerReadinessSection(
        id: "seo",
        title: "SEO",
        systemImage: "magnifyingglass",
        issues: seoIssues,
        isLoading: false
      ),
      PublishDrawerReadinessSection(
        id: "social",
        title: "社交卡片",
        systemImage: "rectangle.inset.filled",
        issues: socialIssues,
        isLoading: false
      ),
    ]
  }

  private func readinessSectionLabel(_ section: PublishDrawerReadinessSection) -> some View {
    HStack(spacing: 8) {
      Image(systemName: section.systemImage)
        .foregroundStyle(section.tint)
        .frame(width: 16)
      Text(section.title)
        .font(.caption.weight(.medium))
      Spacer(minLength: 8)
      Text(section.statusTitle)
        .font(.caption)
        .foregroundStyle(section.tint)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(section.title)，\(section.statusTitle)")
  }

  private func readinessIssueRow(_ issue: PublishDrawerReadinessIssue) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: issue.severity.publishDrawerSystemImage)
        .foregroundStyle(issue.severity.publishDrawerColor)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        Text(issue.title)
          .font(.caption.weight(.medium))
        Text(issue.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func expandedBinding(for id: String) -> Binding<Bool> {
    Binding(
      get: { expandedSectionIDs.contains(id) },
      set: { isExpanded in
        if isExpanded {
          expandedSectionIDs.insert(id)
        } else {
          expandedSectionIDs.remove(id)
        }
      }
    )
  }
}
