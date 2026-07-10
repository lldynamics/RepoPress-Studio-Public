import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var batchPublishQueueSection: some View {
    if let plan = store.batchPublishPlan {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text("待发布队列")
              .font(.headline)
            Text("\(plan.siteName) · \(plan.items.count) 篇 · \(plan.changedFileCount) 个文件变化")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            store.refreshBatchPublishPlan()
          } label: {
            Label("刷新队列", systemImage: "arrow.clockwise")
          }
          Button {
            store.writeBatchReadyDraftsToLocalRepository()
          } label: {
            Label("批量写入可发布", systemImage: "square.stack.3d.down.right")
          }
          .disabled(plan.writableItems.isEmpty)
          Button {
            Task {
              await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy()
            }
          } label: {
            Label(
              store.isRemoteRepositoryPublishing ? "线上发布中" : "批量线上发布",
              systemImage: "network"
            )
          }
          .disabled(plan.remotePublishableItems.isEmpty || store.isRemoteRepositoryPublishing)
        }

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
          MetricTile(title: "可写入", value: "\(plan.readyCount)", systemImage: "checkmark.circle")
          MetricTile(title: "需确认", value: "\(plan.needsReviewCount)", systemImage: "exclamationmark.triangle")
          MetricTile(title: "阻塞", value: "\(plan.blockedCount)", systemImage: "xmark.octagon")
          MetricTile(title: "无变化", value: "\(plan.unchangedCount)", systemImage: "equal.circle")
        }

        if let preview = store.remoteRepositoryPublishPreview(for: plan) {
          batchOnlinePublishPreview(preview)
        }

        DisclosureGroup {
          HStack(spacing: 10) {
            Button {
              copyBatchCommitCommand()
            } label: {
              Label("复制批量提交命令", systemImage: "terminal")
            }
            .disabled(plan.writableItems.isEmpty)

            Button {
              copyBatchReviewBranchCommands()
            } label: {
              Label("复制批量分支命令", systemImage: "arrow.triangle.branch")
            }
            .disabled(plan.writableItems.isEmpty)

            Button {
              copyBatchReviewDescription()
            } label: {
              Label("复制批量 PR/MR 描述", systemImage: "doc.on.doc")
            }
            .disabled(store.batchRemoteReviewDraft == nil)
          }
          .controlSize(.small)
          .padding(.top, 6)
        } label: {
          Label("高级操作", systemImage: "wrench.and.screwdriver")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))

        if let message = store.publishActionMessage {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let review = store.batchRemoteReviewDraft {
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
              VStack(alignment: .leading, spacing: 3) {
                Text("批量 PR/MR 草稿")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                Text("\(review.branchName) -> \(review.targetBranch)")
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
              Button {
                copy(review.body, message: "已复制批量 PR/MR 描述。")
              } label: {
                Label("复制描述", systemImage: "doc.on.doc")
              }
              Button {
                openReviewURL(review)
              } label: {
                Label("打开 PR/MR", systemImage: "arrow.up.right.square")
              }
              .disabled(review.webURL == nil)
            }

            Text(review.title)
              .font(.callout.weight(.medium))
              .textSelection(.enabled)
          }
          .padding(10)
          .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
        }

        if plan.items.isEmpty {
          Text("当前 Profile 没有可纳入发布队列的文章。")
            .foregroundStyle(.secondary)
        } else {
          ForEach(plan.items) { item in
            BatchPublishPlanRow(item: item) {
              store.selectDraft(item.draftID)
              store.selectSection(.writing)
            }
            Divider()
          }
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }
}
