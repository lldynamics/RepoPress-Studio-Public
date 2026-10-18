import AppKit
import SwiftUI

/// SwiftUI's macOS Picker keeps its native value label at the system control
/// size. Set NSControl's font explicitly while retaining its keyboard and AX behavior.
struct WorkbenchScaledMenuPicker: NSViewRepresentable {
  struct Option: Equatable {
    let value: String
    let title: String
  }

  let title: String
  @Binding var selection: String
  let options: [Option]
  let accessibilityIdentifier: String

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection)
  }

  func makeNSView(context: Context) -> NSPopUpButton {
    let control = NSPopUpButton(frame: .zero, pullsDown: false)
    control.target = context.coordinator
    control.action = #selector(Coordinator.selectOption(_:))
    return control
  }

  func updateNSView(_ control: NSPopUpButton, context: Context) {
    context.coordinator.selection = $selection
    configure(control, scale: WorkbenchTextScale.current)
  }

  func configure(_ control: NSPopUpButton, scale: CGFloat) {
    let currentOptions = control.itemArray.map {
      Option(value: $0.representedObject as? String ?? "", title: $0.title)
    }
    if currentOptions != options {
      control.removeAllItems()
      for option in options {
        control.addItem(withTitle: option.title)
        control.lastItem?.representedObject = option.value
      }
    }
    control.selectItem(at: options.firstIndex { $0.value == selection } ?? -1)
    control.controlSize = .regular
    control.font = .systemFont(ofSize: (13 * scale).rounded())
    control.menu?.font = control.font
    control.setAccessibilityLabel(title)
    control.setAccessibilityIdentifier(accessibilityIdentifier)
    control.invalidateIntrinsicContentSize()
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context
  ) -> CGSize? {
    nsView.intrinsicContentSize
  }

  @MainActor
  final class Coordinator: NSObject {
    var selection: Binding<String>

    init(selection: Binding<String>) {
      self.selection = selection
    }

    @objc func selectOption(_ sender: NSPopUpButton) {
      guard let value = sender.selectedItem?.representedObject as? String else { return }
      selection.wrappedValue = value
    }
  }
}
