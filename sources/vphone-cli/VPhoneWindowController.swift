import AppKit
import Foundation
import Virtualization

@MainActor
class VPhoneWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private var windowController: NSWindowController?
    private var statusTimer: Timer?
    private weak var control: VPhoneControl?
    private weak var virtualMachineView: VPhoneVirtualMachineView?
    private(set) var touchIDMonitor: VPhoneTouchIDMonitor?
    private var ecid: String?
    private var guestConnected = false
    private var installPackageAvailable = false
    private static let sidebarWidth: CGFloat = 35

    private nonisolated static let homeItemID = NSToolbarItem.Identifier("home")
    private nonisolated static let installPackageItemID = NSToolbarItem.Identifier("install-package")
    private nonisolated static let importPhotoItemID = NSToolbarItem.Identifier("import-photo")
    private nonisolated static let typeASCIIItemID = NSToolbarItem.Identifier("type-ascii")
    private nonisolated static let deletePhotosItemID = NSToolbarItem.Identifier("delete-photos")
    private nonisolated static let screenshotItemID = NSToolbarItem.Identifier("screenshot")
    private nonisolated static let rebootItemID = NSToolbarItem.Identifier("reboot")
    private nonisolated static let respringItemID = NSToolbarItem.Identifier("respring")
    private nonisolated static let connectionInfoItemID = NSToolbarItem.Identifier("connection-info")

    private weak var homeToolbarItem: NSToolbarItem?
    private weak var installPackageToolbarItem: NSToolbarItem?
    private weak var importPhotoToolbarItem: NSToolbarItem?
    private weak var typeASCIIToolbarItem: NSToolbarItem?
    private weak var deletePhotosToolbarItem: NSToolbarItem?
    private weak var screenshotToolbarItem: NSToolbarItem?
    private weak var rebootToolbarItem: NSToolbarItem?
    private weak var respringToolbarItem: NSToolbarItem?
    private weak var connectionInfoToolbarItem: NSToolbarItem?
    private weak var homeSidebarButton: NSButton?
    private weak var installPackageSidebarButton: NSButton?
    private weak var importPhotoSidebarButton: NSButton?
    private weak var typeASCIISidebarButton: NSButton?
    private weak var deletePhotosSidebarButton: NSButton?
    private weak var screenshotSidebarButton: NSButton?
    private weak var rebootSidebarButton: NSButton?
    private weak var respringSidebarButton: NSButton?
    private weak var connectionInfoSidebarButton: NSButton?

    var onInstallPackagePressed: (() -> Void)? {
        didSet { refreshToolbarAvailability() }
    }
    var onImportPhotoPressed: (() -> Void)? {
        didSet { refreshToolbarAvailability() }
    }
    var onTypeASCIIPressed: (() -> Void)? {
        didSet { refreshToolbarAvailability() }
    }
    var onDeletePhotosPressed: (() -> Void)? {
        didSet { refreshToolbarAvailability() }
    }
    var onScreenshotPressed: (() -> Void)? {
        didSet { refreshToolbarAvailability() }
    }
    var onRebootPressed: (() -> Void)? {
        didSet { refreshToolbarAvailability() }
    }
    var onRespringPressed: (() -> Void)? {
        didSet { refreshToolbarAvailability() }
    }
    var onConnectionInfoPressed: (() -> Void)? {
        didSet { refreshToolbarAvailability() }
    }

    var captureView: VPhoneVirtualMachineView? {
        virtualMachineView
    }

    func showWindow(
        for vm: VZVirtualMachine, screenWidth: Int, screenHeight: Int, screenScale: Double,
        keyHelper: VPhoneKeyHelper, control: VPhoneControl, ecid: String?
    ) {
        self.control = control
        self.ecid = ecid

        let view = VPhoneVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        view.keyHelper = keyHelper
        view.control = control
        virtualMachineView = view
        let vmView: NSView = view

        let scale = CGFloat(screenScale)
        let vmContentSize = NSSize(
            width: CGFloat(screenWidth) / scale, height: CGFloat(screenHeight) / scale
        )
        let windowSize = NSSize(
            width: vmContentSize.width + Self.sidebarWidth, height: vmContentSize.height
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: Self.sidebarWidth + 260, height: 520)
        window.title = "VPHONE [loading]"
        window.subtitle = makeSubtitle(ip: nil)
        window.contentView = makeContentView(vmView: vmView, vmContentSize: vmContentSize)
        if let ecid {
            if !window.setFrameAutosaveName("vphone-\(ecid)") {
                window.center()
            }
        } else {
            window.center()
        }

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        windowController = controller

        keyHelper.window = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        let monitor = VPhoneTouchIDMonitor()
        monitor.start(control: control, window: window)
        touchIDMonitor = monitor

        // Poll vphoned status for title indicator
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, let control = self.control else { return }
                window.title = control.isConnected ? "VPHONE [connected]" : "VPHONE [disconnected]"
                window.subtitle = self.makeSubtitle(ip: control.isConnected ? control.guestIP : nil)
            }
        }
        refreshToolbarAvailability()
    }

    func showExistingWindow() {
        guard let window = windowController?.window else { return }
        window.makeKeyAndOrderFront(nil)
        if let virtualMachineView {
            window.makeFirstResponder(virtualMachineView)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Treat the close button/Cmd-W as "hide GUI", not "power off VM".
        // The VM process, host-control socket, and SSH/VNC/RPC forwards keep
        // running in the background.  Use the standalone manager's Stop action
        // or Cmd-Q/kill to actually terminate this instance.
        sender.orderOut(nil)
        return false
    }

    private func makeContentView(vmView: NSView, vmContentSize: NSSize) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        vmView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSVisualEffectView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 3, bottom: 6, right: 3)

        homeSidebarButton = makeSidebarButton(
            title: "主屏幕", symbolName: "circle.circle", action: #selector(homePressed)
        )
        installPackageSidebarButton = makeSidebarButton(
            title: "安装 IPA", symbolName: "square.and.arrow.down", action: #selector(installPackagePressed)
        )
        importPhotoSidebarButton = makeSidebarButton(
            title: "导入图片", symbolName: "photo.on.rectangle", action: #selector(importPhotoPressed)
        )
        typeASCIISidebarButton = makeSidebarButton(
            title: "粘贴输入ASCII", symbolName: "keyboard", action: #selector(typeASCIIPressed)
        )
        deletePhotosSidebarButton = makeSidebarButton(
            title: "清空相册", symbolName: "trash", action: #selector(deletePhotosPressed)
        )
        screenshotSidebarButton = makeSidebarButton(
            title: "截图", symbolName: "camera.viewfinder", action: #selector(screenshotPressed)
        )
        rebootSidebarButton = makeSidebarButton(
            title: "重启", symbolName: "arrow.clockwise", action: #selector(rebootPressed)
        )
        respringSidebarButton = makeSidebarButton(
            title: "Restart SpringBoard",
            symbolName: "arrow.triangle.2.circlepath",
            action: #selector(respringPressed)
        )
        connectionInfoSidebarButton = makeSidebarButton(
            title: "SSH 信息", symbolName: "info.circle", action: #selector(connectionInfoPressed)
        )

        [
            homeSidebarButton,
            installPackageSidebarButton,
            importPhotoSidebarButton,
            typeASCIISidebarButton,
            deletePhotosSidebarButton,
            screenshotSidebarButton,
            rebootSidebarButton,
            respringSidebarButton,
            connectionInfoSidebarButton,
        ].compactMap { $0 }.forEach { stack.addArrangedSubview($0) }

        sidebar.addSubview(stack)
        container.addSubview(vmView)
        container.addSubview(sidebar)

        let aspect = vmView.widthAnchor.constraint(
            equalTo: vmView.heightAnchor,
            multiplier: vmContentSize.width / vmContentSize.height
        )
        aspect.priority = .defaultHigh

        NSLayoutConstraint.activate([
            vmView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vmView.topAnchor.constraint(equalTo: container.topAnchor),
            vmView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            vmView.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            aspect,

            sidebar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),

            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor),
        ])

        return container
    }

    private func makeSubtitle(ip: String?) -> String {
        switch (ecid, ip) {
        case let (ecid?, ip?): "\(ecid) — \(ip)"
        case let (ecid?, nil): ecid
        case let (nil, ip?): ip
        case (nil, nil): ""
        }
    }

    // MARK: - NSToolbarDelegate

    nonisolated func toolbar(
        _: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            if itemIdentifier == Self.homeItemID {
                let item = makeToolbarItem(
                    itemIdentifier,
                    label: "主屏幕",
                    toolTip: "发送 Home 键",
                    symbolName: "circle.circle",
                    action: #selector(homePressed)
                )
                homeToolbarItem = item
                refreshToolbarAvailability()
                return item
            }
            if itemIdentifier == Self.installPackageItemID {
                let item = makeToolbarItem(
                    itemIdentifier,
                    label: "安装 IPA",
                    toolTip: "安装 IPA/TIPA 到当前实例",
                    symbolName: "square.and.arrow.down",
                    action: #selector(installPackagePressed)
                )
                installPackageToolbarItem = item
                refreshToolbarAvailability()
                return item
            }
            if itemIdentifier == Self.importPhotoItemID {
                let item = makeToolbarItem(
                    itemIdentifier,
                    label: "导入图片",
                    toolTip: "导入图片到 guest 相册",
                    symbolName: "photo.on.rectangle",
                    action: #selector(importPhotoPressed)
                )
                importPhotoToolbarItem = item
                refreshToolbarAvailability()
                return item
            }
            if itemIdentifier == Self.typeASCIIItemID {
                let item = makeToolbarItem(
                    itemIdentifier,
                    label: "粘贴输入ASCII",
                    toolTip: "把 macOS 剪贴板里的 ASCII 输入到当前焦点",
                    symbolName: "keyboard",
                    action: #selector(typeASCIIPressed)
                )
                typeASCIIToolbarItem = item
                refreshToolbarAvailability()
                return item
            }
            if itemIdentifier == Self.deletePhotosItemID {
                let item = makeToolbarItem(
                    itemIdentifier,
                    label: "清空相册",
                    toolTip: "清空 guest 照片库里的所有照片/视频",
                    symbolName: "trash",
                    action: #selector(deletePhotosPressed)
                )
                deletePhotosToolbarItem = item
                refreshToolbarAvailability()
                return item
            }
            if itemIdentifier == Self.screenshotItemID {
                let item = makeToolbarItem(
                    itemIdentifier,
                    label: "截图",
                    toolTip: "保存当前画面截图",
                    symbolName: "camera.viewfinder",
                    action: #selector(screenshotPressed)
                )
                screenshotToolbarItem = item
                refreshToolbarAvailability()
                return item
            }
            if itemIdentifier == Self.rebootItemID {
                let item = makeToolbarItem(
                    itemIdentifier,
                    label: "重启",
                    toolTip: "通过 SSH 重启 guest",
                    symbolName: "arrow.clockwise",
                    action: #selector(rebootPressed)
                )
                rebootToolbarItem = item
                refreshToolbarAvailability()
                return item
            }
            if itemIdentifier == Self.respringItemID {
                let item = makeToolbarItem(
                    itemIdentifier,
                    label: "Restart SpringBoard",
                    toolTip: "重启 SpringBoard，快速注销当前桌面",
                    symbolName: "arrow.triangle.2.circlepath",
                    action: #selector(respringPressed)
                )
                respringToolbarItem = item
                refreshToolbarAvailability()
                return item
            }
            if itemIdentifier == Self.connectionInfoItemID {
                let item = makeToolbarItem(
                    itemIdentifier,
                    label: "SSH 信息",
                    toolTip: "查看 SSH/VNC/RPC/UDID/ECID 信息",
                    symbolName: "info.circle",
                    action: #selector(connectionInfoPressed)
                )
                connectionInfoToolbarItem = item
                refreshToolbarAvailability()
                return item
            }
            return nil
        }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.homeItemID,
            .space,
            Self.installPackageItemID,
            Self.importPhotoItemID,
            Self.typeASCIIItemID,
            Self.deletePhotosItemID,
            Self.screenshotItemID,
            Self.rebootItemID,
            Self.respringItemID,
            Self.connectionInfoItemID,
        ]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.homeItemID,
            Self.installPackageItemID,
            Self.importPhotoItemID,
            Self.typeASCIIItemID,
            Self.deletePhotosItemID,
            Self.screenshotItemID,
            Self.rebootItemID,
            Self.respringItemID,
            Self.connectionInfoItemID,
            .flexibleSpace,
            .space,
        ]
    }

    func updateToolbarAvailability(connected: Bool, canInstallPackage: Bool) {
        guestConnected = connected
        installPackageAvailable = canInstallPackage
        refreshToolbarAvailability()
    }

    private func makeToolbarItem(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        toolTip: String,
        symbolName: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.target = self
        item.action = action
        return item
    }

    private func makeSidebarButton(title: String, symbolName: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 29).isActive = true
        button.heightAnchor.constraint(equalToConstant: 29).isActive = true
        return button
    }

    private func refreshToolbarAvailability() {
        homeToolbarItem?.isEnabled = guestConnected
        installPackageToolbarItem?.isEnabled =
            installPackageAvailable && onInstallPackagePressed != nil
        importPhotoToolbarItem?.isEnabled = onImportPhotoPressed != nil
        typeASCIIToolbarItem?.isEnabled = onTypeASCIIPressed != nil
        deletePhotosToolbarItem?.isEnabled = onDeletePhotosPressed != nil
        screenshotToolbarItem?.isEnabled = onScreenshotPressed != nil
        rebootToolbarItem?.isEnabled = onRebootPressed != nil
        respringToolbarItem?.isEnabled = onRespringPressed != nil
        connectionInfoToolbarItem?.isEnabled = onConnectionInfoPressed != nil

        homeSidebarButton?.isEnabled = guestConnected
        installPackageSidebarButton?.isEnabled =
            installPackageAvailable && onInstallPackagePressed != nil
        importPhotoSidebarButton?.isEnabled = onImportPhotoPressed != nil
        typeASCIISidebarButton?.isEnabled = onTypeASCIIPressed != nil
        deletePhotosSidebarButton?.isEnabled = onDeletePhotosPressed != nil
        screenshotSidebarButton?.isEnabled = onScreenshotPressed != nil
        rebootSidebarButton?.isEnabled = onRebootPressed != nil
        respringSidebarButton?.isEnabled = onRespringPressed != nil
        connectionInfoSidebarButton?.isEnabled = onConnectionInfoPressed != nil
    }

    // MARK: - Actions

    @objc private func homePressed() {
        control?.sendHIDPress(page: 0x0C, usage: 0x40)
    }

    @objc private func installPackagePressed() {
        onInstallPackagePressed?()
    }

    @objc private func importPhotoPressed() {
        onImportPhotoPressed?()
    }

    @objc private func typeASCIIPressed() {
        onTypeASCIIPressed?()
    }

    @objc private func deletePhotosPressed() {
        onDeletePhotosPressed?()
    }

    @objc private func screenshotPressed() {
        onScreenshotPressed?()
    }

    @objc private func rebootPressed() {
        onRebootPressed?()
    }

    @objc private func respringPressed() {
        onRespringPressed?()
    }

    @objc private func connectionInfoPressed() {
        onConnectionInfoPressed?()
    }
}
