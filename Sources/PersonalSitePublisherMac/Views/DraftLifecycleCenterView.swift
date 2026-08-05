import PublishingWorkbenchCore
import SwiftUI

private struct DraftRepositoryCleanupConfirmation {
  let request: DraftRepositoryCleanupRequest
  let preview: LocalPublishPreview?
}

struct DraftLifecycleCenterView: View {
  enum Presentation: Equatable {
    case standalone
    case embedded
  }

  @ObservedObject var store: WorkbenchStore
  let presentation: Presentation
  @Environment(\.dismiss) private var dismiss
  @State private var draftPendingPermanentDeletion: RecycledDraft?
  @State private var cleanupPendingExecution: DraftRepositoryCleanupConfirmation?
  @State private var versionPendingComparison: DraftVersionSnapshot?
  @State private var versionPendingRestore: DraftVersionSnapshot?
  @State private var ownershipTransferPlan: DraftOwnershipTransferPlan?
  @State private var ownershipOperation: DraftOwnershipTransferOperation = .moveToGeneral
  @State private var ownershipTargetProfileID: UUID?

  init(
    store: WorkbenchStore,
    presentation: Presentation = .standalone
  ) {
    self.store = store
    self.presentation = presentation
  }

  private var selectedDraftVersions: [DraftVersionSnapshot] {
    guard let draftID = store.selectedDraftID else { return [] }
    return store.versions(for: draftID)
  }

  var body: some View {
    NavigationStack {
      List {
        versionHistorySection
        ownershipTransferSection
        recycleBinSection
        repositoryCleanupSection
      }
      .navigationTitle("版本历史与回收站")
      .toolbar {
        if presentation == .standalone {
          ToolbarItem(placement: .confirmationAction) {
            Button("完成") {
              dismiss()
            }
          }
        }
      }
    }
    .frame(minWidth: 700, minHeight: 560)
    .confirmationDialog(
      "永久删除文章？",
      isPresented: permanentDeletionPresented,
      titleVisibility: .visible,
      presenting: draftPendingPermanentDeletion
    ) { recycled in
      Button("永久删除", role: .destructive) {
        _ = store.permanentlyDeleteRecycledDraft(recycled.id)
        draftPendingPermanentDeletion = nil
      }
      Button("取消", role: .cancel) {
        draftPendingPermanentDeletion = nil
      }
    } message: { recycled in
      Text("「\(recycled.draft.title.nilIfEmpty ?? "未命名文章")」的回收站副本和版本历史将被删除。仓库待清理记录仍会保留。")
    }
    .confirmationDialog(
      "清理本地仓库文件？",
      isPresented: cleanupExecutionPresented,
      titleVisibility: .visible,
      presenting: cleanupPendingExecution
    ) { confirmation in
      Button("清理本地文件", role: .destructive) {
        _ = store.performLocalRepositoryCleanup(
          confirmation.request.id,
          preview: confirmation.preview
        )
        cleanupPendingExecution = nil
      }
      Button("取消", role: .cancel) {
        cleanupPendingExecution = nil
      }
    } message: { confirmation in
      Text("将从已配置的本地仓库删除 \(confirmation.request.repositoryPath)。该操作有路径保护和回滚，但仍需你后续检查并提交 Git 变更。")
    }
    .confirmationDialog(
      "恢复这个版本？",
      isPresented: versionRestorePresented,
      titleVisibility: .visible,
      presenting: versionPendingRestore
    ) { version in
      Button("恢复版本", role: .destructive) {
        _ = store.restoreDraftVersion(version.id)
        versionPendingRestore = nil
      }
      Button("取消", role: .cancel) {
        versionPendingRestore = nil
      }
    } message: { _ in
      Text("恢复前会自动保存当前内容；仓库路径、远端版本和内部发布状态会保留。")
    }
    .sheet(item: $versionPendingComparison) { version in
      DraftVersionComparisonView(store: store, sourceVersion: version)
    }
    .sheet(item: $ownershipTransferPlan) { plan in
      DraftOwnershipTransferConfirmationView(plan: plan) { confirmedPlan in
        store.applyDraftOwnershipTransfer(confirmedPlan) != nil
      }
    }
  }

