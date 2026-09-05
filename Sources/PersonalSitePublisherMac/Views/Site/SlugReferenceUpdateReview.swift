import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SlugReferenceUpdateReview: Identifiable {
  struct Change: Identifiable {
    let id: String
    let draftID: UUID
    let title: String
    let path: String
    let oldTarget: String
    let newTarget: String
  }

  struct Article: Identifiable {
    let id: UUID
    let title: String
    let path: String
    let changes: [Change]
  }

  let id = UUID()
  let profileID: UUID
  let impact: SlugChangeImpact
  let targetSlug: String
  let articles: [Article]

  init?(
    profileID: UUID, impact: SlugChangeImpact, targetSlug: String,
    sources: [UUID: (draft: ArticleDraft, body: String, path: String)]
  ) {
    var changes: [Change] = []
    for reference in impact.references {
      guard let source = sources[reference.sourceDraftID] else { return nil }
      let body = source.body as NSString
      let range = reference.targetUTF16Range
      guard range.location >= 0, range.length >= 0,
        range.location <= body.length, range.length <= body.length - range.location
      else { return nil }
      let newTarget =
        reference.syntax == .wiki
        ? (targetSlug.trimmedForPublishing.nilIfEmpty
          ?? impact.newRoute.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        : impact.newRoute
      changes.append(
        Change(
          id: reference.id, draftID: reference.sourceDraftID,
          title: source.draft.title, path: source.path,
          oldTarget: body.substring(with: range), newTarget: newTarget))
    }
    self.profileID = profileID
    self.impact = impact
    self.targetSlug = targetSlug
    articles = Dictionary(grouping: changes, by: \.draftID).compactMap { id, changes in
      guard let first = changes.first else { return nil }
      return Article(id: id, title: first.title, path: first.path, changes: changes)
    }.sorted { ($0.path, $0.id.uuidString) < ($1.path, $1.id.uuidString) }
  }
}

struct SlugReferenceUpdateResult {
  let application: SlugChangeApplicationResult
  let review: SlugReferenceUpdateReview?
}

struct SlugReferenceUpdateReviewSheet: View {
  let review: SlugReferenceUpdateReview
  let confirm: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("审阅 Slug 引用更新")
        .font(.headline)
      Text(review.impact.targetTitle)
        .font(.callout.weight(.medium))
      Text("将更新 \(review.impact.affectedDraftCount) 篇文章中的 \(review.impact.referenceCount) 处引用。")
      Text("仅替换以下链接目标，保留链接文字、查询参数和锚点；更新前会创建恢复版本。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          ForEach(review.articles) { article in
            VStack(alignment: .leading, spacing: 8) {
              Text(article.title).font(.callout.weight(.semibold))
              Text(article.path).font(.caption.monospaced()).textSelection(.enabled)
              ForEach(article.changes) { change in
                VStack(alignment: .leading, spacing: 4) {
                  Label("原目标：\(change.oldTarget)", systemImage: "minus.circle")
                  Label("新目标：\(change.newTarget)", systemImage: "plus.circle")
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          if review.articles.isEmpty {
            Text("没有需要替换的站内引用。确认后将清除本次待处理的 Slug 变更。")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Button("取消", role: .cancel) { dismiss() }
        Spacer()
        Button("确认更新 \(review.impact.referenceCount) 处引用") { confirm() }
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("content-health-confirm-slug-references")
      }
    }
    .padding(20)
    .frame(minWidth: 620, idealWidth: 760, minHeight: 460, idealHeight: 580)
  }
}

struct SlugReferenceUpdateResultView: View {
  let result: SlugReferenceUpdateResult
  let openVersions: (UUID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      AccessibleStatusMessage(
        message: result.application.message,
        severity: result.application.wasApplied ? .success : .error)
      if result.application.wasApplied, let review = result.review {
        DisclosureGroup(String(localized: "查看更新文章与恢复版本")) {
          ForEach(review.articles) { article in
            Button {
              openVersions(article.id)
            } label: {
              Label("查看/恢复版本：\(article.title)", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.link)
            .help(article.path)
          }
          Button("查看目标文章的恢复版本") { openVersions(review.impact.targetDraftID) }
            .buttonStyle(.link)
        }
      }
    }
    .padding(12)
    .accessibilityIdentifier("content-health-slug-update-result")
  }
}
