import PublishingGitCore
import SwiftUI

/// The small, value-only presentation model used by the branch graph.
///
/// Keeping this separate from Git and view state makes the graph useful in both
/// the sync confirmation sheet and conflict-resolution surfaces.
struct RepositoryBranchGraphPresentation: Equatable, Sendable {
  enum NodeKind: Hashable, Sendable {
    case common
    case local
    case remote
  }

  struct Node: Equatable, Sendable, Identifiable {
    let kind: NodeKind
    let label: String
    let sha: String?

    var id: NodeKind { kind }
  }

  let branchName: String
  let upstreamName: String
  let localHeadSHA: String?
  let remoteHeadSHA: String?
  let aheadCount: Int
  let behindCount: Int

  init(
    branchName: String?,
    upstreamName: String?,
    aheadCount: Int,
    behindCount: Int,
    localHeadSHA: String? = nil,
    remoteHeadSHA: String? = nil
  ) {
    self.branchName = branchName?.nilIfEmpty ?? "当前分支"
    self.upstreamName = upstreamName?.nilIfEmpty ?? "远端分支"
    self.localHeadSHA = localHeadSHA?.nilIfEmpty
    self.remoteHeadSHA = remoteHeadSHA?.nilIfEmpty
    self.aheadCount = max(0, aheadCount)
    self.behindCount = max(0, behindCount)
  }

  init(
    status: RepositoryBranchStatus,
    localHeadSHA: String? = nil,
    remoteHeadSHA: String? = nil
  ) {
    self.init(
      branchName: status.branchName,
      upstreamName: status.upstreamName,
      aheadCount: status.aheadCount,
      behindCount: status.behindCount,
      localHeadSHA: localHeadSHA,
      remoteHeadSHA: remoteHeadSHA
    )
  }

  var isSynchronized: Bool { aheadCount == 0 && behindCount == 0 }
  var isDiverged: Bool { aheadCount > 0 && behindCount > 0 }

  var localLabel: String { "Local (Ahead \(aheadCount))" }
  var remoteLabel: String { "Remote (Behind \(behindCount))" }

  /// The common node is retained in all states so the two tips read as a
  /// timeline, while zero-distance branches remain a single shared tip.
  var nodes: [Node] {
    var result = [Node(kind: .common, label: "共同节点", sha: commonSHA)]
    if !isSynchronized {
      if aheadCount > 0 { result.append(Node(kind: .local, label: localLabel, sha: localHeadSHA)) }
      if behindCount > 0 {
        result.append(Node(kind: .remote, label: remoteLabel, sha: remoteHeadSHA))
      }
    }
    return result
  }

  var commonSHA: String? {
    guard let localHeadSHA, let remoteHeadSHA, localHeadSHA == remoteHeadSHA else { return nil }
    return localHeadSHA
  }

  var accessibilitySummary: String {
    if isSynchronized {
      return "分支图：\(branchName) 与 \(upstreamName) 已同步，共同节点\(shaDescription(commonSHA))。"
    }
    let state = isDiverged ? "已分叉" : (behindCount > 0 ? "本地落后远端" : "本地领先远端")
    return
      "分支图：\(branchName) 对比 \(upstreamName)，\(state)。\(localLabel)，\(remoteLabel)。共同节点\(shaDescription(commonSHA))。"
  }

  private func shaDescription(_ sha: String?) -> String {
    guard let sha else { return "SHA 未提供" }
    return "SHA \(String(sha.prefix(12)))"
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A compact timeline showing the shared base and the local/remote tips.
struct RepositoryBranchGraphWidget: View {
  let presentation: RepositoryBranchGraphPresentation

  init(presentation: RepositoryBranchGraphPresentation) {
    self.presentation = presentation
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("分支时间线", systemImage: "arrow.triangle.branch")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(presentation.isSynchronized ? "已同步" : presentation.isDiverged ? "已分叉" : "待同步")
          .font(.caption.weight(.medium))
          .foregroundStyle(presentation.isSynchronized ? .secondary : .primary)
      }
      graph
      HStack(spacing: 14) {
        legendDot(.accentColor, text: presentation.localLabel)
        legendDot(.secondary, text: presentation.remoteLabel)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.accessibilitySummary)
    .accessibilityIdentifier("repository-branch-graph")
  }

  private var graph: some View {
    GeometryReader { proxy in
      let midY = proxy.size.height / 2
      let branchY = max(18, proxy.size.height * 0.22)
      ZStack {
        Path { path in
          path.move(to: CGPoint(x: 24, y: midY))
          if presentation.aheadCount > 0 {
            path.addLine(to: CGPoint(x: proxy.size.width - 24, y: branchY))
          }
          if presentation.behindCount > 0 {
            path.move(to: CGPoint(x: 24, y: midY))
            path.addLine(to: CGPoint(x: proxy.size.width - 24, y: proxy.size.height - branchY))
          }
        }
        .stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        graphNode(kind: .common, at: CGPoint(x: 24, y: midY), color: .secondary)
        if presentation.aheadCount > 0 {
          graphNode(
            kind: .local, at: CGPoint(x: proxy.size.width - 24, y: branchY), color: .accentColor)
        }
        if presentation.behindCount > 0 {
          graphNode(
            kind: .remote, at: CGPoint(x: proxy.size.width - 24, y: proxy.size.height - branchY),
            color: .secondary)
        }
      }
    }
    .frame(height: 68)
    .frame(maxWidth: .infinity)
    .accessibilityHidden(true)
  }

  private func graphNode(
    kind: RepositoryBranchGraphPresentation.NodeKind, at point: CGPoint, color: Color
  ) -> some View {
    Circle()
      .fill(color)
      .frame(width: 9, height: 9)
      .position(point)
  }

  private func legendDot(_ color: Color, text: String) -> some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(text)
    }
  }
}
