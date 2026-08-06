import PublishingWorkbenchCore
import SwiftUI

struct VisualContentGraphView: View {
  let store: WorkbenchStore
  @Environment(\.dismiss) private var dismiss
  @State private var topology = ArticleGraphTopology()
  @State private var nodePositions: [UUID: CGPoint] = [:]
  @State private var selectedNodeID: UUID?
  @State private var hoveredNodeID: UUID?
  @State private var isSimulating = false

  var body: some View {
    VStack(spacing: 0) {
      headerBar
      Divider()

      ZStack {
        Color(nsColor: .windowBackgroundColor)
          .ignoresSafeArea()

        if topology.nodes.isEmpty {
          ContentUnavailableView(
            "暂无可构图的文章数据",
            systemImage: "circle.hexgrid",
            description: Text("在站点新建文章并添加双向链接 [[文章标题]] 或标签，系统将自动绘制拓扑图谱。")
          )
        } else {
          graphCanvas
        }
      }

      Divider()
      footerBar
    }
    .frame(minWidth: 780, idealWidth: 880, minHeight: 520, idealHeight: 600)
    .onAppear {
      reloadTopology()
    }
  }

  private var headerBar: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text("全站文章双向关联图谱")
          .font(.title2.weight(.semibold))
        Text("力导向拓扑关系图：节点大小代表引用权重，双击节点即可进入文章编辑。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("刷新关系图") {
        reloadTopology()
      }
      Button("完成") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(WorkbenchSpacing.page)
  }

  private var graphCanvas: some View {
    GeometryReader { geometry in
      Canvas { context, _ in
        // 1. Draw Edges
        for edge in topology.edges {
          guard let posA = nodePositions[edge.sourceID],
                let posB = nodePositions[edge.targetID] else { continue }

          var path = Path()
          path.move(to: posA)
          path.addLine(to: posB)

          let isHighlight = selectedNodeID == edge.sourceID || selectedNodeID == edge.targetID
          let strokeColor: Color = isHighlight ? .accentColor : Color.gray.opacity(0.3)
          let lineWidth: CGFloat = isHighlight ? 2.5 : 1.0

          context.stroke(path, with: .color(strokeColor), lineWidth: lineWidth)
        }

        // 2. Draw Nodes
        for node in topology.nodes {
          guard let pos = nodePositions[node.id] else { continue }
          let isSelected = selectedNodeID == node.id
          let isHovered = hoveredNodeID == node.id

          let baseRadius: CGFloat = CGFloat(12 + min(20, node.incomingLinkCount * 4 + node.outgoingLinkCount * 2))
          let nodeRect = CGRect(
            x: pos.x - baseRadius,
            y: pos.y - baseRadius,
            width: baseRadius * 2,
            height: baseRadius * 2
          )

          let nodeColor: Color = isSelected ? .accentColor : (isHovered ? .orange : Color.blue.opacity(0.8))
          context.fill(Path(ellipseIn: nodeRect), with: .color(nodeColor))

          // Node Label
          let title = node.title.isEmpty ? CoreL10n.text("untitled") : node.title
          let titleText = Text(title)
            .font(.caption.weight(isSelected ? .bold : .regular))
            .foregroundColor(isSelected ? .primary : .secondary)

          context.draw(titleText, at: CGPoint(x: pos.x, y: pos.y + baseRadius + 10), anchor: .top)
        }
      }
      .gesture(
        DragGesture()
          .onChanged { value in
            if let targetID = nodeAt(location: value.startLocation, size: geometry.size) {
              selectedNodeID = targetID
              nodePositions[targetID] = value.location
            }
          }
      )
      .onTapGesture(count: 2) { location in
        if let clickedID = nodeAt(location: location, size: geometry.size) {
          openDraft(id: clickedID)
        }
      }
      .onTapGesture(count: 1) { location in
        selectedNodeID = nodeAt(location: location, size: geometry.size)
      }
    }
  }

  private var footerBar: some View {
    HStack {
      if let selectedNodeID,
         let node = topology.nodes.first(where: { $0.id == selectedNodeID }) {
        HStack(spacing: 8) {
          Text("已选择文章：\(node.title)")
            .font(.callout.weight(.medium))
          Text("(\(node.incomingLinkCount) 入链 / \(node.outgoingLinkCount) 出链)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("进入文章编辑") {
          openDraft(id: node.id)
        }
        .buttonStyle(.borderedProminent)
      } else {
        Text("共有 \(topology.nodes.count) 篇文章，\(topology.edges.count) 条双向引用关联")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
    }
    .padding(WorkbenchSpacing.page)
  }

  private func reloadTopology(size: CGSize = CGSize(width: 800, height: 520)) {
    let service = ArticleGraphRelationService()
    let newTopology = service.buildTopology(
      drafts: store.drafts,
      profileID: store.activeProfileID
    )
    self.topology = newTopology

    var positions: [UUID: CGPoint] = [:]
    let center = CGPoint(x: max(200, size.width / 2), y: max(180, size.height / 2))
    let radius: CGFloat = max(120, min(size.width, size.height) * 0.35)
    let count = max(1, newTopology.nodes.count)

    for (index, node) in newTopology.nodes.enumerated() {
      let angle = (CGFloat(index) / CGFloat(count)) * 2.0 * .pi
      let x = center.x + radius * cos(angle)
      let y = center.y + radius * sin(angle)
      positions[node.id] = CGPoint(x: x, y: y)
    }

    self.nodePositions = positions
  }

  private func nodeAt(location: CGPoint, size: CGSize) -> UUID? {
    for node in topology.nodes {
      guard let pos = nodePositions[node.id] else { continue }
      let dist = hypot(pos.x - location.x, pos.y - location.y)
      if dist <= 24 {
        return node.id
      }
    }
    return nil
  }

  private func openDraft(id: UUID) {
    _ = store.focusDraft(id, section: .writing)
    dismiss()
  }
}
