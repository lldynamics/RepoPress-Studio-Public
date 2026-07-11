import AppKit
import PublishingWorkbenchCore
import SwiftUI

enum ArticleInspectorTab: String, CaseIterable, Identifiable {
  case metadata
  case seo
  case images
  case checks
  case publish

  var id: String { rawValue }

  static let articleMetadataTabs: [ArticleInspectorTab] = [
    .metadata,
    .seo,
    .images,
    .checks,
    .publish,
  ]

  var title: String {
    switch self {
    case .metadata:
      return "元数据"
    case .seo:
      return "SEO"
    case .images:
      return "图片"
    case .checks:
      return "检查"
    case .publish:
      return "发布"
    }
  }

  var systemImage: String {
    switch self {
    case .metadata:
      return "slider.horizontal.3"
    case .seo:
      return "chart.bar.doc.horizontal"
    case .images:
      return "photo.on.rectangle"
    case .checks:
      return "checklist"
    case .publish:
      return "paperplane"
    }
  }

  static func defaultTab(for section: WorkspaceSection) -> ArticleInspectorTab {
    switch section {
    case .writing:
      return .metadata
    case .sync, .releaseHistory:
      return .publish
    case .contentHealth:
      return .checks
    case .images:
      return .images
    case .siteStarter, .ai, .generalDrafts, .maintenance, .releaseReadiness:
      return .metadata
    }
  }
}

extension PreflightIssue {
  var editorQuery: String? {
    guard field == "body" else {
      return nil
    }

    if title == "正文图片未登记" {
      return message.components(separatedBy: " 不在").first
    }

    return nil
  }
}

