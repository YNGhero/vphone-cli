import AppKit

// MARK: - Apps Menu

extension VPhoneMenuController {
  func buildAppsMenu() -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: "Apps")
    menu.autoenablesItems = false

    let list = makeItem("List Installed Apps", action: #selector(listApps))
    list.isEnabled = false
    appsListItem = list
    menu.addItem(list)

    let running = makeItem("List Running Apps", action: #selector(listRunningApps))
    running.isEnabled = false
    appsRunningItem = running
    menu.addItem(running)

    menu.addItem(NSMenuItem.separator())

    let foreground = makeItem("Foreground App", action: #selector(queryForegroundApp))
    foreground.isEnabled = false
    appsForegroundItem = foreground
    menu.addItem(foreground)

    menu.addItem(NSMenuItem.separator())

    let launch = makeItem("Launch App...", action: #selector(launchApp))
    launch.isEnabled = false
    appsLaunchItem = launch
    menu.addItem(launch)

    let terminate = makeItem("Terminate App...", action: #selector(terminateApp))
    terminate.isEnabled = false
    appsTerminateItem = terminate
    menu.addItem(terminate)

    menu.addItem(NSMenuItem.separator())

    let openURL = makeItem("Open URL...", action: #selector(openURL))
    openURL.isEnabled = false
    appsOpenURLItem = openURL
    menu.addItem(openURL)

    item.submenu = menu
    return item
  }

  func updateAppsAvailability(available: Bool) {
    appsListItem?.isEnabled = available
    appsRunningItem?.isEnabled = available
    appsForegroundItem?.isEnabled = available
    appsLaunchItem?.isEnabled = available
    appsTerminateItem?.isEnabled = available
    appsOpenURLItem?.isEnabled = available
  }

  @objc func listApps() {
    showAppList(filter: "installed")
  }

  @objc func listRunningApps() {
    showAppList(filter: "running")
  }

  private func showAppList(filter: String) {
    Task {
      do {
        let apps = try await control.appList(filter: filter)
        if apps.isEmpty {
          showAlert(title: "Apps (\(filter))", message: "No apps found.", style: .informational)
          return
        }
        let lines = apps.prefix(50).map { app in
          let pidStr = app.pid > 0 ? " (pid \(app.pid))" : ""
          return "\(app.name) — \(app.bundleId) v\(app.version) [\(app.type)]\(pidStr)"
        }
        var message = lines.joined(separator: "\n")
        if apps.count > 50 {
          message += "\n... and \(apps.count - 50) more"
        }
        showAlert(
          title: "Apps (\(filter)) — \(apps.count) total", message: message, style: .informational)
      } catch {
        showAlert(title: "Apps", message: "\(error)", style: .warning)
      }
    }
  }

  @objc func queryForegroundApp() {
    Task {
      do {
        let fg = try await control.appForeground()
        showAlert(
          title: "Foreground App",
          message: "\(fg.name)\n\(fg.bundleId)\npid: \(fg.pid)",
          style: .informational
        )
      } catch {
        showAlert(title: "Foreground App", message: "\(error)", style: .warning)
      }
    }
  }

  @objc func launchApp() {
    let alert = NSAlert()
    alert.messageText = "Launch App"
    alert.informativeText = "Enter bundle ID to launch:"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Launch")
    alert.addButton(withTitle: "Cancel")

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    input.placeholderString = "com.apple.mobilesafari"
    alert.accessoryView = input

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let bundleId = input.stringValue
    guard !bundleId.isEmpty else { return }

    Task {
      do {
        let pid = try await control.appLaunch(bundleId: bundleId)
        showAlert(
          title: "Launch App", message: "Launched \(bundleId) (pid \(pid))", style: .informational)
      } catch {
        showAlert(title: "Launch App", message: "\(error)", style: .warning)
      }
    }
  }

  @objc func terminateApp() {
    let alert = NSAlert()
    alert.messageText = "Terminate App"
    alert.informativeText = "Enter bundle ID to terminate:"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Terminate")
    alert.addButton(withTitle: "Cancel")

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    input.placeholderString = "com.apple.mobilesafari"
    alert.accessoryView = input

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let bundleId = input.stringValue
    guard !bundleId.isEmpty else { return }

    Task {
      do {
        try await control.appTerminate(bundleId: bundleId)
        showAlert(title: "Terminate App", message: "Terminated \(bundleId)", style: .informational)
      } catch {
        showAlert(title: "Terminate App", message: "\(error)", style: .warning)
      }
    }
  }

  @objc func openURL() {
    let alert = NSAlert()
    alert.messageText = "Open URL"
    alert.informativeText = "Enter URL to open on the guest:"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Open")
    alert.addButton(withTitle: "Cancel")

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
    input.placeholderString = "https://example.com"
    alert.accessoryView = input

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let url = input.stringValue
    guard !url.isEmpty else { return }

    Task {
      do {
        try await control.openURL(url)
        showAlert(title: "Open URL", message: "Opened \(url)", style: .informational)
      } catch {
        showAlert(title: "Open URL", message: "\(error)", style: .warning)
      }
    }
  }
}