  private var versionHistorySection: some View {
    Section {
      if let draft = store.selectedDraft {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(draft.title.nilIfEmpty ?? "未命名文章")
              .font(.headline)
            Text("最多保留 30 个去重版本；连续编辑每 5 分钟最多记录一次。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            _ = store.createManualVersion(for: draft.id)
          } label: {
            Label("保存当前版本", systemImage: "camera")
          }
        }

        if selectedDraftVersions.isEmpty {
          ContentUnavailableView(
            "暂无版本历史",
            systemImage: "clock.arrow.circlepath",
            description: Text("编辑、手动保存、恢复或删除前会自动创建版本。")
          )
        } else {
          ForEach(selectedDraftVersions) { version in
            HStack(alignment: .top, spacing: 12) {
              Image(systemName: version.reason == .manual ? "camera.fill" : "clock.fill")
                .foregroundStyle(WorkbenchTheme.primary)
                .frame(width: 20)
              VStack(alignment: .leading, spacing: 4) {
                Text(version.reason.localizedDisplayNameKey)
                  .font(.subheadline.weight(.semibold))
                Text(version.capturedAt.formatted(date: .abbreviated, time: .shortened))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(version.draft.bodyMarkdown.trimmedForPublishing.nilIfEmpty ?? "空白正文")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              Spacer()
              Button {
                versionPendingComparison = version
              } label: {
                Label("比较", systemImage: "arrow.left.arrow.right")
              }
              .help("比较这个版本与当前文章或其他版本")
              Button("恢复") {
                versionPendingRestore = version
              }
            }
          }
        }
      } else {
        ContentUnavailableView("未选择文章", systemImage: "doc")
      }
    } header: {
      Label("当前文章版本", systemImage: "clock.arrow.circlepath")
    }
  }

  private var ownershipTransferSection: some View {
    Section {
      if let draft = store.selectedDraft {
        VStack(alignment: .leading, spacing: 10) {
          Text(draft.title.nilIfEmpty ?? "未命名文章")
            .font(.headline)

          Picker("变更方式", selection: $ownershipOperation) {
            Text("移动到站点").tag(DraftOwnershipTransferOperation.moveToSite)
            Text("复制到站点").tag(DraftOwnershipTransferOperation.copyToSite)
            Text("转为通用草稿").tag(DraftOwnershipTransferOperation.moveToGeneral)
          }

          if ownershipOperation != .moveToGeneral {
            Picker("目标站点", selection: ownershipTargetProfileBinding) {
              Text("选择站点").tag(UUID?.none)
              ForEach(ownershipTargetProfiles) { profile in
                Text(profile.name).tag(Optional(profile.id))
              }
            }
          }

          HStack {
            Text("只更新工作台中的草稿归属，不会改写原仓库文件。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("生成归属变更预览", systemImage: "arrow.right.doc.on.clipboard") {
              ownershipTransferPlan = store.draftOwnershipTransferPlan(
                draftIDs: [draft.id],
                operation: ownershipOperation,
                targetProfileID: ownershipOperation == .moveToGeneral
                  ? nil
                  : ownershipTargetProfileID
              )
            }
            .disabled(!canPreviewOwnershipTransfer)
          }
        }
        .padding(.vertical, 4)
        .onAppear {
          ownershipTargetProfileID = ownershipTargetProfileID ?? ownershipTargetProfiles.first?.id
        }
      } else {
        Text("请先在文章列表中选择一篇文章，再管理它的归属。")
          .foregroundStyle(.secondary)
      }
    } header: {
      Label("草稿归属", systemImage: "person.2.arrow.trianglehead.counterclockwise")
    } footer: {
      Text("批量归属变更仍可在文章列表的批量操作中使用。")
    }
  }