struct ArticleInspectorTabs: View {
  @Binding var selectedTab: ArticleInspectorTab
  @Binding var draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      tabPicker
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          selectedContent
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()
      actionFooter
    }
    .background(.bar)
    .onAppear {
      prepareSelectedTab()
    }
    .onChange(of: draft.id) { _, _ in
      prepareSelectedTab()
    }
    .onChange(of: selectedTab) { _, _ in
      prepareSelectedTab()
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: selectedTab.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text("文章 Inspector")
          .font(.headline)
        Text(store.profile(for: draft).markdownPath(for: draft))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }

      Spacer()
    }
    .padding(14)
  }

  private var tabPicker: some View {
    Picker("Inspector", selection: $selectedTab) {
      ForEach(ArticleInspectorTab.articleMetadataTabs) { tab in
        Label(tab.title, systemImage: tab.systemImage)
          .tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(10)
    .accessibilityLabel("文章 Inspector 标签")
    .accessibilityValue(selectedTab.title)
  }

  private var actionFooter: some View {
    HStack(spacing: 10) {
      Button {
        store.save()
      } label: {
        Label("保存", systemImage: "tray.and.arrow.down")
      }

      Button {
        selectedTab = .checks
        store.runPreflight()
      } label: {
        Label(selectedTab == .checks ? "重新检查" : "检查", systemImage: "checklist")
      }

      Spacer(minLength: 0)

      if selectedTab == .publish {
        Button {
          store.selectSection(.sync)
        } label: {
          Label("前往同步", systemImage: "arrow.right.circle")
        }
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("文章 Inspector 主要操作")
  }

  @ViewBuilder
  private var selectedContent: some View {
    switch selectedTab {
    case .metadata:
      metadataContent
    case .seo:
      seoContent
    case .images:
      imageContent
    case .checks:
      checkContent
    case .publish:
      publishContent
    }
  }

  private var metadataContent: some View {
    WorkspaceTaskMetadataSection(
      draft: $draft,
      state: WorkspaceTaskMetadataState(
        draft: draft,
        profile: store.profile(for: draft)
      )
    )
  }

  private var seoContent: some View {
    WorkspaceTaskSEOSection(draft: draft, store: store)
  }

  private var imageContent: some View {
    WorkspaceTaskImageSection(
      draft: $draft,
      state: WorkspaceTaskImageState(
        report: store.imageWorkbenchReport(for: draft),
        siteSummary: store.imageWorkbenchSiteSummary,
        actionMessage: store.imageActionMessage
      ),
      actions: WorkspaceTaskImageActions(
        fillMissingMetadataForCurrentDraft: {
          store.fillMissingImageMetadataForSelectedDraft()
        },
        optimizeJPEGForCurrentDraft: {
          store.optimizeSelectedDraftJPEGImages()
        },
        openImageWorkbench: {
          _ = store.focusDraft(draft.id, section: .images)
        },
        refreshReport: {
          store.refreshImageWorkbenchReport()
        }
      )
    )
  }

  private var checkContent: some View {
    WorkspaceTaskChecksSection(
      state: WorkspaceTaskChecksState(
        issues: store.preflightIssues(for: draft),
        publicRisk: store.publicRiskSummary(for: draft)
      ),
      actions: WorkspaceTaskChecksActions(
        rerunPreflight: {
          store.runPreflight()
        },
        focusIssue: focus
      )
    )
  }

  private var publishContent: some View {
    WorkspaceTaskPublishSection(draft: $draft, store: store)
  }

  private func focus(_ issue: PreflightIssue) {
    switch issue.field {
    case "body":
      store.requestEditorFocus(draftID: draft.id, field: issue.field, query: issue.editorQuery)
    case "attachments", "cover":
      selectedTab = .images
    case "repository", "contentRoot", "assetRoot", "markdownPathPattern":
      selectedTab = .publish
    default:
      selectedTab = .metadata
    }
  }

  private func prepareSelectedTab() {
    switch selectedTab {
    case .seo:
      store.prepareSEOSocialPreview(for: draft)
    case .images:
      store.refreshImageWorkbenchReport()
    case .checks:
      store.runPreflight()
    case .publish:
      store.refreshPublishPreview(for: draft)
    case .metadata:
      break
    }
  }
}

struct ReleaseQualityGateInspectorView: View {
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    let report = store.releaseQualityGateReport

    InspectorScaffold(
      title: "上架门禁",
      subtitle: report.isReadyForAppStore ? "当前未发现阻断项" : "仍需补齐发布证据",
      systemImage: WorkspaceSection.releaseReadiness.systemImage
    ) {
      InspectorStatRow(title: "阻断", value: "\(report.blockingItems.count)", systemImage: ReleaseQualityGateStatus.blocked.systemImage)
      InspectorStatRow(title: "需确认", value: "\(report.warningItems.count)", systemImage: ReleaseQualityGateStatus.warning.systemImage)
      InspectorStatRow(title: "通过", value: "\(report.passedItems.count)", systemImage: ReleaseQualityGateStatus.passed.systemImage)
      InspectorStatRow(
        title: "截图",
        value: "\(report.capturedScreenshotRequirements.count)/\(report.screenshotRequirements.count)",
        systemImage: "camera.viewfinder"
      )

      Button {
        store.refreshReleaseQualityGate()
      } label: {
        Label(
          store.isReleaseQualityGateRefreshing ? "刷新中" : "刷新门禁",
          systemImage: store.isReleaseQualityGateRefreshing ? "hourglass" : "arrow.clockwise"
        )
      }
      .disabled(store.isReleaseQualityGateRefreshing)

      if let message = store.releaseQualityGateMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      let missingScreenshots = report.missingScreenshotRequirements
      if !missingScreenshots.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Label("待采集截图", systemImage: "camera.viewfinder")
            .font(.caption.weight(.semibold))
            .foregroundStyle(WorkbenchTheme.warning)
          ForEach(Array(missingScreenshots.prefix(4)), id: \.id) { requirement in
            Text("\(requirement.screenTitle.nilIfEmpty ?? requirement.id) · \(requirement.targetFileName.nilIfEmpty ?? "未配置目标文件")")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .padding(.vertical, 3)
      }

      ForEach(report.blockingItems.prefix(5)) { item in
        VStack(alignment: .leading, spacing: 4) {
          Label(item.title, systemImage: item.status.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(WorkbenchTheme.risk)
          Text(item.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
        .padding(.vertical, 3)
      }
    }
  }
}

struct GeneralDraftLibraryInspectorView: View {
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    let report = store.generalDraftLibraryReport
    let backupPlan = store.generalDraftBackupPlan
    let packagePlan = store.generalDraftLibraryPackagePlan

    InspectorScaffold(
      title: "素材库",
      subtitle: "跨文章、跨站点复用素材",
      systemImage: WorkspaceSection.generalDrafts.systemImage
    ) {
      InspectorStatRow(title: "库内素材", value: "\(report.generalDraftCount)", systemImage: GeneralDraftReuseStatus.libraryDraft.systemImage)
      InspectorStatRow(title: "复用候选", value: "\(report.crossSiteCandidateCount)", systemImage: GeneralDraftReuseStatus.reusableCandidate.systemImage)
      InspectorStatRow(title: "标签维度", value: "\(report.tagSummaries.count)", systemImage: "tag")
      InspectorStatRow(title: "分类维度", value: "\(report.categorySummaries.count)", systemImage: "folder")
      InspectorStatRow(title: "附件素材", value: "\(report.attachmentCount)", systemImage: "paperclip")
      InspectorStatRow(title: "素材库 Profile", value: "\(report.generalProfileCount)", systemImage: SiteProfilePurpose.generalDraftBackup.systemImage)

      Button {
        copy(report.crossSiteMaterialPackageMarkdown, message: "已复制跨站点素材包。")
      } label: {
        Label("复制素材包", systemImage: "shippingbox")
      }
      .disabled(report.items.isEmpty && report.assets.isEmpty)

      Button {
        copy(packagePlan.packageText, message: "已复制素材包。")
      } label: {
        Label("复制素材包", systemImage: "shippingbox.fill")
      }
      .disabled(packagePlan.files.isEmpty)

      Button {
        importPackageFromClipboard()
      } label: {
        Label("导入素材包", systemImage: "tray.and.arrow.down")
      }

      if !report.tagSummaries.isEmpty || !report.categorySummaries.isEmpty {
        InspectorSection("素材标签/分类") {
          if !report.tagSummaries.isEmpty {
            Text("标签：\(report.tagSummaries.map { "\($0.label)(\($0.draftCount))" }.joined(separator: "、"))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if !report.categorySummaries.isEmpty {
            Text("分类：\(report.categorySummaries.map { "\($0.label)(\($0.draftCount))" }.joined(separator: "、"))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      if let reusePlan = store.latestGeneralDraftReusePlan {
        InspectorSection("最近复用计划") {
          InspectorStatRow(
            title: "目标站点",
            value: reusePlan.targetProfileName,
            systemImage: reusePlan.riskLevel.systemImage
          )
          Text(reusePlan.targetMarkdownPath)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)

          if !reusePlan.sourceFieldDiffs.isEmpty {
            Text("字段对比（来源）")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            ForEach(reusePlan.sourceFieldDiffs, id: \.self) { item in
              Label(item, systemImage: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }

          Button {
            sendReusePlanToAI(reusePlan)
          } label: {
            Label("发送到 AI", systemImage: "sparkles")
          }
          .disabled(store.ai.isChatRunning)
        }
      }

      InspectorSection("备份") {
        let writeResult = store.latestGeneralDraftBackupWriteResult

        InspectorStatRow(
          title: "备份文件",
          value: "\(backupPlan.files.count)",
          systemImage: "doc.zipper"
        )
        InspectorStatRow(
          title: "备份仓库",
          value: backupPlan.isRepositoryConfigured ? "已选择" : "未选择",
          systemImage: backupPlan.isRepositoryConfigured ? "externaldrive.fill" : "externaldrive"
        )
        Label(
          backupPlan.isReady ? "备份就绪" : backupPlan.statusMessage,
          systemImage: backupPlan.isReady ? "checkmark.seal" : "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(backupPlan.isReady ? .green : .orange)
        .lineLimit(3)

        if let writeResult {
          InspectorStatRow(
            title: "最近写入",
            value: "\(writeResult.writtenPaths.count) 篇",
            systemImage: "square.and.arrow.down"
          )
          InspectorStatRow(
            title: "清理过期",
            value: "\(writeResult.deletedStalePaths.count)",
            systemImage: "trash"
          )
          if !writeResult.deletedStalePaths.isEmpty {
            Text(writeResult.deletedStalePaths.prefix(3).joined(separator: "\n"))
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(3)
              .textSelection(.enabled)
          }
        }

        Button {
          store.writeGeneralDraftBackupToRepository()
        } label: {
          Label("写入备份", systemImage: "square.and.arrow.down")
        }
        .disabled(!backupPlan.isReady)

        Button {
          copy(backupPlan.manifestMarkdown, message: "已复制素材备份清单。")
        } label: {
          Label("复制备份清单", systemImage: "doc.on.doc")
        }
        .disabled(backupPlan.files.isEmpty)

        Button {
          copy(backupPlan.packageText, message: "已复制素材备份文件。")
        } label: {
          Label("复制文件包", systemImage: "shippingbox")
        }
        .disabled(backupPlan.files.isEmpty)

        Button {
          copy(backupPlan.commandText, message: "已复制素材备份命令。")
        } label: {
          Label("复制备份命令", systemImage: "terminal")
        }
        .disabled(backupPlan.commandLines.isEmpty)
      }

      Button {
        store.createGeneralDraft()
      } label: {
        Label("新建素材", systemImage: "plus")
      }

      Button {
        let profile = store.ensureGeneralDraftProfile()
        store.selectProfile(profile.id)
      } label: {
        Label("切换到素材库 Profile", systemImage: "shippingbox")
      }
    }
  }

  private func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { store.setPublishActionMessage($0) }
  }

  private func importPackageFromClipboard() {
    guard let packageText = ClipboardReader.string(),
          !packageText.trimmedForPublishing.isEmpty else {
      store.setPublishActionMessage("剪贴板中没有可识别的草稿包。")
      return
    }
    _ = store.importGeneralDraftLibraryPackage(from: packageText)
  }

  private func sendReusePlanToAI(_ plan: GeneralDraftReusePlan) {
    guard let draft = store.publishing.drafts.first(where: { $0.id == plan.targetDraftID }) else {
      store.setPublishActionMessage("没有找到复用后的目标草稿，无法发送到 AI。")
      return
    }

    store.ai.openChatWorkspace(for: draft.id)
    Task {
      await store.ai.sendChatMessage(
        AIPublishingChatPromptTemplateService.generalDraftReusePlanPrompt(
          for: plan,
          draft: draft,
          profile: store.publishing.profile(for: draft)
        ),
        draft: draft
      )
    }
  }
}

struct MaintenanceTaskInspector: View {
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    InspectorScaffold(
      title: "维护",
      subtitle: "日历、标签、旧文和链接审计",
      systemImage: "wrench.and.screwdriver"
    ) {
      if let snapshot = store.siteMaintenanceSnapshot {
        let report = snapshot.report
        InspectorStatRow(title: "Profile", value: snapshot.profileName, systemImage: "person.crop.circle")
        InspectorStatRow(title: "快照文章", value: "\(snapshot.draftCount)", systemImage: "doc.on.doc")
        InspectorStatRow(title: "快照版本", value: "v\(snapshot.sourceVersion)", systemImage: "number")
        InspectorStatRow(title: "文章", value: "\(report.draftCount)", systemImage: "doc.text")
        InspectorStatRow(title: "行动项", value: "\(report.actionItems.count)", systemImage: "checklist")
        InspectorStatRow(title: "日历提示", value: "\(report.calendarInsights.count)", systemImage: "calendar.badge.exclamationmark")
        InspectorStatRow(title: "待发布排期", value: "\(report.calendarScheduleItems.count)", systemImage: "calendar.badge.clock")
        InspectorStatRow(title: "旧文候选", value: "\(report.staleArticles.count)", systemImage: "clock.badge.exclamationmark")
        InspectorStatRow(title: "链接问题", value: "\(report.internalLinkIssueCount)", systemImage: "link.badge.plus")
        InspectorStatRow(title: "缺标签", value: "\(report.tagSummary.missingCount)", systemImage: "tag")

        if store.isSiteMaintenanceSnapshotStale {
          Label("维护报告可能已过期，建议刷新。", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
        }

        Button {
          store.refreshSiteMaintenanceSnapshot()
        } label: {
          Label("刷新维护报告", systemImage: "arrow.clockwise")
        }

        if let insight = report.calendarInsights.first {
          InspectorSection("内容节奏") {
            Label("\(insight.priority.displayName) · \(insight.title)", systemImage: insight.systemImage)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(insight.summary)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } else {
        Text("维护报告尚未生成。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button {
          store.refreshSiteMaintenanceSnapshot()
        } label: {
          Label("生成维护报告", systemImage: "arrow.clockwise")
        }
      }
    }
  }
}
