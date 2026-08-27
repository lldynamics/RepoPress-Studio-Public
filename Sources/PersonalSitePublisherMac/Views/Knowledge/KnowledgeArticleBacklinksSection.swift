import PublishingWorkbenchCore
import SwiftUI

private struct KnowledgeArticleCitationGroup: Identifiable {
  let documentID: UUID
  let documentTitle: String
  let backlinks: [KnowledgeBacklink]

  var id: UUID { documentID }
}

/// Shows the knowledge sources cited by the current article. The knowledge
/// library owns the persisted relationship; this section is the article-side
/// view of the same relationship.
struct KnowledgeArticleBacklinksSection: View {
  let draft: ArticleDraft
  @ObservedObject var knowledge: KnowledgeStore
  let onOpenDocument: (UUID) -> Void
  @State private var expandedDocumentIDs = Set<UUID>()

  private var groups: [KnowledgeArticleCitationGroup] {
    Dictionary(grouping: knowledge.articleBacklinks, by: \.documentID)
      .compactMap { documentID, backlinks in
        guard !backlinks.isEmpty else { return nil }
        let title = knowledge.documents.first(where: { $0.id == documentID })?.title
          ?? "已删除资料"
        return KnowledgeArticleCitationGroup(
          documentID: documentID,
          documentTitle: title,
          backlinks: backlinks.sorted { $0.createdAt > $1.createdAt }
        )
      }
      .sorted {
        if $0.documentTitle != $1.documentTitle {
          return $0.documentTitle.localizedStandardCompare($1.documentTitle) == .orderedAscending
        }
        return $0.documentID.uuidString < $1.documentID.uuidString
      }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label("本文引用的资料", systemImage: "link.badge.plus")
          .font(.workbenchCardTitle)
        Spacer(minLength: 6)
        if knowledge.isLoadingArticleBacklinks {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("正在读取本文引用")
        } else {
          Text("\(groups.count) 条资料 · \(knowledge.articleBacklinks.count) 个片段")
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
        }
      }

      if knowledge.isLoadingArticleBacklinks && groups.isEmpty {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("正在读取本文引用…")
            .font(.workbenchSupporting)
            .foregroundStyle(.secondary)
        }
      } else if groups.isEmpty {
        Text("在右侧知识建议中插入引用后，这里会自动显示资料反向链接。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      } else {
        ForEach(groups) { group in
          citationGroupRow(group)
        }
      }
    }
    .padding(12)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("knowledge-article-backlinks-section")
    .accessibilityLabel("本文引用的资料")
    .onChange(of: draft.id) { _, _ in
      expandedDocumentIDs.removeAll()
    }
  }

  private func citationGroupRow(_ group: KnowledgeArticleCitationGroup) -> some View {
    DisclosureGroup(
      isExpanded: Binding(
        get: { expandedDocumentIDs.contains(group.documentID) },
        set: { expanded in
          if expanded {
            expandedDocumentIDs.insert(group.documentID)
          } else {
            expandedDocumentIDs.remove(group.documentID)
          }
        }
      )
    ) {
      VStack(alignment: .leading, spacing: 7) {
        ForEach(group.backlinks.prefix(3)) { backlink in
          VStack(alignment: .leading, spacing: 3) {
            Text(backlink.chunkLocator?.nilIfEmpty ?? "资料正文")
              .font(.workbenchMetadata.weight(.medium))
            if let excerpt = backlink.chunkExcerpt?.nilIfEmpty {
              Text(excerpt)
                .font(.workbenchMetadata)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if group.backlinks.count > 3 {
          Text("还有 \(group.backlinks.count - 3) 个片段")
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.top, 6)
      .padding(.leading, 26)
    } label: {
      Button {
        onOpenDocument(group.documentID)
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: "books.vertical")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text(group.documentTitle)
            .font(.workbenchSupporting.weight(.medium))
            .workbenchTruncatedIdentity(group.documentTitle)
          Spacer(minLength: 4)
          Text("引用 \(group.backlinks.count)")
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
        }
      }
      .buttonStyle(.plain)
      .help("在资料库中打开“\(group.documentTitle)”")
      .accessibilityLabel("打开资料：\(group.documentTitle)")
    }
    .accessibilityElement(children: .contain)
  }
}
