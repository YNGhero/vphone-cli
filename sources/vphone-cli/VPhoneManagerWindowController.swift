import AppKit
import SwiftUI

// MARK: - Standalone Manager Window

@MainActor
final class VPhoneManagerWindowController {
    private var window: NSWindow?
    private var model: VPhoneInstanceManager?
    private let projectRootURL: URL

    init(projectRootURL: URL) {
        self.projectRootURL = projectRootURL
    }

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = VPhoneInstanceManager(projectRootURL: projectRootURL)
        self.model = model

        let view = VPhoneManagerDashboardView(model: model)
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "vphone 多开管理器"
        window.subtitle = projectRootURL.appendingPathComponent("vm.instances", isDirectory: true).path
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 1040, height: 620)
        window.center()
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false

        window.makeKeyAndOrderFront(nil)
        self.window = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window = nil
                self?.model = nil
            }
        }
    }
}
