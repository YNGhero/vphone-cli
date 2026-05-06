import AppKit
import Foundation

// MARK: - Standalone Manager App

final class VPhoneManagerAppDelegate: NSObject, NSApplicationDelegate {
    private let cli: VPhoneManagerCLI
    private var windowController: VPhoneManagerWindowController?

    init(cli: VPhoneManagerCLI) {
        self.cli = cli
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        UserDefaults.standard.set(120, forKey: "NSInitialToolTipDelay")
        NSApp.setActivationPolicy(.regular)
        setupMenuBar()

        let wc = VPhoneManagerWindowController(projectRootURL: cli.projectRootURL)
        windowController = wc
        wc.showWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    @MainActor
    private func setupMenuBar() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "vphone 管理器")
        appMenu.addItem(
            NSMenuItem(
                title: "退出 vphone 管理器",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        mainMenu.addItem(VPhoneStandardMenus.buildEditMenu())

        NSApp.mainMenu = mainMenu
    }
}
