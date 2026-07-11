import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct GeneralDraftLibraryDetailView: View {
  @ObservedObject var store: WorkbenchStore

  var body: some View {
    let report = store.generalDraftLibraryReport
    let backupPlan = store.generalDraftBackupPlan
    let packagePlan = store.generalDraftLibraryPackagePlan

    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text("素材库")
              .font(.title2.weight(.semibold))
            Text("沉淀跨文章、跨站点复用的想法、片段、文章雏形和附件素材。")
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            copy(report.distributionChecklistMarkdown, message: "已复制素材分发清单。")
          } label: {
            Label("复制分发清单", systemImage: "checklist")
          }
          .disabled(report.items.isEmpty && report.assets.isEmpty)

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

          Button {
            store.createGeneralDraft()
          } label: {
            Label("新建素材", systemImage: "plus")
          }
        }

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
          MetricTile(title: "全部候选", value: "\(report.totalDraftCount)", systemImage: "doc.text")
          MetricTile(title: "库内素材", value: "\(report.generalDraftCount)", systemImage: GeneralDraftReuseStatus.libraryDraft.systemImage)
          MetricTile(title: "复用候选", value: "\(report.crossSiteCandidateCount)", systemImage: GeneralDraftReuseStatus.reusableCandidate.systemImage)
          MetricTile(title: "素材附件", value: "\(report.attachmentCount)", systemImage: "paperclip")
          MetricTile(title: "标签维度", value: "\(report.tagSummaries.count)", systemImage: "tag")
          MetricTile(title: "分类维度", value: "\(report.categorySummaries.count)", systemImage: "folder")
          MetricTile(title: "素材库 Profile", value: "\(report.generalProfileCount)", systemImage: SiteProfilePurpose.generalDraftBackup.systemImage)
          MetricTile(title: "发布站点", value: "\(report.publishingProfileCount)", systemImage: SiteProfilePurpose.publishing.systemImage)
        }

        if !report.tagSummaries.isEmpty || !report.categorySummaries.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("素材标签/分类")
              .font(.subheadline.weight(.medium))
            if !report.tagSummaries.isEmpty {
              Text("标签：\(report.tagSummaries.map { "\($0.label)(\($0.draftCount))" }.joined(separator: "、"))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            if !report.categorySummaries.isEmpty {
              Text("分类：\(report.categorySummaries.map { "\($0.label)(\($0.draftCount))" }.joined(separator: "、"))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
          .padding(10)
          .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
        }

        if let reusePlan = store.latestGeneralDraftReusePlan {
          reusePlanSection(reusePlan)
        }

        backupSection(backupPlan)
        librarySection(report)
        assetSection(report)
      }
      .padding(20)
    }
  }

  @ViewBuilder
  private func reusePlanSection(_ plan: GeneralDraftReusePlan) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("最近复用计划")
            .font(.headline)
          Text("\(plan.sourceProfileName) -> \(plan.targetProfileName)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          _ = store.focusDraft(plan.targetDraftID, section: .writing)
        } label: {
          Label("打开复用草稿", systemImage: "arrow.right.circle")
        }
        Button {
          copy(plan.checklistMarkdown, message: "已复制跨站点复用计划。")
        } label: {
          Label("复制计划", systemImage: "checklist")
        }

        Button {
          sendReusePlanToAI(plan)
        } label: {
          Label("发送到 AI", systemImage: "sparkles")
        }
        .disabled(store.ai.isChatRunning)
      }

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        MetricTile(title: "建议路径", value: plan.targetMarkdownPath, systemImage: "doc.text.magnifyingglass")
        MetricTile(title: "附件", value: "\(plan.attachmentCount)", systemImage: "paperclip")
        MetricTile(
          title: "附件待补",
          value: plan.hasAttachmentWarnings ? "alt \(plan.missingAltTextCount) / caption \(plan.missingCaptionCount)" : "已就绪",
          systemImage: plan.hasAttachmentWarnings ? "exclamationmark.triangle" : "checkmark.circle"
        )
        MetricTile(title: "复用风险", value: plan.riskLevel.displayName, systemImage: plan.riskLevel.systemImage)
      }

      if !plan.sourceFieldDiffs.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("字段对比（相对来源）")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          ForEach(plan.sourceFieldDiffs, id: \.self) { item in
            Label(item, systemImage: "line.3.horizontal")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        ForEach(plan.riskItems.prefix(4), id: \.self) { item in
          Label(item, systemImage: plan.riskLevel.systemImage)
            .font(.caption)
            .foregroundStyle(plan.riskLevel == .high ? .orange : .secondary)
            .lineLimit(2)
        }
        ForEach(plan.checklistItems.prefix(5), id: \.self) { item in
          Label(item, systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .padding(12)
    .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  @ViewBuilder
  private func backupSection(_ plan: GeneralDraftBackupPlan) -> some View {
    let writeResult = store.latestGeneralDraftBackupWriteResult

    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("素材备份")
            .font(.headline)
          Text(plan.statusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          _ = store.ensureGeneralDraftProfile()
          if let url = RepositorySelectionPanel.chooseDirectory() {
            Task {
              await store.repository.rememberRootAsync(url)
            }
          }
        } label: {
          Label(plan.isRepositoryConfigured ? "更换备份仓库" : "选择备份仓库", systemImage: "folder")
        }

        Button {
          store.writeGeneralDraftBackupToRepository()
        } label: {
          Label("写入备份", systemImage: "square.and.arrow.down")
        }
        .disabled(!plan.isReady)

        Button {
          copy(plan.manifestMarkdown, message: "已复制素材备份清单。")
        } label: {
          Label("复制清单", systemImage: "doc.on.doc")
        }
        .disabled(plan.files.isEmpty)

        Button {
          copy(plan.packageText, message: "已复制素材备份文件。")
        } label: {
          Label("复制文件包", systemImage: "shippingbox")
        }
        .disabled(plan.files.isEmpty)

        Button {
          copy(plan.commandText, message: "已复制素材备份命令。")
        } label: {
          Label("复制命令", systemImage: "terminal")
        }
        .disabled(plan.commandLines.isEmpty)
      }

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        MetricTile(title: "备份文件", value: "\(plan.files.count)", systemImage: "doc.zipper")
        MetricTile(title: "备份分支", value: plan.branch, systemImage: "arrow.triangle.branch")
        MetricTile(
          title: "备份仓库",
          value: plan.repositoryRootPath.nilIfEmpty ?? "未选择",
          systemImage: plan.isRepositoryConfigured ? "externaldrive.fill" : "externaldrive"
        )
        if let writeResult {
          MetricTile(title: "最近写入", value: "\(writeResult.writtenPaths.count) 篇", systemImage: "square.and.arrow.down")
          MetricTile(title: "清理过期", value: "\(writeResult.deletedStalePaths.count)", systemImage: "trash")
        }
      }

      if let writeResult {
        VStack(alignment: .leading, spacing: 8) {
          Label(writeResult.statusMessage, systemImage: writeResult.deletedStalePaths.isEmpty ? "checkmark.seal" : "trash")
            .font(.caption.weight(.medium))
            .foregroundStyle(writeResult.deletedStalePaths.isEmpty ? .green : .orange)

          if !writeResult.deletedStalePaths.isEmpty {
            ForEach(writeResult.deletedStalePaths.prefix(6), id: \.self) { path in
              Text(path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
            }
          }
        }
        .padding(10)
        .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }

      if !plan.files.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(plan.files.prefix(6)) { file in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 18)
              Text(file.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
              Spacer()
              Text(file.relativePath)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
              Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
          }
        }
      }
    }
  }

  @ViewBuilder
  private func librarySection(_ report: GeneralDraftLibraryReport) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("可复用素材")
        .font(.headline)

      if report.items.isEmpty {
        EmptyStateView(
          title: "还没有素材",
          message: "新建素材后，可以作为跨文章、跨站点内容沉淀和复用。",
          systemImage: "tray"
        )
        .frame(height: 220)
      } else {
        let visibleItems = report.items.prefix(12).map { $0 }
        ForEach(visibleItems) { (item: GeneralDraftLibraryItem) in
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.reuseStatus.systemImage)
              .foregroundStyle(reuseStatusColor(item.reuseStatus))
              .frame(width: 18)

            VStack(alignment: .leading, spacing: 5) {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                  .font(.callout.weight(.medium))
                  .lineLimit(1)
                Text(item.reuseStatus.displayName)
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(reuseStatusColor(item.reuseStatus))
                Spacer()
                Text(item.updatedAt.workbenchShortText)
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
              }

              Text(item.reuseReason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

              libraryItemMetadataRow(item)
            }

            Button {
              _ = store.focusDraft(item.draftID, section: .writing)
            } label: {
              Label("打开", systemImage: "arrow.right.circle")
            }
            .controlSize(.small)

            Button {
              copy(item.reuseChecklistMarkdown, message: "已复制素材复用清单。")
            } label: {
              Label("复制清单", systemImage: "checklist")
            }
            .controlSize(.small)

            Button {
              store.copyDraftToActiveProfile(item.draftID)
            } label: {
              Label("复制到当前站点", systemImage: "doc.on.doc")
            }
            .controlSize(.small)

            if item.reuseStatus != .libraryDraft {
              Button {
                store.copyDraftToGeneralLibrary(item.draftID)
              } label: {
                Label("收进素材库", systemImage: "tray.and.arrow.down")
              }
              .controlSize(.small)
            }
          }
          .padding(12)
          .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
        }
      }
    }
  }

  private func libraryItemMetadataRow(_ item: GeneralDraftLibraryItem) -> some View {
    HStack(spacing: 8) {
      Text(item.profileName)
      if !item.slug.isEmpty {
        Text(item.slug)
      }
      if let sourceProfileName = item.sourceProfileName, !sourceProfileName.isEmpty {
        Text("来源：\(sourceProfileName)")
          .lineLimit(1)
          .foregroundStyle(.secondary)
      }
      if !item.tags.isEmpty {
        Text(item.tags.joined(separator: " | "))
      }
      if !item.categories.isEmpty {
        Text(item.categories.joined(separator: " | "))
      }
      Text("\(item.bodyCharacterCount) 字")
      if item.attachmentCount > 0 {
        Text("\(item.attachmentCount) 个附件")
      }
    }
    .font(.caption2)
    .foregroundStyle(.tertiary)
    .lineLimit(1)
  }

  @ViewBuilder
  private func assetSection(_ report: GeneralDraftLibraryReport) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("跨站点素材")
        .font(.headline)

      if report.assets.isEmpty {
        Text("还没有附件素材。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      } else {
        ForEach(report.assets.prefix(12)) { asset in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "paperclip")
              .foregroundStyle(.secondary)
              .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
              Text(asset.originalFilename)
                .font(.callout.weight(.medium))
                .lineLimit(1)
              Text("\(asset.profileName) · \(asset.draftTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
              Text(asset.repositoryPath.nilIfEmpty ?? asset.relativePublishPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer()
            if asset.isMissingAltText {
              Label("缺 alt", systemImage: "text.quote")
                .font(.caption2)
                .foregroundStyle(.orange)
            }
            if asset.isMissingCaption {
              Label("缺 caption", systemImage: "captions.bubble")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          .padding(10)
          .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
        }
      }
    }
  }

  private func reuseStatusColor(_ status: GeneralDraftReuseStatus) -> AnyShapeStyle {
    switch status {
    case .libraryDraft:
      return AnyShapeStyle(.green)
    case .reusableCandidate:
      return AnyShapeStyle(.orange)
    case .siteSpecific:
      return AnyShapeStyle(.secondary)
    }
  }

  private func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { store.setPublishActionMessage($0) }
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

  private func importPackageFromClipboard() {
    guard let packageText = ClipboardReader.string(),
          !packageText.trimmedForPublishing.isEmpty else {
      store.setPublishActionMessage("剪贴板中没有可识别的草稿包。")
      return
    }
    _ = store.importGeneralDraftLibraryPackage(from: packageText)
  }
}
