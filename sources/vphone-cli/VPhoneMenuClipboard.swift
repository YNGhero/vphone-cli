import AppKit

// MARK: - Clipboard Menu

extension VPhoneMenuController {
  func buildClipboardMenu() -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: "Clipboard")
    menu.autoenablesItems = false

    let get = makeItem("Get Clipboard", action: #selector(getClipboard))
    get.isEnabled = false
    clipboardGetItem = get
    menu.addItem(get)

    let set = makeItem("Set Clipboard Text...", action: #selector(setClipboardText))
    set.isEnabled = false
    clipboardSetItem = set
    menu.addItem(set)

    item.submenu = menu
    return item
  }

  func updateClipboardAvailability(available: Bool) {
    clipboardGetItem?.isEnabled = available
    clipboardSetItem?.isEnabled = available
  }

  @objc func getClipboard() {
    Task {
      do {
        let content = try await control.clipboardGet()
        var message = ""
        if let text = content.text {
          let truncated = text.count > 500 ? String(text.prefix(500)) + "..." : text
          message += "Text: \(truncated)\n"
        }
        message += "Types: \(content.types.joined(separator: ", "))\n"
        message += "Has Image: \(content.hasImage)\n"
        message += "Change Count: \(content.changeCount)"
        showAlert(title: "Clipboard Content", message: message, style: .informational)
      } catch {
        showAlert(title: "Clipboard", message: "\(error)", style: .warning)
      }
    }
  }

  @objc func setClipboardText() {
    let alert = NSAlert()
    alert.messageText = "Set Clipboard Text"
    alert.informativeText = "Enter text to set on the guest clipboard:"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Set")
    alert.addButton(withTitle: "Cancel")

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    input.placeholderString = "Text to copy to clipboard"
    alert.accessoryView = input

    let response: NSApplication.ModalResponse =
      if let window = NSApp.keyWindow {
        alert.runModal()
      } else {
        alert.runModal()
      }

    guard response == .alertFirstButtonReturn else { return }
    let text = input.stringValue
    guard !text.isEmpty else { return }

    Task {
      do {
        try await control.clipboardSet(text: text)
        showAlert(title: "Clipboard", message: "Text set successfully.", style: .informational)
      } catch {
        showAlert(title: "Clipboard", message: "\(error)", style: .warning)
      }
    }
  }
}
