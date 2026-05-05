import AppKit
import LocalAuthentication

// MARK: - Keys Menu

extension VPhoneMenuController {
    func buildKeysMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: VPhoneMenuText.Keys.menu)
        menu.addItem(makeItem(VPhoneMenuText.Keys.home, action: #selector(sendHome)))
        menu.addItem(makeItem(VPhoneMenuText.Keys.power, action: #selector(sendPower)))
        menu.addItem(makeItem(VPhoneMenuText.Keys.volumeUp, action: #selector(sendVolumeUp)))
        menu.addItem(makeItem(VPhoneMenuText.Keys.volumeDown, action: #selector(sendVolumeDown)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem(VPhoneMenuText.Keys.spotlight, action: #selector(sendSpotlight)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem(VPhoneMenuText.Keys.typeASCII, action: #selector(typeFromClipboard)))
        menu.addItem(NSMenuItem.separator())
        let tidItem = makeItem(
            VPhoneMenuText.Keys.touchIDForwarding, action: #selector(toggleTouchIDForwarding)
        )
        if hasTouchID {
            let tidEnabled = !UserDefaults.standard.bool(forKey: "touchIDForwardingDisabled")
            tidItem.state = tidEnabled ? .on : .off
        } else {
            tidItem.isEnabled = false
            tidItem.state = .off
        }
        touchIDMenuItem = tidItem
        menu.addItem(tidItem)
        item.submenu = menu
        return item
    }

    @objc func sendHome() {
        keyHelper.sendHome()
    }

    @objc func sendPower() {
        keyHelper.sendPower()
    }

    @objc func sendVolumeUp() {
        keyHelper.sendVolumeUp()
    }

    @objc func sendVolumeDown() {
        keyHelper.sendVolumeDown()
    }

    @objc func sendSpotlight() {
        keyHelper.sendSpotlight()
    }

    @objc func typeFromClipboard() {
        keyHelper.typeFromClipboard()
    }

    @objc func toggleTouchIDForwarding() {
        guard let monitor = touchIDMonitor, let item = touchIDMenuItem else { return }
        monitor.isEnabled.toggle()
        item.state = monitor.isEnabled ? .on : .off
        UserDefaults.standard.set(!monitor.isEnabled, forKey: "touchIDForwardingDisabled")
    }
}

private extension VPhoneMenuController {
    var hasTouchID: Bool {
        let ctx = LAContext()
        ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType == .touchID
    }
}
