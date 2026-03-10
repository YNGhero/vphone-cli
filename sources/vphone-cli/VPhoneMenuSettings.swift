import AppKit

// MARK: - Settings Menu

extension VPhoneMenuController {
  func buildSettingsMenu() -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: "Settings")
    menu.autoenablesItems = false

    let get = makeItem("Read Setting...", action: #selector(readSetting))
    get.isEnabled = false
    settingsGetItem = get
    menu.addItem(get)

    let set = makeItem("Write Setting...", action: #selector(writeSetting))
    set.isEnabled = false
    settingsSetItem = set
    menu.addItem(set)

    item.submenu = menu
    return item
  }

  func updateSettingsAvailability(available: Bool) {
    settingsGetItem?.isEnabled = available
    settingsSetItem?.isEnabled = available
  }

  @objc func readSetting() {
    let alert = NSAlert()
    alert.messageText = "Read Setting"
    alert.informativeText = "Enter preference domain and key:"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Read")
    alert.addButton(withTitle: "Cancel")

    let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 350, height: 56))
    stack.orientation = .vertical
    stack.spacing = 8

    let domainField = NSTextField(frame: .zero)
    domainField.placeholderString = "com.apple.springboard"
    domainField.translatesAutoresizingMaskIntoConstraints = false
    domainField.widthAnchor.constraint(equalToConstant: 350).isActive = true

    let keyField = NSTextField(frame: .zero)
    keyField.placeholderString = "Key (leave empty for all keys)"
    keyField.translatesAutoresizingMaskIntoConstraints = false
    keyField.widthAnchor.constraint(equalToConstant: 350).isActive = true

    stack.addArrangedSubview(domainField)
    stack.addArrangedSubview(keyField)
    alert.accessoryView = stack

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let domain = domainField.stringValue
    guard !domain.isEmpty else { return }
    let key: String? = keyField.stringValue.isEmpty ? nil : keyField.stringValue

    Task {
      do {
        let value = try await control.settingsGet(domain: domain, key: key)
        let display: String
        if let dict = value as? [String: Any] {
          let data = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
          display = String(data: data, encoding: .utf8) ?? "\(dict)"
        } else {
          display = "\(value ?? "nil")"
        }
        let truncated = display.count > 2000 ? String(display.prefix(2000)) + "\n..." : display
        showAlert(
          title: "Setting: \(domain)\(key.map { ".\($0)" } ?? "")",
          message: truncated,
          style: .informational
        )
      } catch {
        showAlert(title: "Read Setting", message: "\(error)", style: .warning)
      }
    }
  }

  @objc func writeSetting() {
    let alert = NSAlert()
    alert.messageText = "Write Setting"
    alert.informativeText = "Enter preference domain, key, type, and value:"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Write")
    alert.addButton(withTitle: "Cancel")

    let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 350, height: 116))
    stack.orientation = .vertical
    stack.spacing = 8

    let domainField = NSTextField(frame: .zero)
    domainField.placeholderString = "com.apple.springboard"
    domainField.translatesAutoresizingMaskIntoConstraints = false
    domainField.widthAnchor.constraint(equalToConstant: 350).isActive = true

    let keyField = NSTextField(frame: .zero)
    keyField.placeholderString = "Key"
    keyField.translatesAutoresizingMaskIntoConstraints = false
    keyField.widthAnchor.constraint(equalToConstant: 350).isActive = true

    let typeField = NSTextField(frame: .zero)
    typeField.placeholderString = "Type: boolean | string | integer | float"
    typeField.translatesAutoresizingMaskIntoConstraints = false
    typeField.widthAnchor.constraint(equalToConstant: 350).isActive = true

    let valueField = NSTextField(frame: .zero)
    valueField.placeholderString = "Value"
    valueField.translatesAutoresizingMaskIntoConstraints = false
    valueField.widthAnchor.constraint(equalToConstant: 350).isActive = true

    stack.addArrangedSubview(domainField)
    stack.addArrangedSubview(keyField)
    stack.addArrangedSubview(typeField)
    stack.addArrangedSubview(valueField)
    alert.accessoryView = stack

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let domain = domainField.stringValue
    let key = keyField.stringValue
    let type = typeField.stringValue
    let rawValue = valueField.stringValue
    guard !domain.isEmpty, !key.isEmpty else { return }

    // Convert value based on type
    let value: Any =
      switch type.lowercased() {
      case "boolean", "bool":
        rawValue.lowercased() == "true" || rawValue == "1"
      case "integer", "int":
        Int(rawValue) ?? 0
      case "float", "double":
        Double(rawValue) ?? 0.0
      default:
        rawValue
      }

    Task {
      do {
        try await control.settingsSet(
          domain: domain, key: key, value: value, type: type.isEmpty ? nil : type)
        showAlert(
          title: "Write Setting", message: "Set \(domain).\(key) = \(rawValue)",
          style: .informational)
      } catch {
        showAlert(title: "Write Setting", message: "\(error)", style: .warning)
      }
    }
  }
}
