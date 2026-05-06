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

        menu.addItem(NSMenuItem.separator())

        let appBackup = makeItem(VPhoneMenuText.Instance.appBackup, action: #selector(backupAppState))
        instanceAppBackupItem = appBackup
        menu.addItem(appBackup)

        let appNewDevice = makeItem(
            VPhoneMenuText.Instance.appNewDevice, action: #selector(newDeviceAppState)
        )
        instanceAppNewDeviceItem = appNewDevice
        menu.addItem(appNewDevice)

        let appRestore = makeItem(VPhoneMenuText.Instance.appRestore, action: #selector(restoreAppState))
        instanceAppRestoreItem = appRestore
        menu.addItem(appRestore)

        menu.addItem(NSMenuItem.separator())

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

        let setProxy = makeItem(VPhoneMenuText.Instance.setProxy, action: #selector(setInstanceProxy))
        instanceSetProxyItem = setProxy
        menu.addItem(setProxy)

        let clearProxy = makeItem(VPhoneMenuText.Instance.clearProxy, action: #selector(clearInstanceProxy))
        instanceClearProxyItem = clearProxy
        menu.addItem(clearProxy)

        let testProxy = makeItem(VPhoneMenuText.Instance.testProxy, action: #selector(testInstanceProxy))
        instanceTestProxyItem = testProxy
        menu.addItem(testProxy)

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

    @objc func backupAppState() {
        guard let port = sshLocalPort() else {
            showAlert(
                title: "备份 App",
                message: "没有找到 SSH 本地端口。请先启动实例并确认 connection_info.txt 已生成。",
                style: .warning
            )
            return
        }

        guard let options = promptAppBackupOptions() else { return }
        rememberAppBundleID(options.bundleID)

        let instanceName = instanceEnvValue("INSTANCE_NAME")
            ?? vmDirectoryURL?.lastPathComponent
            ?? "instance"

        launchProjectScript(
            relativePath: "scripts/app_backup.sh",
            arguments: [
                port,
                options.bundleID,
                options.backupName,
                "--instance-name",
                instanceName,
            ],
            title: "备份 App"
        )
    }

    @objc func newDeviceAppState() {
        guard let port = sshLocalPort() else {
            showAlert(
                title: "一键新机",
                message: "没有找到 SSH 本地端口。请先启动实例并确认 connection_info.txt 已生成。",
                style: .warning
            )
            return
        }

        guard let bundleID = promptAppBundleID(
            title: "一键新机",
            message: "输入要执行一键新机的 App Bundle ID。",
            confirmTitle: "继续"
        ) else { return }
        rememberAppBundleID(bundleID)

        guard confirmDestructive(
            title: "一键新机",
            message: "将清理 \(bundleID) 的 App Data、App Group、Preferences 和 Keychain，并生成新的设备 profile。建议先执行“备份 App”。继续？",
            confirmTitle: "新机"
        ) else {
            return
        }

        launchProjectScript(
            relativePath: "scripts/app_new_device.sh",
            arguments: [port, bundleID, "--yes"],
            title: "一键新机"
        )
    }

    @objc func restoreAppState() {
        guard let port = sshLocalPort() else {
            showAlert(
                title: "还原 App",
                message: "没有找到 SSH 本地端口。请先启动实例并确认 connection_info.txt 已生成。",
                style: .warning
            )
            return
        }

        guard let bundleID = promptAppBundleID(
            title: "还原 App",
            message: "输入要还原的 App Bundle ID。",
            confirmTitle: "选择备份"
        ) else { return }
        rememberAppBundleID(bundleID)

        guard let archive = chooseAppBackupArchive(bundleID: bundleID) else { return }

        guard confirmDestructive(
            title: "还原 App",
            message: "将用备份还原 \(bundleID)，当前 App 数据会先被清理。\n\n备份：\(archive.lastPathComponent)",
            confirmTitle: "还原"
        ) else {
            return
        }

        launchProjectScript(
            relativePath: "scripts/app_restore.sh",
            arguments: [port, bundleID, archive.path, "--yes"],
            title: "还原 App"
        )
    }

    @objc func setLocationByIP() {
        guard let vmDirectoryURL else {
            showAlert(title: "按 IP 定位", message: "当前实例目录未知。", style: .warning)
            return
        }

        guard FileManager.default.fileExists(
            atPath: vmDirectoryURL.appendingPathComponent("vphone.sock").path
        ) else {
            showAlert(
                title: "按 IP 定位",
                message: "当前实例的 GUI/control socket 未就绪。请先等待 vphone.sock ready。",
                style: .warning
            )
            return
        }

        guard let ip = promptLocationTargetIP(
            title: "按 IP 定位",
            message: "输入要查询定位的目标 IP。脚本会调用 ipapi.co 并把经纬度应用到当前实例。",
            confirmTitle: "定位"
        ) else { return }
        rememberLocationTargetIP(ip)

        launchProjectScript(
            relativePath: "scripts/set_location_by_ip.sh",
            arguments: [vmDirectoryURL.path, ip],
            title: "按 IP 定位"
        )
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

    @objc func setInstanceProxy() {
        guard sshLocalPort() != nil else {
            showAlert(
                title: "设置实例代理",
                message: "没有找到 SSH 本地端口。请先启动实例并确认 connection_info.txt 已生成。",
                style: .warning
            )
            return
        }
        guard let vmDirectoryURL else {
            showAlert(title: "设置实例代理", message: "当前实例目录未知。", style: .warning)
            return
        }
        guard let proxyURL = promptProxyURL() else { return }
        rememberProxyURL(proxyURL)

        launchProjectScript(
            relativePath: "scripts/set_instance_proxy.sh",
            arguments: [vmDirectoryURL.path, proxyURL, "--test"],
            title: "设置实例代理"
        )
    }

    @objc func clearInstanceProxy() {
        guard sshLocalPort() != nil else {
            showAlert(
                title: "清除实例代理",
                message: "没有找到 SSH 本地端口。请先启动实例并确认 connection_info.txt 已生成。",
                style: .warning
            )
            return
        }
        guard let vmDirectoryURL else {
            showAlert(title: "清除实例代理", message: "当前实例目录未知。", style: .warning)
            return
        }
        guard confirmDestructive(
            title: "清除实例代理",
            message: "将清除当前实例的 guest SystemConfiguration HTTP/SOCKS 代理配置。继续？",
            confirmTitle: "清除"
        ) else { return }

        launchProjectScript(
            relativePath: "scripts/set_instance_proxy.sh",
            arguments: [vmDirectoryURL.path, "clear", "--yes"],
            title: "清除实例代理"
        )
    }

    @objc func testInstanceProxy() {
        guard sshLocalPort() != nil else {
            showAlert(
                title: "测试出口 IP",
                message: "没有找到 SSH 本地端口。请先启动实例并确认 connection_info.txt 已生成。",
                style: .warning
            )
            return
        }
        guard let vmDirectoryURL else {
            showAlert(title: "测试出口 IP", message: "当前实例目录未知。", style: .warning)
            return
        }

        launchProjectScript(
            relativePath: "scripts/set_instance_proxy.sh",
            arguments: [vmDirectoryURL.path, "test"],
            title: "测试出口 IP"
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
            if let proxy = instanceEnvValue("VPHONE_PROXY_URL"), !proxy.isEmpty {
                generated.append("Proxy: \(proxy)")
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

    private func defaultAppBundleID() -> String {
        UserDefaults.standard.string(forKey: "VPhoneLastAppStateBundleID") ?? "com.burbn.instagram"
    }

    private func rememberAppBundleID(_ bundleID: String) {
        UserDefaults.standard.set(bundleID, forKey: "VPhoneLastAppStateBundleID")
    }

    private func defaultLocationTargetIP() -> String {
        UserDefaults.standard.string(forKey: "VPhoneLastLocationTargetIP") ?? "8.8.8.8"
    }

    private func rememberLocationTargetIP(_ ip: String) {
        UserDefaults.standard.set(ip, forKey: "VPhoneLastLocationTargetIP")
    }

    private func defaultProxyURL() -> String {
        if let current = instanceEnvValue("VPHONE_PROXY_URL"), !current.isEmpty {
            return current
        }
        return UserDefaults.standard.string(forKey: "VPhoneLastProxyURL") ?? "socks5://127.0.0.1:1080"
    }

    private func rememberProxyURL(_ proxyURL: String) {
        UserDefaults.standard.set(proxyURL, forKey: "VPhoneLastProxyURL")
    }

    private func promptAppBundleID(
        title: String,
        message: String,
        confirmTitle: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")

        let field = NSTextField(string: defaultAppBundleID())
        field.placeholderString = "例如 com.burbn.instagram"
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let bundleID = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return nil }
        return bundleID
    }

    private func promptAppBackupOptions() -> (bundleID: String, backupName: String)? {
        let alert = NSAlert()
        alert.messageText = "备份 App"
        alert.informativeText = "输入要备份的 App Bundle ID 和备份名称。"
        alert.addButton(withTitle: "备份")
        alert.addButton(withTitle: "取消")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        // 4 arranged subviews + 3 spacings need more than 76pt; otherwise
        // AppKit compresses the text fields and their text becomes invisible.
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 118)

        let bundleField = NSTextField(string: defaultAppBundleID())
        bundleField.placeholderString = "例如 com.burbn.instagram"
        let nameField = NSTextField(string: "manual")
        nameField.placeholderString = "例如 before-login / clean-state"
        bundleField.widthAnchor.constraint(equalToConstant: 420).isActive = true
        bundleField.heightAnchor.constraint(equalToConstant: 26).isActive = true
        nameField.widthAnchor.constraint(equalToConstant: 420).isActive = true
        nameField.heightAnchor.constraint(equalToConstant: 26).isActive = true

        stack.addArrangedSubview(NSTextField(labelWithString: "Bundle ID"))
        stack.addArrangedSubview(bundleField)
        stack.addArrangedSubview(NSTextField(labelWithString: "备份名称"))
        stack.addArrangedSubview(nameField)
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let bundleID = bundleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let backupName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return nil }
        return (bundleID, backupName.isEmpty ? "manual" : backupName)
    }

    private func promptLocationTargetIP(
        title: String,
        message: String,
        confirmTitle: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")

        let field = NSTextField(string: defaultLocationTargetIP())
        field.placeholderString = "例如 8.8.8.8"
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 26)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let ip = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { return nil }
        return ip
    }

    private func promptProxyURL() -> String? {
        let alert = NSAlert()
        alert.messageText = "设置实例代理"
        alert.informativeText = "输入当前实例要使用的 HTTP/SOCKS5 代理 URL。该配置写入 guest SystemConfiguration，适用于遵循系统代理的 App。"
        alert.addButton(withTitle: "设置并测试")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(string: defaultProxyURL())
        field.placeholderString = "例如 socks5://user:pass@1.2.3.4:1080"
        field.frame = NSRect(x: 0, y: 0, width: 460, height: 26)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let proxyURL = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proxyURL.isEmpty else { return nil }
        return proxyURL
    }

    private func chooseAppBackupArchive(bundleID: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = []
        for ext in ["gz", "tgz", "tar"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        panel.prompt = "还原"
        panel.message = "选择要还原的 \(bundleID) 备份包。"

        if let projectRootURL {
            let backupDir = projectRootURL
                .appendingPathComponent("app_backups", isDirectory: true)
                .appendingPathComponent(bundleID, isDirectory: true)
            if FileManager.default.fileExists(atPath: backupDir.path) {
                panel.directoryURL = backupDir
            }
        }

        return panel.runModal() == .OK ? panel.url : nil
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
