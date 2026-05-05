import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Instance Menu

extension VPhoneMenuController {
    func buildInstanceMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: VPhoneMenuText.Instance.menu)
        menu.autoenablesItems = false

        let manager = makeItem(VPhoneMenuText.Instance.manager, action: #selector(openInstanceManager))
        instanceManagerItem = manager
        menu.addItem(manager)

        menu.addItem(NSMenuItem.separator())

        let install = makeItem(
            VPhoneMenuText.Instance.installPackage, action: #selector(installIPAFromDisk)
        )
        install.isEnabled = false
        instanceInstallPackageItem = install
        menu.addItem(install)

        let importPhoto = makeItem(
            VPhoneMenuText.Instance.importPhoto, action: #selector(importPhotoToAlbum)
        )
        instanceImportPhotoItem = importPhoto
        menu.addItem(importPhoto)

        let deletePhotos = makeItem(
            VPhoneMenuText.Instance.deletePhotos, action: #selector(deleteAllPhotosFromAlbum)
        )
        instanceDeletePhotosItem = deletePhotos
        menu.addItem(deletePhotos)

        menu.addItem(NSMenuItem.separator())

        let reboot = makeItem(VPhoneMenuText.Instance.reboot, action: #selector(rebootGuest))
        instanceRebootItem = reboot
        menu.addItem(reboot)

        let respring = makeItem(VPhoneMenuText.Instance.respring, action: #selector(respringGuest))
        instanceRespringItem = respring
        menu.addItem(respring)

        menu.addItem(NSMenuItem.separator())

        let connectionInfo = makeItem(
            VPhoneMenuText.Instance.showConnectionInfo, action: #selector(showConnectionInfo)
        )
        instanceConnectionInfoItem = connectionInfo
        menu.addItem(connectionInfo)

        let copyIdentity = makeItem(
            VPhoneMenuText.Instance.copyIdentity, action: #selector(copyIdentity)
        )
        instanceCopyIdentityItem = copyIdentity
        menu.addItem(copyIdentity)

        menu.addItem(NSMenuItem.separator())

        let openDir = makeItem(
            VPhoneMenuText.Instance.openInstanceDirectory, action: #selector(openInstanceDirectory)
        )
        instanceOpenDirectoryItem = openDir
        menu.addItem(openDir)

        let openLogs = makeItem(
            VPhoneMenuText.Instance.openLogDirectory, action: #selector(openLogDirectory)
        )
        instanceOpenLogsItem = openLogs
        menu.addItem(openLogs)

        item.submenu = menu
        return item
    }

    @objc func openInstanceManager() {
        onInstanceManagerPressed?()
    }

    @objc func importPhotoToAlbum() {
        guard let port = sshLocalPort() else {
            showAlert(
                title: "导入图片到相册",
                message: "没有找到 SSH 本地端口。请先启动实例并确认 connection_info.txt 已生成。",
                style: .warning
            )
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie]
        panel.prompt = "导入"
        panel.message = "选择要导入到 guest「照片」App 的图片或视频。"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        launchProjectScript(
            relativePath: "scripts/import_photo_to_instance.sh",
            arguments: [url.path, port, "VPhoneImports"],
            title: "导入图片到相册"
        )
    }

    @objc func deleteAllPhotosFromAlbum() {
        guard let port = sshLocalPort() else {
            showAlert(
                title: "清空相册",
                message: "没有找到 SSH 本地端口。请先启动实例并确认 connection_info.txt 已生成。",
                style: .warning
            )
            return
        }

        guard confirmDestructive(
            title: "清空相册",
            message: "将删除 guest「照片」App 里的所有照片/视频资产，并清理 DCIM、缩略图和缓存。继续？",
            confirmTitle: "清空"
        ) else {
            return
        }

        launchProjectScript(
            relativePath: "scripts/delete_all_photos_from_instance.sh",
            arguments: [port, "--yes"],
            title: "清空相册"
        )
    }

    @objc func rebootGuest() {
        guard let port = sshLocalPort() else {
            showAlert(
                title: "一键重启",
                message: "没有找到 SSH 本地端口。请先启动实例并确认 connection_info.txt 已生成。",
                style: .warning
            )
            return
        }

        guard confirmDestructive(
            title: "一键重启",
            message: "将通过 SSH 在 guest 内执行 reboot。GUI 可能会短暂断开，继续？",
            confirmTitle: "重启"
        ) else {
            return
        }

        launchHostCommand(
            executable: "/usr/bin/env",
            arguments: [
                "sshpass", "-p", "alpine",
                "ssh",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "PreferredAuthentications=password",
                "-p", port,
                "root@127.0.0.1",
                "(/sbin/reboot || reboot || /var/jb/usr/bin/killall backboardd) >/dev/null 2>&1 &",
            ],
            title: "一键重启"
        )
    }

    @objc func respringGuest() {
        guard let port = sshLocalPort() else {
            showAlert(
                title: "Restart SpringBoard",
                message: "没有找到 SSH 本地端口。请先启动实例并确认 connection_info.txt 已生成。",
                style: .warning
            )
            return
        }

        launchHostCommand(
            executable: "/usr/bin/env",
            arguments: [
                "sshpass", "-p", "alpine",
                "ssh",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "PreferredAuthentications=password",
                "-p", port,
                "root@127.0.0.1",
                """
                PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin:/iosbinpack64/usr/bin:/iosbinpack64/bin:$PATH; \
                (killall SpringBoard || launchctl kickstart -k system/com.apple.SpringBoard || killall backboardd) >/dev/null 2>&1 &
                """,
            ],
            title: "Restart SpringBoard"
        )
    }

    @objc func showConnectionInfo() {
        showTextPanel(title: "连接信息", message: connectionInfoText())
    }

    @objc func copyIdentity() {
        let text = identityText()
        guard !text.isEmpty else {
            showAlert(title: "复制 UDID/ECID", message: "没有找到 UDID/ECID 信息。", style: .warning)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showAlert(title: "复制 UDID/ECID", message: "已复制到剪贴板。", style: .informational)
    }

    @objc func openInstanceDirectory() {
        guard let vmDirectoryURL else {
            showAlert(title: "打开实例目录", message: "当前实例目录未知。", style: .warning)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([vmDirectoryURL])
    }

    @objc func openLogDirectory() {
        guard let logsURL = logsDirectoryURL(create: true) else {
            showAlert(title: "打开日志目录", message: "当前日志目录未知。", style: .warning)
            return
        }
        NSWorkspace.shared.open(logsURL)
    }

    // MARK: - Instance Helpers

    private func identityText() -> String {
        var lines: [String] = []
        if let udidFile = vmDirectoryURL?.appendingPathComponent("udid-prediction.txt"),
           let content = try? String(contentsOf: udidFile, encoding: .utf8) {
            lines.append(content.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let ecidHex = vm?.ecidHex {
            lines.append("ECID=0x\(ecidHex)")
        }

        if let instanceName = instanceEnvValue("INSTANCE_NAME"), !instanceName.isEmpty {
            lines.insert("INSTANCE_NAME=\(instanceName)", at: 0)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func connectionInfoText() -> String {
        var sections: [String] = []
        if let infoURL = vmDirectoryURL?.appendingPathComponent("connection_info.txt"),
           let content = try? String(contentsOf: infoURL, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(content.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            var generated: [String] = []
            generated.append("Instance: \(instanceEnvValue("INSTANCE_NAME") ?? vmDirectoryURL?.lastPathComponent ?? "unknown")")
            if let vmDirectoryURL {
                generated.append("VM_DIR: \(vmDirectoryURL.path)")
                generated.append("Host control socket: \(vmDirectoryURL.appendingPathComponent("vphone.sock").path)")
            }
            if let port = sshLocalPort() {
                generated.append("SSH: sshpass -p alpine ssh -tt -p \(port) root@127.0.0.1")
            }
            if let vnc = instanceEnvValue("VNC_LOCAL_PORT"), !vnc.isEmpty {
                generated.append("VNC: vnc://127.0.0.1:\(vnc)")
            }
            if let rpc = instanceEnvValue("RPC_LOCAL_PORT"), !rpc.isEmpty {
                generated.append("RPC: 127.0.0.1:\(rpc)")
            }
            sections.append(generated.joined(separator: "\n"))
        }

        let identity = identityText()
        if !identity.isEmpty {
            sections.append("Identity:\n\(identity)")
        }
        return sections.joined(separator: "\n\n")
    }

    private func sshLocalPort() -> String? {
        if let value = instanceEnvValue("SSH_LOCAL_PORT"), isNumeric(value) {
            return value
        }

        guard let infoURL = vmDirectoryURL?.appendingPathComponent("connection_info.txt"),
              let content = try? String(contentsOf: infoURL, encoding: .utf8) else {
            return nil
        }

        var found: String?
        for part in content.components(separatedBy: "-p ").dropFirst() {
            guard let token = part.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first
            else { continue }
            let candidate = String(token)
            if isNumeric(candidate) {
                found = candidate
            }
        }
        return found
    }

    private func instanceEnvValue(_ key: String) -> String? {
        guard let envURL = vmDirectoryURL?.appendingPathComponent("instance.env"),
              let content = try? String(contentsOf: envURL, encoding: .utf8) else {
            return nil
        }

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("\(key)=") else { continue }
            let value = String(line.dropFirst(key.count + 1))
            return stripShellQuotes(value)
        }
        return nil
    }

    private func stripShellQuotes(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (text.hasPrefix("\"") && text.hasSuffix("\""))
            || (text.hasPrefix("'") && text.hasSuffix("'"))
        {
            text.removeFirst()
            text.removeLast()
        }
        return text
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\'", with: "'")
    }

    private func isNumeric(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    private func logsDirectoryURL(create: Bool) -> URL? {
        guard let vmDirectoryURL else { return nil }
        let logsURL = vmDirectoryURL.appendingPathComponent("logs", isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(
                at: logsURL, withIntermediateDirectories: true
            )
        }
        return logsURL
    }

    private func projectScriptURL(relativePath: String) -> URL? {
        guard let projectRootURL else { return nil }
        return projectRootURL.appendingPathComponent(relativePath)
    }

    private func launchProjectScript(relativePath: String, arguments: [String], title: String) {
        guard let scriptURL = projectScriptURL(relativePath: relativePath) else {
            showAlert(title: title, message: "项目根目录未知，无法运行脚本。", style: .warning)
            return
        }
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            showAlert(title: title, message: "脚本不存在：\(scriptURL.path)", style: .warning)
            return
        }
        launchHostCommand(
            executable: "/bin/zsh",
            arguments: [scriptURL.path] + arguments,
            title: title
        )
    }

    private func launchHostCommand(executable: String, arguments: [String], title: String) {
        guard let logURL = guiActionLogURL() else {
            showAlert(title: title, message: "无法创建 GUI 动作日志。", style: .warning)
            return
        }

        do {
            let logHandle = try openLogHandle(logURL: logURL)
            writeLogHeader(logHandle, title: title, executable: executable, arguments: arguments)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = projectRootURL
            process.environment = processEnvironment()
            process.standardOutput = logHandle
            process.standardError = logHandle
            try process.run()

            showAlert(
                title: title,
                message: "任务已启动。日志：\(logURL.path)",
                style: .informational
            )
        } catch {
            showAlert(title: title, message: "\(error)", style: .warning)
        }
    }

    private func guiActionLogURL() -> URL? {
        guard let logsURL = logsDirectoryURL(create: true) else { return nil }
        return logsURL.appendingPathComponent("gui-actions.log")
    }

    private func openLogHandle(logURL: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        return handle
    }

    private func writeLogHeader(
        _ handle: FileHandle, title: String, executable: String, arguments: [String]
    ) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let command = ([executable] + arguments).map { shellQuote($0) }.joined(separator: " ")
        let header = "\n=== \(stamp) \(title) ===\n$ \(command)\n"
        if let data = header.data(using: .utf8) {
            handle.write(data)
        }
    }

    private func shellQuote(_ value: String) -> String {
        if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "'\"")))
            == nil {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let projectPath = projectRootURL?.path ?? FileManager.default.currentDirectoryPath
        env["PATH"] = [
            "\(projectPath)/.tools/shims",
            "\(projectPath)/.tools/bin",
            "\(projectPath)/.venv/bin",
            "\(home)/Library/Python/3.9/bin",
            "\(home)/Library/Python/3.14/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ].joined(separator: ":")
        return env
    }

    private func confirmDestructive(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showTextPanel(title: String, message: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.center()

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 58, width: 600, height: 342))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = message
        scroll.documentView = textView

        let copy = NSButton(frame: NSRect(x: 420, y: 18, width: 90, height: 28))
        copy.title = "复制"
        copy.bezelStyle = .rounded

        let ok = NSButton(frame: NSRect(x: 520, y: 18, width: 90, height: 28))
        ok.title = "关闭"
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.target = NSApp
        ok.action = #selector(NSApplication.stopModal(withCode:))

        class CopyHelper: NSObject {
            let text: String
            init(text: String) { self.text = text }
            @MainActor @objc func copyAndClose() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 100))
            }
        }
        let helper = CopyHelper(text: message)
        copy.target = helper
        copy.action = #selector(CopyHelper.copyAndClose)

        panel.contentView?.addSubview(scroll)
        panel.contentView?.addSubview(copy)
        panel.contentView?.addSubview(ok)

        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        if response.rawValue == 100 {
            showAlert(title: title, message: "已复制到剪贴板。", style: .informational)
        }
    }
}
