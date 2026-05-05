import AppKit
import SwiftUI

// MARK: - Instance Manager Window

@MainActor
final class VPhoneInstanceWindowController {
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

        let view = VPhoneInstanceListView(model: model)
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "多开管理器"
        window.subtitle = "vm.instances"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 860, height: 420)
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