  private var recycleBinSection: some View {
    Section {
      if store.recycledDrafts.isEmpty {
        Text("回收站为空")
          .foregroundStyle(.secondary)
      } else {
        ForEach(store.recycledDrafts.sorted { $0.deletedAt > $1.deletedAt }) { recycled in
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
              VStack(alignment: .leading, spacing: 3) {
                Text(recycled.draft.title.nilIfEmpty ?? "未命名文章")
                  .font(.headline)
                Text("删除于 \(recycled.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button {
                _ = store.restoreRecycledDraft(recycled.id)
              } label: {
                Label("恢复", systemImage: "arrow.uturn.backward")
                  .foregroundStyle(WorkbenchTheme.success)
              }
              .help(Text("恢复文章并取消尚未执行的仓库清理请求"))

              Button(role: .destructive) {
                draftPendingPermanentDeletion = recycled
              } label: {
                Label("永久删除", systemImage: "trash")
                  .foregroundStyle(WorkbenchTheme.risk)
              }
              .tint(WorkbenchTheme.risk)
              .help(Text("永久删除回收站副本和版本历史"))
            }

            if let repositoryPath = recycled.draft.repositoryPath?.nilIfEmpty {
              Label(repositoryPath, systemImage: "externaldrive.badge.exclamationmark")
                .font(.caption.monospaced())
                .foregroundStyle(WorkbenchTheme.warning)
            }
          }
          .padding(.vertical, 4)
        }
      }
    } header: {
      Label("文章回收站", systemImage: "trash")
    } footer: {
      Text("恢复文章会自动取消尚未执行的仓库清理请求。")
    }
  }

  private var repositoryCleanupSection: some View {
    Section {
      if store.pendingRepositoryCleanupRequests.isEmpty {
        Text("没有待处理的仓库文件")
          .foregroundStyle(.secondary)
      } else {
        ForEach(store.pendingRepositoryCleanupRequests) { request in
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                Text(request.draftTitle.nilIfEmpty ?? "未命名文章")
                  .font(.headline)
                Text(request.repositoryPath)
                  .font(.caption.monospaced())
                  .textSelection(.enabled)
                cleanupPreviewSummary(request)
              }
              Spacer()
              Button("保留文件") {
                _ = store.keepRepositoryFile(request.id)
              }
              Button("清理本地文件", role: .destructive) {
                cleanupPendingExecution = DraftRepositoryCleanupConfirmation(
                  request: request,
                  preview: store.repositoryCleanupPreview(for: request.id)
                )
              }
            }
          }
          .padding(.vertical, 4)
        }
      }
    } header: {
      Label("仓库待清理", systemImage: "externaldrive.badge.xmark")
    } footer: {
      Text("这里只删除文章 Markdown，不自动删除可能被其他文章复用的图片。远端仓库可在提交并推送本地删除后同步。")
    }
  }

  @ViewBuilder
  private func cleanupPreviewSummary(_ request: DraftRepositoryCleanupRequest) -> some View {
    if let preview = store.repositoryCleanupPreview(for: request.id),
       let diff = preview.fileDiffs.first {
      Label(
        diff.status == .deleted ? "本地文件存在，等待清理" : "本地文件已不存在",
        systemImage: diff.status == .deleted ? "exclamationmark.triangle" : "checkmark.circle"
      )
      .font(.caption)
      .foregroundStyle(diff.status == .deleted ? WorkbenchTheme.warning : WorkbenchTheme.success)
    } else {
      Label("尚未配置可访问的本地仓库", systemImage: "questionmark.folder")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var permanentDeletionPresented: Binding<Bool> {
    Binding(
      get: { draftPendingPermanentDeletion != nil },
      set: { if !$0 { draftPendingPermanentDeletion = nil } }
    )
  }

  private var cleanupExecutionPresented: Binding<Bool> {
    Binding(
      get: { cleanupPendingExecution != nil },
      set: { if !$0 { cleanupPendingExecution = nil } }
    )
  }

  private var versionRestorePresented: Binding<Bool> {
    Binding(
      get: { versionPendingRestore != nil },
      set: { if !$0 { versionPendingRestore = nil } }
    )
  }

  private var ownershipTargetProfiles: [SiteProfile] {
    guard let draft = store.selectedDraft else { return [] }
    return store.publishingProfiles.filter { profile in
      draft.isGeneralDraft || draft.siteProfileID != profile.id
    }
  }

  private var ownershipTargetProfileBinding: Binding<UUID?> {
    Binding(
      get: { ownershipTargetProfileID },
      set: { ownershipTargetProfileID = $0 }
    )
  }

  private var canPreviewOwnershipTransfer: Bool {
    guard store.selectedDraft != nil else { return false }
    if ownershipOperation == .moveToGeneral {
      return true
    }
    return ownershipTargetProfileID != nil && !ownershipTargetProfiles.isEmpty
  }
}
