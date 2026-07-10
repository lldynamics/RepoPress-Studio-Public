import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct ReleaseQualityGateDetailView: View {
  @ObservedObject var store: WorkbenchStore
  @State private var externalEvidenceDrafts: [String: String] = [:]
  @State private var externalEvidenceURLs: [String: String] = [:]

  var body: some View {
    let report = store.releaseQualityGateReport

    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        let externalCoverage = store.externalVerificationCoverageSummary
        let checklistCoverage = store.appStoreChecklistCoverageSummary
        let evidenceFileStatus = report.externalVerificationEvidenceFileStatus

        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text("上架门禁")
              .font(.title2.weight(.semibold))
            Text("集中检查本地化、UI runtime、截图证据、App Store checklist 和产品边界。")
              .foregroundStyle(.secondary)
          }
          Spacer()
          Menu {
            Button {
              copy(store.localReleaseEvidenceBundleMarkdown, message: "已复制本地发布证据包。")
            } label: {
              Label("复制本地证据", systemImage: "doc.on.doc")
            }
            Button {
              copy(store.cleanRuntimeEvidenceRecordingCommandMarkdown, message: "已复制 clean runtime 记录命令。")
            } label: {
              Label("复制 Runtime 命令", systemImage: "terminal")
            }
            Button {
              copy(store.appStoreArchiveValidationRecordingCommandMarkdown, message: "已复制归档验证记录命令。")
            } label: {
              Label("复制归档命令", systemImage: "archivebox")
            }
            Button {
              copy(
                store.externalVerificationEnvironmentPreparationCommandMarkdown,
                message: "已复制外部验收私有 env 准备命令。"
              )
            } label: {
              Label("复制 env 准备", systemImage: "doc.badge.gearshape")
            }
            Button {
              copy(store.remainingReleaseVerificationCommandMarkdown, message: "已复制剩余上架验收命令包。")
            } label: {
              Label("复制验收命令", systemImage: "terminal.fill")
            }
            Button {
              copy(
                store.externalVerificationEnvironmentStatusReportCommandMarkdown,
                message: "已复制私有 env 状态报告命令。"
              )
            } label: {
              Label("复制 env 状态", systemImage: "doc.text.magnifyingglass")
            }
            Button {
              copy(
                store.externalVerificationEnvironmentFieldChecklistMarkdown,
                message: "已复制私有 env 字段清单。"
              )
            } label: {
              Label("复制 env 清单", systemImage: "checklist")
            }
          } label: {
            Label("复制...", systemImage: "doc.on.doc")
          }
          Button {
            do {
              _ = try store.writeLocalReleaseEvidenceBundle()
            } catch {
              store.setReleaseQualityGateMessage("写入本地发布证据包失败：\(error.localizedDescription)")
            }
          } label: {
            Label("写入本地证据", systemImage: "square.and.arrow.down")
          }
          Button {
            store.refreshReleaseQualityGate()
          } label: {
            Label("刷新", systemImage: "arrow.clockwise")
          }
        }

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
          MetricTile(title: "阻断项", value: "\(report.blockingItems.count)", systemImage: ReleaseQualityGateStatus.blocked.systemImage)
          MetricTile(title: "需确认", value: "\(report.warningItems.count)", systemImage: ReleaseQualityGateStatus.warning.systemImage)
          MetricTile(title: "已通过", value: "\(report.passedItems.count)", systemImage: ReleaseQualityGateStatus.passed.systemImage)
          MetricTile(
            title: "截图",
            value: "\(report.capturedScreenshotRequirements.count)/\(report.screenshotRequirements.count)",
            systemImage: "camera.viewfinder"
          )
          MetricTile(
            title: "外部证据",
            value: "\(externalCoverage.recordedCount)/\(externalCoverage.totalCount)",
            systemImage: externalCoverage.isComplete ? "checkmark.seal" : "checkmark.shield"
          )
          MetricTile(
            title: "清单覆盖",
            value: "\(checklistCoverage.coveredCount)/\(checklistCoverage.totalCount)",
            systemImage: checklistCoverage.isFullyCoveredByChecklistOrEvidence ? "checkmark.seal" : "list.bullet.clipboard"
          )
          MetricTile(
            title: "证据包",
            value: "\(evidenceFileStatus.completedCount)/\(evidenceFileStatus.totalCount)",
            systemImage: evidenceFileStatus.isComplete ? "checkmark.seal" : "doc.badge.clock"
          )
        }

        strictReleaseReadinessSection()

        if let message = store.releaseQualityGateMessage {
          Label(message, systemImage: report.isReadyForAppStore ? "checkmark.circle" : "exclamationmark.triangle")
            .foregroundStyle(report.isReadyForAppStore ? .green : .orange)
        }

        Text(report.projectRootPath.nilIfEmpty ?? FileManager.default.currentDirectoryPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        if !report.screenshotRequirements.isEmpty {
          screenshotCaptureSection(report)
        }

        if !report.externalVerificationItems.isEmpty {
          externalVerificationSection(report)
        }

        if !report.appStoreChecklistTasks.isEmpty {
          appStoreChecklistCoverageSection()
        }

        ForEach(report.sections) { section in
          releaseGateSection(section)
        }
      }
      .padding(20)
    }
    .onAppear {
      store.refreshReleaseQualityGate()
    }
  }

  private func strictReleaseReadinessSection() -> some View {
    let summary = store.strictReleaseReadinessSummary

    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label(
          summary.title,
          systemImage: summary.isReady ? "checkmark.seal" : "exclamationmark.triangle"
        )
        .font(.headline)
        .foregroundStyle(summary.isReady ? .green : .orange)

        Spacer()

        Button {
          copy(summary.commandText, message: "已复制严格发布下一步命令。")
        } label: {
          Label(summary.isReady ? "复制 strict 命令" : "复制下一步", systemImage: "terminal")
        }
        .buttonStyle(.bordered)
      }

      Text(summary.message)
        .font(.caption)
        .foregroundStyle(.secondary)

      if summary.actions.isEmpty {
        Text(summary.strictCommand)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      } else {
        ForEach(summary.actions) { action in
          strictReleaseReadinessActionRow(action)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func strictReleaseReadinessActionRow(_ action: ReleaseStrictReadinessAction) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text(action.priority.displayName)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(action.priority == .high ? .orange : .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(WorkbenchBackgroundStyle.badge, in: Capsule())
        .frame(width: 44, alignment: .leading)

      VStack(alignment: .leading, spacing: 3) {
        Text(action.title)
          .font(.caption.weight(.semibold))
        Text(action.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
        if let command = action.command {
          Text(command)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
      }

      Spacer(minLength: 8)
    }
  }

  private func screenshotCaptureSection(_ report: ReleaseQualityGateReport) -> some View {
    let requirements = report.screenshotRequirements

    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("上架截图采集", systemImage: "camera.viewfinder")
          .font(.headline)
        Spacer()
        Text("\(requirements.filter(\.isCaptured).count)/\(requirements.count)")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Button {
          copy(report.screenshotCapturePlanMarkdown, message: "已复制截图采集计划。")
        } label: {
          Label("复制计划", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        Button {
          copy(
            store.appStoreScreenshotEvidenceRecordingCommandMarkdown,
            message: "已复制截图证据记录命令。"
          )
        } label: {
          Label("复制记录命令", systemImage: "terminal")
        }
        .buttonStyle(.bordered)
        Button {
          store.recordAppStoreScreenshotExternalVerificationEvidence()
        } label: {
          Label("记录截图证据", systemImage: "checkmark.seal")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!store.canRecordAppStoreScreenshotEvidence)
      }

      ForEach(Array(requirements), id: \ReleaseScreenshotRequirement.id) { requirement in
        screenshotRequirementRow(requirement)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func screenshotRequirementRow(_ requirement: ReleaseScreenshotRequirement) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: requirement.gateStatus.systemImage)
        .foregroundStyle(releaseQualityGateStatusColor(requirement.gateStatus))
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(requirement.screenTitle.nilIfEmpty ?? requirement.id)
            .font(.callout.weight(.semibold))
          Text(requirement.id)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
        }

        Text(requirement.purpose.nilIfEmpty ?? "Manifest 缺少截图说明。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)

        Text(requirement.capturedFilePath ?? "待采集：\(requirement.targetFileName.nilIfEmpty ?? "未配置目标文件")")
          .font(.caption.monospaced())
          .foregroundStyle(screenshotRequirementPathColor(requirement))
          .textSelection(.enabled)

        Text(requirement.captureCommand)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        Text(requirement.privacyReminder)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      Spacer()
      Button {
        copy(requirement.captureCommand, message: "已复制 \(requirement.id) 截图命令。")
      } label: {
        Image(systemName: "doc.on.doc")
      }
      .buttonStyle(.borderless)
      .help("复制单项截图命令")
      .accessibilityLabel("复制截图命令")
      .accessibilityValue(requirement.id)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func screenshotRequirementPathColor(_ requirement: ReleaseScreenshotRequirement) -> Color {
    requirement.isCaptured ? .secondary : .orange
  }

  private func externalVerificationSection(_ report: ReleaseQualityGateReport) -> some View {
    let coverage = store.externalVerificationCoverageSummary

    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("外部验收计划", systemImage: "checkmark.shield")
          .font(.headline)
        Spacer()
        Text("\(report.externalVerificationItems.count) 项")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Button {
          copy(store.externalVerificationEvidenceFileMarkdown, message: "已复制外部验收证据包。")
        } label: {
          Label("复制证据包", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        Button {
          do {
            _ = try store.writeExternalVerificationEvidenceFile()
          } catch {
            store.setReleaseQualityGateMessage("写入外部验收证据包失败：\(error.localizedDescription)")
          }
        } label: {
          Label("写入证据包", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
        Button {
          do {
            _ = try store.importExternalVerificationEvidenceFile()
          } catch {
            store.setReleaseQualityGateMessage("导入外部验收证据包失败：\(error.localizedDescription)")
          }
        } label: {
          Label("导入证据包", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        Button {
          copy(store.externalVerificationEvidenceMarkdown, message: "已复制外部验收证据。")
        } label: {
          Label("复制证据", systemImage: "doc.text")
        }
        .buttonStyle(.bordered)
        Button {
          copy(report.externalVerificationPlanMarkdown, message: "已复制外部发布验收计划。")
        } label: {
          Label("复制计划", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        Button {
          copy(store.remotePublishLiveVerificationCommandMarkdown, message: "已复制 GitHub/GitLab 实测命令。")
        } label: {
          Label("复制实测命令", systemImage: "terminal")
        }
        .buttonStyle(.bordered)
        Button {
          copy(
            store.externalVerificationEnvironmentPreparationCommandMarkdown,
            message: "已复制外部验收私有 env 准备命令。"
          )
        } label: {
          Label("复制 env 准备", systemImage: "doc.badge.gearshape")
        }
        .buttonStyle(.bordered)
        Button {
          copy(
            store.externalVerificationEnvironmentStatusReportCommandMarkdown,
            message: "已复制私有 env 状态报告命令。"
          )
        } label: {
          Label("复制 env 状态", systemImage: "doc.text.magnifyingglass")
        }
        .buttonStyle(.bordered)
        Button {
          copy(
            store.externalVerificationEnvironmentFieldChecklistMarkdown,
            message: "已复制私有 env 字段清单。"
          )
        } label: {
          Label("复制 env 清单", systemImage: "checklist")
        }
        .buttonStyle(.bordered)
      }

      Label(coverage.message, systemImage: coverage.isComplete ? "checkmark.circle" : "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(coverage.isComplete ? .green : .orange)

      let fileStatus = report.externalVerificationEvidenceFileStatus
      Label(fileStatus.message, systemImage: fileStatus.isComplete ? "checkmark.circle" : "doc.text")
        .font(.caption)
        .foregroundStyle(fileStatus.isComplete ? .green : .secondary)
        .textSelection(.enabled)

      externalVerificationEnvironmentStatusSection(store.externalVerificationEnvironmentStatusReport)

      let runnerTargets = store.remainingExternalVerificationRunnerTargets
      if !runnerTargets.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Label("下一步验收 target", systemImage: "play.square.stack")
              .font(.callout.weight(.semibold))
            Spacer()
            Text("\(runnerTargets.count) 项")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
          }

          ForEach(runnerTargets) { target in
            externalVerificationRunnerTargetRow(target)
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }

      ForEach(report.externalVerificationItems) { item in
        externalVerificationRow(item)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func externalVerificationEnvironmentStatusSection(
    _ status: ReleaseExternalVerificationEnvStatusReport
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label(
          status.title,
          systemImage: status.isClean ? "checkmark.circle" : "doc.text.magnifyingglass"
        )
        .font(.callout.weight(.semibold))
        .foregroundStyle(status.isClean ? .green : .orange)

        Spacer()

        if status.isPresent {
          Text("\(status.passingEnvFileCount)/\(status.checkedTargetCount)")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }

        Button {
          copy(status.summaryMarkdown, message: "已复制私有 env 状态摘要。")
        } label: {
          Label("复制摘要", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
      }

      Text(status.message)
        .font(.caption)
        .foregroundStyle(.secondary)

      if status.isPresent {
        if !status.evidenceCompletions.isEmpty {
          HStack(spacing: 8) {
            Label(status.evidenceCompletionMessage, systemImage: status.pendingEvidenceCompletions.isEmpty ? "checkmark.seal" : "checklist")
              .font(.caption)
              .foregroundStyle(status.pendingEvidenceCompletions.isEmpty ? .green : .secondary)
            Spacer()
          }

          ForEach(status.pendingEvidenceCompletions.prefix(4)) { item in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .frame(width: 14)
              Text(item.targetID)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
              Text(item.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
              Spacer()
            }
          }
        }

        ForEach(status.files.filter { !$0.issues.isEmpty }.prefix(4)) { file in
          VStack(alignment: .leading, spacing: 4) {
            Text("\(file.envFilename) · \(file.targetID)")
              .font(.caption.weight(.semibold))
            if !file.missingOrPlaceholderKeys.isEmpty {
              Text("待补：\(file.missingOrPlaceholderKeys.joined(separator: "、"))")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)
            }
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func externalVerificationRunnerTargetRow(_ target: ReleaseExternalVerificationRunnerTarget) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "terminal")
        .foregroundStyle(.secondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(target.title)
            .font(.caption.weight(.semibold))
          Text(target.id)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
        }

        Text(target.purpose)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)

        Text("env：/private/tmp/personal-site-publisher-release-envs/\(target.environmentFilename)")
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
          .textSelection(.enabled)

        if !target.checklistItems.isEmpty {
          Text("checklist：\(target.checklistItems.joined(separator: "；"))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(3)
            .textSelection(.enabled)
        }

        if !target.requiredEnvironmentKeys.isEmpty {
          Text("必填 env：\(target.requiredEnvironmentKeys.joined(separator: "、"))")
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(3)
            .textSelection(.enabled)
        }
      }

      Spacer(minLength: 8)

      Button {
        copy(target.dryRunCommand, message: "已复制 \(target.title) dry-run 命令。")
      } label: {
        Label("Dry-run", systemImage: "play")
      }
      .buttonStyle(.bordered)

      Button {
        copy(target.executeCommand, message: "已复制 \(target.title) execute 命令。")
      } label: {
        Label("Execute", systemImage: "checkmark.seal")
      }
      .buttonStyle(.borderedProminent)

      Button {
        copy(target.executeAndFinalizeCommand, message: "已复制 \(target.title) 执行 + Gate 命令。")
      } label: {
        Label("Execute + Gate", systemImage: "checkmark.shield")
      }
      .buttonStyle(.bordered)
      .help("执行目标验收后同步 App Store checklist，并运行 strict release gate。")
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func externalVerificationRow(_ item: ReleaseExternalVerificationItem) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(item.title)
          .font(.callout.weight(.semibold))
        Text(item.id)
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
        Spacer()
        Button {
          copy(
            store.externalVerificationRecordingCommandMarkdown(for: item.id),
            message: "已复制 \(item.title) 记录命令。"
          )
        } label: {
          Label("复制记录命令", systemImage: "terminal")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
      }

      Text(item.purpose)
        .font(.caption)
        .foregroundStyle(.secondary)

      Text("证据：\(item.evidenceToCollect)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      if let environmentTemplate = store.releaseQualityGateReport.externalVerificationEnvironmentTemplatePath(for: item.id) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Label("私有 env 模板", systemImage: "doc.badge.gearshape")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(environmentTemplate)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
          Spacer()
          Button {
            copy(environmentTemplate, message: "已复制 \(item.title) 私有 env 模板路径。")
          } label: {
            Label("复制路径", systemImage: "doc.on.doc")
          }
          .controlSize(.small)
          .buttonStyle(.bordered)
        }
      }

      let requiredLabels = store.releaseQualityGateReport.externalVerificationRequiredSummaryLabels(for: item.id)
      if !requiredLabels.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("录入时必须包含")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ForEach(requiredLabels, id: \.self) { label in
            Label(label.replacingOccurrences(of: ":", with: ""), systemImage: "text.badge.checkmark")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
      }

      ForEach(item.steps.prefix(3), id: \.self) { step in
        Label(step, systemImage: "checklist")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      if let latest = store.latestExternalVerificationEvidence(for: item.id) {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Label("已记录证据", systemImage: "checkmark.circle")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.green)
            Spacer()
            Text(latest.recordedAt, style: .time)
              .font(.caption2)
              .foregroundStyle(.tertiary)
            Button {
              store.deleteExternalVerificationEvidence(latest.id)
            } label: {
              Label("删除", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("删除这条外部验收证据")
            .accessibilityLabel("删除外部验收证据")
          }

          Text(latest.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

          if let evidenceURL = latest.evidenceURL {
            Text(evidenceURL)
              .font(.caption.monospaced())
              .foregroundStyle(.tertiary)
              .textSelection(.enabled)
          }
        }
        .padding(8)
        .background(.green.opacity(WorkbenchOpacity.warningBackground), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }

      VStack(alignment: .leading, spacing: 6) {
        TextEditor(text: externalEvidenceDraftBinding(for: item.id))
          .font(.caption)
          .frame(minHeight: requiredLabels.isEmpty ? 36 : 92)
          .overlay(
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
              .stroke(.quaternary)
          )
          .accessibilityLabel("外部验收证据说明")

        TextField("证据链接（可选）", text: externalEvidenceURLBinding(for: item.id))
          .font(.caption)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("外部验收证据链接")
          .accessibilityValue((externalEvidenceURLs[item.id] ?? "").nilIfEmpty ?? "未填写")

        HStack(spacing: 8) {
          if !requiredLabels.isEmpty {
            Button {
              externalEvidenceDrafts[item.id] = externalEvidenceTemplate(for: item)
            } label: {
              Label("填入模板", systemImage: "text.badge.plus")
            }
            .buttonStyle(.bordered)
          }

          Spacer()

          let draft = externalEvidenceDrafts[item.id] ?? ""
          let isEligible = externalEvidenceDraftIsEligible(itemID: item.id, draft: draft)
          if !requiredLabels.isEmpty && !draft.trimmedForPublishing.isEmpty && !isEligible {
            let missingLabels = store.releaseQualityGateReport.missingExternalVerificationSummaryLabels(
              itemID: item.id,
              summary: draft
            )
            Label(
              missingLabels.isEmpty
                ? "结构未完整"
                : "缺少 \(missingLabels.map { $0.replacingOccurrences(of: ":", with: "") }.joined(separator: "、"))",
              systemImage: "exclamationmark.triangle"
            )
              .font(.caption2)
              .foregroundStyle(.orange)
          }

          Button {
            let draft = externalEvidenceDrafts[item.id] ?? ""
            let evidenceURL = externalEvidenceURLs[item.id]
            store.recordExternalVerificationEvidence(
              itemID: item.id,
              summary: draft,
              evidenceURL: evidenceURL
            )
            if externalEvidenceDraftIsEligible(itemID: item.id, draft: draft) {
              externalEvidenceDrafts[item.id] = ""
              externalEvidenceURLs[item.id] = ""
            }
          } label: {
            Label("记录", systemImage: "plus.circle")
          }
          .disabled(!isEligible)
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func externalEvidenceDraftBinding(for itemID: String) -> Binding<String> {
    Binding(
      get: { externalEvidenceDrafts[itemID] ?? "" },
      set: { externalEvidenceDrafts[itemID] = $0 }
    )
  }

  private func externalEvidenceURLBinding(for itemID: String) -> Binding<String> {
    Binding(
      get: { externalEvidenceURLs[itemID] ?? "" },
      set: { externalEvidenceURLs[itemID] = $0 }
    )
  }

  private func externalEvidenceDraftIsEligible(itemID: String, draft: String) -> Bool {
    let summary = draft.trimmedForPublishing
    guard !summary.isEmpty else { return false }
    return store.releaseQualityGateReport.isExternalVerificationSummaryChecklistEligible(
      itemID: itemID,
      summary: summary
    )
  }

  private func externalEvidenceTemplate(for item: ReleaseExternalVerificationItem) -> String {
    store.releaseQualityGateReport.externalVerificationEvidenceTemplate(for: item.id)
  }

  private func appStoreChecklistCoverageSection() -> some View {
    let coverage = store.appStoreChecklistCoverageSummary

    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("App Store 清单证据覆盖", systemImage: "list.bullet.clipboard")
          .font(.headline)
        Spacer()
        Text("\(coverage.coveredCount)/\(coverage.totalCount)")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Button {
          do {
            _ = try store.applyEvidenceToAppStoreChecklist()
          } catch {
            store.setReleaseQualityGateMessage("写回 App Store checklist 失败：\(error.localizedDescription)")
          }
        } label: {
          Label("写回清单", systemImage: "checklist.checked")
        }
        .buttonStyle(.bordered)
        .disabled(coverage.evidenceBackedTasks.isEmpty)
      }

      Label(
        coverage.message,
        systemImage: coverage.isFullyCoveredByChecklistOrEvidence ? "checkmark.circle" : "exclamationmark.triangle"
      )
      .font(.caption)
      .foregroundStyle(coverage.isFullyCoveredByChecklistOrEvidence ? .green : .orange)

      if !coverage.evidenceBackedTasks.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("已有证据但清单未勾选")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          ForEach(coverage.evidenceBackedTasks.prefix(6)) { item in
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
                .frame(width: 16)
              VStack(alignment: .leading, spacing: 2) {
                Text(item.task.title)
                  .font(.caption)
                Text(item.evidence)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Spacer()
            }
          }
        }
      }

      if !coverage.missingTasks.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("仍需人工完成")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          ForEach(coverage.missingTasks.prefix(6)) { task in
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "circle")
                .foregroundStyle(.orange)
                .frame(width: 16)
              VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                  .font(.caption)
                if let sectionTitle = task.sectionTitle {
                  Text(sectionTitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
              }
              Spacer()
              Button {
                copy(
                  store.releaseQualityGateReport.appStoreChecklistManualCommandMarkdown(for: task),
                  message: "已复制 checklist 任务命令。"
                )
              } label: {
                Label("复制命令", systemImage: "terminal")
              }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .help("复制这项 checklist 的验证命令")
              .accessibilityLabel("复制 checklist 验证命令")
            }
          }
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func releaseGateSection(_ section: ReleaseQualityGateSection) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(section.category.displayName, systemImage: section.category.systemImage)
        .font(.headline)

      ForEach(section.items) { item in
        releaseGateItemCard(item)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func releaseGateItemCard(_ item: ReleaseQualityGateItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label(item.title, systemImage: item.status.systemImage)
          .font(.callout.weight(.semibold))
          .foregroundStyle(releaseQualityGateStatusColor(item.status))
        Spacer()
        Text(item.status.displayName)
          .font(.caption.weight(.medium))
          .foregroundStyle(releaseQualityGateStatusColor(item.status))
      }

      Text(item.message)
        .foregroundStyle(.secondary)

      if let evidence = item.evidence, !evidence.isEmpty {
        Text(evidence)
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
          .textSelection(.enabled)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { store.setReleaseQualityGateMessage($0) }
  }
}

private func releaseQualityGateStatusColor(_ status: ReleaseQualityGateStatus) -> Color {
  switch status {
  case .passed:
    return .green
  case .warning:
    return .orange
  case .blocked:
    return .red
  }
}
