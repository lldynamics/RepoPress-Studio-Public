import Foundation
import PublishingDomainContracts
import SwiftUI

struct RepositoryImageArticleUsage: Equatable {
  let draftID: UUID
  let attachmentID: UUID
  let altText: String
  let caption: String
  let isCover: Bool
}

struct RepositoryImageTargetDraft: Identifiable {
  let id: UUID
  let title: String
}

struct RepositoryImageInspectorUsageView: View {
  let asset: RepositoryImageAsset
  let availableDrafts: [RepositoryImageTargetDraft]
  @Binding var targetDraftID: UUID?
  let usage: RepositoryImageArticleUsage?
  let isWorking: Bool
  let saveStatusText: String?
  let saveStatusIsError: Bool
  let onEditAlt: (String) -> Void
  let onEditCaption: (String) -> Void
  let onSetCover: (Bool) -> Void
  let onFillMetadata: () -> Void
  let onAttach: (UUID) -> Void
  let onOpenDraft: (UUID) -> Void

  private var selectedDraft: RepositoryImageTargetDraft? {
    guard let targetDraftID else { return nil }
    return availableDrafts.first(where: { $0.id == targetDraftID })
  }

  private var selectedUsage: RepositoryImageArticleUsage? {
    guard let targetDraftID, usage?.draftID == targetDraftID else { return nil }
    return usage
  }

  private var alreadyReferencedDraftIDs: Set<UUID> {
    Set(asset.references.map(\.draftID))
  }

  private var otherAttachableDrafts: [RepositoryImageTargetDraft] {
    availableDrafts.filter { !alreadyReferencedDraftIDs.contains($0.id) }
  }

  private var needsMetadataFill: Bool {
    guard let selectedUsage else { return false }
    return selectedUsage.altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || selectedUsage.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      targetControls
      usageContent
      otherArticleMenu
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(String(localized: "图片文章用法"))
    .accessibilityIdentifier("repository-image-article-usage")
  }

  private var targetControls: some View {
    VStack(alignment: .leading, spacing: 7) {
      Picker(String(localized: "目标文章"), selection: $targetDraftID) {
        Text(String(localized: "选择文章"))
          .tag(nil as UUID?)
        ForEach(availableDrafts) { draft in
          Text(draftTitle(draft))
            .tag(Optional(draft.id))
        }
      }
      .accessibilityIdentifier("repository-image-target-picker")

      if let selectedDraft {
        HStack(spacing: 8) {
          Text(draftTitle(selectedDraft))
            .font(.caption)
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(draftTitle(selectedDraft), lineLimit: 2)
          Spacer(minLength: 4)
          Button {
            onOpenDraft(selectedDraft.id)
          } label: {
            Label(String(localized: "打开文章"), systemImage: "arrow.right.circle")
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .accessibilityIdentifier("repository-image-open-target-article")
        }
      }
    }
  }

  @ViewBuilder
  private var usageContent: some View {
    if let selectedUsage {
      VStack(alignment: .leading, spacing: 9) {
        Text(String(localized: "以下说明仅应用到当前选择的文章。"))
          .font(.caption)
          .foregroundStyle(.secondary)

        Text(String(localized: "Alt 文本"))
          .font(.caption)
          .accessibilityHidden(true)
        TextField(
          String(localized: "Alt 文本"),
          text: Binding(
            get: { selectedUsage.altText },
            set: { onEditAlt($0) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .disabled(isWorking)
        .help(isWorking ? String(localized: "正在批处理图片，暂时不能编辑。") : "")
        .accessibilityLabel(String(localized: "图片 Alt 文本"))
        .accessibilityIdentifier("repository-image-alt-text")

        Text(String(localized: "Caption（可选）"))
          .font(.caption)
          .accessibilityHidden(true)
        TextField(
          String(localized: "Caption（可选）"),
          text: Binding(
            get: { selectedUsage.caption },
            set: { onEditCaption($0) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .disabled(isWorking)
        .help(isWorking ? String(localized: "正在批处理图片，暂时不能编辑。") : "")
        .accessibilityLabel(String(localized: "图片 Caption"))
        .accessibilityIdentifier("repository-image-caption")

        Toggle(
          String(localized: "设为文章封面"),
          isOn: Binding(
            get: { selectedUsage.isCover },
            set: { onSetCover($0) }
          )
        )
        .toggleStyle(.checkbox)
        .disabled(isWorking)
        .help(isWorking ? String(localized: "正在批处理图片，暂时不能更改封面。") : "")
        .accessibilityIdentifier("repository-image-set-cover")

        if needsMetadataFill {
          Button {
            onFillMetadata()
          } label: {
            Label(String(localized: "补全缺失说明"), systemImage: "text.badge.checkmark")
          }
          .buttonStyle(.bordered)
          .disabled(isWorking)
          .help(isWorking ? String(localized: "正在批处理图片，暂时不能补全。") : "")
          .accessibilityIdentifier("repository-image-fill-metadata")
        }

        if isWorking {
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.small)
            Text(String(localized: "正在处理图片…"))
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("repository-image-saving")
        } else if let saveStatusText {
          Text(saveStatusText)
            .font(.caption)
            .foregroundStyle(saveStatusIsError ? .red : .secondary)
            .workbenchTruncatedIdentity(saveStatusText, lineLimit: 2)
            .accessibilityIdentifier("repository-image-save-status")
        }
      }
    } else if let selectedDraft {
      if alreadyReferencedDraftIDs.contains(selectedDraft.id) {
        Label(String(localized: "这张图片已登记到当前文章。"), systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text(String(localized: "当前文章尚未使用这张图片。加入后可在此编辑说明和封面状态。"))
            .font(.caption)
            .foregroundStyle(.secondary)
          Button {
            onAttach(selectedDraft.id)
          } label: {
            Label(String(localized: "加入当前文章"), systemImage: "plus.circle")
          }
          .workbenchProminentActionStyle()
          .disabled(isWorking)
          .help(isWorking ? String(localized: "正在批处理图片，暂时不能加入文章。") : "")
          .accessibilityIdentifier("repository-image-attach-target")
        }
      }
    } else if availableDrafts.isEmpty {
      Text(String(localized: "当前站点还没有可选文章。"))
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Text(String(localized: "选择一篇文章后，可查看或加入这张图片。"))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var otherArticleMenu: some View {
    if !otherAttachableDrafts.isEmpty {
      Menu {
        ForEach(otherAttachableDrafts) { draft in
          Button(draftTitle(draft)) {
            onAttach(draft.id)
          }
          .disabled(isWorking)
          .accessibilityIdentifier("repository-image-attach-other-\(draft.id.uuidString)")
        }
      } label: {
        Label(String(localized: "加入其他文章"), systemImage: "plus.rectangle.on.folder")
      }
      .disabled(isWorking)
      .help(isWorking ? String(localized: "正在批处理图片，暂时不能加入其他文章。") : "")
      .accessibilityIdentifier("repository-image-attach-other-menu")
    }
  }

  private func draftTitle(_ draft: RepositoryImageTargetDraft) -> String {
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? String(localized: "未命名文章") : title
  }
}
