import AppKit
import Darwin
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - Instance Manager Model

@MainActor
@Observable
final class VPhoneInstanceManager {
    let projectRootURL: URL
    let instancesRootURL: URL

    var records: [VPhoneInstanceRecord] = []
    var selection = Set<VPhoneInstanceRecord.ID>()
    var searchText = ""
    var isRefreshing = false
    var lastActionMessage: String?
    var error: String?
    var runningActionCount = 0

    @ObservationIgnored private var runningProcesses: [UUID: Process] = [:]
    @ObservationIgnored private var runningLogHandles: [UUID: FileHandle] = [:]

    init(projectRootURL: URL) {
        self.projectRootURL = projectRootURL
        self.instancesRootURL = projectRootURL.appendingPathComponent("vm.instances", isDirectory: true)
    }

    var filteredRecords: [VPhoneInstanceRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return records }
        return records.filter { record in
            record.name.lowercased().contains(query)
                || record.vmURL.path.lowercased().contains(query)
                || (record.udid?.lowercased().contains(query) ?? false)
                || (record.ecid?.lowercased().contains(query) ?? false)
        }
    }

    var selectedRecord: VPhoneInstanceRecord? {
        guard let id = selection.first else { return nil }
        return records.first { $0.id == id }
    }

    var selectedRecords: [VPhoneInstanceRecord] {
        records.filter { selection.contains($0.id) }
    }

    var isRunningAction: Bool {
        runningActionCount > 0
    }

    func refresh() async {
        isRefreshing = true
        let root = projectRootURL
        let scanned = await Task.detached(priority: .userInitiated) {
            VPhoneInstanceScanner.scan(projectRootURL: root)
        }.value
        records = scanned
        selection = selection.filter { id in scanned.contains { $0.id == id } }
        isRefreshing = false
    }

    func launchSelected() {
        guard let record = selectedRecord else { return }
        launch(record)
    }

    func launchSelectedRecords() {
        let targets = selectedRecords
        guard !targets.isEmpty else { return }
        for record in targets {
            launch(record)
        }
    }

    func stopSelected() {
        guard let record = selectedRecord else { return }
        stop(record)
    }

    func stopSelectedRecords() {
        let targets = selectedRecords
        guard !targets.isEmpty else { return }
        guard confirm(
            title: "批量停止实例",
            message: "将停止 \(targets.count) 个实例的 guest、GUI 进程和本地 SSH/VNC/RPC 转发。继续？",
            confirmTitle: "停止"
        ) else { return }

        for record in targets {
            stop(record, confirmFirst: false)
        }
    }

    func cloneSelected() {
        guard let record = selectedRecord else { return }
        clone(record)
    }

    func installIPASelected() {
        guard let record = selectedRecord else { return }
        installIPA(record)
    }

    func installIPASelectedRecords() {
        let targets = selectedRecords
        guard !targets.isEmpty else { return }
        guard let url = chooseInstallPackage(message: "选择要安装到 \(targets.count) 个实例的 IPA/TIPA。") else {
            return
        }
        for record in targets {
            installIPA(record, packageURL: url)
        }
    }

    func openSelectedDirectory() {
        guard let record = selectedRecord else { return }
        openDirectory(record)
    }

    func openSelectedLogs() {
        guard let record = selectedRecord else { return }
        openLogs(record)
    }

    func showSelectedConnectionInfo() {
        guard let record = selectedRecord else { return }
        showConnectionInfo(record)
    }

    func copySelectedIdentity() {
        guard let record = selectedRecord else { return }
        copyIdentity(record)
    }

    func selectAll(_ records: [VPhoneInstanceRecord]) {
        selection = Set(records.map(\.id))
    }

    func clearSelection() {
        selection.removeAll()
    }

    func cancelRunningActions() {
        let processes = runningProcesses
        guard !processes.isEmpty else {
            lastActionMessage = "没有需要清理的后台任务。"
            return
        }

        for process in processes.values where process.isRunning {
            process.terminate()
        }

        lastActionMessage = "正在清理 \(processes.count) 个后台任务..."

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for process in processes.values where process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }

            for token in processes.keys {
                runningProcesses.removeValue(forKey: token)
                if let handle = runningLogHandles.removeValue(forKey: token) {
                    try? handle.close()
                }
            }
            runningActionCount = runningProcesses.count
            lastActionMessage = "已清理卡住的后台任务。"
            await refresh()
        }
    }

    func setSelected(_ record: VPhoneInstanceRecord, selected: Bool) {
        if selected {
            selection.insert(record.id)
        } else {
            selection.remove(record.id)
        }
    }

    func createSlot(defaultName: String) {
        guard let source = cleanBaseRecord() else {
            showAlert(
                title: "创建实例",
                message: "未找到干净母盘 trollstore-clean。请先准备一个已关机的母盘实例，或在左侧选择现有实例执行“克隆”。",
                style: .warning
            )
            return
        }

        guard source.status == .stopped else {
            showAlert(
                title: "创建实例",
                message: "母盘必须先关机：\(source.name)",
                style: .warning
            )
            return
        }

        let proposedName = nextAvailableInstanceName(preferred: defaultName)
        guard let name = promptText(
            title: "从母盘创建实例",
            message: "将从 \(source.name) 克隆一个新实例。克隆体会清空 machineIdentifier，首次启动后生成新的 ECID/UDID。",
            defaultValue: proposedName,
            confirmTitle: "创建"
        ) else {
            return
        }

        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalName.isEmpty else { return }
        clone(source, nameOrPrefix: finalName, count: 1)
    }

    // MARK: - Record Actions

    func launch(_ record: VPhoneInstanceRecord) {
        runProjectScript(
            relativePath: "scripts/launch_vphone_instance.sh",
            arguments: [record.vmURL.path],
            environment: [
                // Manager-launched scripts are already headless from AppKit; keep this explicit.
                "VPHONE_LAUNCH_CLOSE_TERMINAL": "0",
            ],
            title: "启动 GUI",
            record: record
        )
    }

    func stop(_ record: VPhoneInstanceRecord, confirmFirst: Bool = true) {
        if confirmFirst {
            guard confirm(
                title: "停止实例",
                message: "将停止 \(record.name) 的 guest、GUI 进程和本地 SSH/VNC/RPC 转发。继续？",
                confirmTitle: "停止"
            ) else { return }
        }

        runProjectScript(
            relativePath: "scripts/stop_vphone_instance.sh",
            arguments: [record.vmURL.path],
            environment: [:],
            title: "停止实例",
            record: record
        )
    }

    func clone(_ record: VPhoneInstanceRecord) {
        guard record.status == .stopped else {
            showAlert(
                title: "克隆实例",
                message: "来源实例必须先关机：\(record.name)",
                style: .warning
            )
            return
        }

        let result = promptCloneOptions(defaultPrefix: "\(record.name)-clone")
        guard let result else { return }
        clone(record, nameOrPrefix: result.nameOrPrefix, count: result.count)
    }

    func installIPA(_ record: VPhoneInstanceRecord) {
        guard let url = chooseInstallPackage(message: "选择要安装到 \(record.name) 的 IPA/TIPA。") else {
            return
        }
        installIPA(record, packageURL: url)
    }

    func importPhoto(_ record: VPhoneInstanceRecord) {
        guard let port = record.sshPort else {
            showAlert(
                title: "导入图片到相册",
                message: "\(record.name) 没有 SSH 本地端口。请先启动实例并等待 SSH ready。",
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
        panel.message = "选择要导入到 \(record.name)「照片」App 的图片或视频。"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        runProjectScript(
            relativePath: "scripts/import_photo_to_instance.sh",
            arguments: [url.path, port, "VPhoneImports"],
            environment: [:],
            title: "导入图片到相册",
            record: record
        )
    }

    func deletePhotos(_ record: VPhoneInstanceRecord) {
        guard let port = record.sshPort else {
            showAlert(
                title: "清空相册",
                message: "\(record.name) 没有 SSH 本地端口。请先启动实例并等待 SSH ready。",
                style: .warning
            )
            return
        }

        guard confirm(
            title: "清空相册",
            message: "将删除 \(record.name)「照片」App 里的所有照片/视频资产，并清理 DCIM、缩略图和缓存。继续？",
            confirmTitle: "清空"
        ) else {
            return
        }

        runProjectScript(
            relativePath: "scripts/delete_all_photos_from_instance.sh",
            arguments: [port, "--yes"],
            environment: [:],
            title: "清空相册",
            record: record
        )
    }

    func typeClipboardASCII(_ record: VPhoneInstanceRecord) {
        runProjectScript(
            relativePath: "scripts/type_clipboard_ascii_to_instance.sh",
            arguments: [record.vmURL.path],
            environment: [:],
            title: "粘贴输入ASCII",
            record: record
        )
    }

    func reboot(_ record: VPhoneInstanceRecord) {
        guard let port = record.sshPort else {
            showAlert(
                title: "一键重启",
                message: "\(record.name) 没有 SSH 本地端口。请先启动实例并等待 SSH ready。",
                style: .warning
            )
            return
        }

        guard confirm(
            title: "一键重启",
            message: "将通过 SSH 在 guest 内执行 reboot。GUI 可能会短暂断开，继续？",
            confirmTitle: "重启"
        ) else {
            return
        }

        runHostCommand(
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
            title: "一键重启",
            record: record
        )
    }

    func respring(_ record: VPhoneInstanceRecord) {
        guard let port = record.sshPort else {
            showAlert(
                title: "Restart SpringBoard",
                message: "\(record.name) 没有 SSH 本地端口。请先启动实例并等待 SSH ready。",
                style: .warning
            )
            return
        }

        runHostCommand(
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
            title: "Restart SpringBoard",
            record: record
        )
    }

    func openDirectory(_ record: VPhoneInstanceRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.vmURL])
    }

    func openLogs(_ record: VPhoneInstanceRecord) {
        try? FileManager.default.createDirectory(
            at: record.logsURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(record.logsURL)
    }

    func showConnectionInfo(_ record: VPhoneInstanceRecord) {
        showTextPanel(title: "连接信息 — \(record.name)", message: record.connectionInfoText)
    }

    func copyIdentity(_ record: VPhoneInstanceRecord) {
        var lines: [String] = ["INSTANCE_NAME=\(record.name)"]
        if let udid = record.udid { lines.append("UDID=\(udid)") }
        if let ecid = record.ecid { lines.append("ECID=\(ecid)") }
        lines.append("VM_DIR=\(record.vmURL.path)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        lastActionMessage = "已复制 \(record.name) 的身份信息。"
    }

    // MARK: - Actions
    private func clone(_ record: VPhoneInstanceRecord, nameOrPrefix: String, count: Int) {
        var env = [
            "VPHONE_INTERACTIVE_CONFIG": "0",
            "VPHONE_AUTO_LAUNCH_CLONED": "0",
            "VPHONE_CLONE_COUNT": "\(count)",
        ]
        if !nameOrPrefix.isEmpty {
            env["VPHONE_CLONE_NAME"] = nameOrPrefix
        }

        var args = [record.vmURL.path]
        if !nameOrPrefix.isEmpty {
            args.append(nameOrPrefix)
        }

        runProjectScript(
            relativePath: "scripts/clone_vphone_instance.sh",
            arguments: args,
            environment: env,
            title: "克隆实例",
            record: record
        )
    }

    private func installIPA(_ record: VPhoneInstanceRecord, packageURL url: URL) {
        runProjectScript(
            relativePath: "scripts/install_ipa_to_instance.sh",
            arguments: [url.path, record.vmURL.path],
            environment: [
                "VPHONE_LAUNCH_CLOSE_TERMINAL": "0",
            ],
            title: "安装 IPA/TIPA",
            record: record
        )
    }

    private func chooseInstallPackage(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = []
        if let ipa = UTType(filenameExtension: "ipa") { types.append(ipa) }
        if let tipa = UTType(filenameExtension: "tipa") { types.append(tipa) }
        panel.allowedContentTypes = types
        panel.prompt = "安装"
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Process

    private func runProjectScript(
        relativePath: String,
        arguments: [String],
        environment extraEnvironment: [String: String],
        title: String,
        record: VPhoneInstanceRecord
    ) {
        let scriptURL = projectRootURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            showAlert(title: title, message: "脚本不存在：\(scriptURL.path)", style: .warning)
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: record.logsURL,
                withIntermediateDirectories: true
            )
            let logHandle = try openLogHandle(logURL: record.managerLogURL)
            writeLogHeader(
                logHandle,
                title: title,
                executable: "/bin/zsh",
                arguments: [scriptURL.path] + arguments
            )

            let process = Process()
            let token = UUID()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path] + arguments
            process.currentDirectoryURL = projectRootURL
            process.environment = processEnvironment(extraEnvironment)
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard let self else { return }
                    let status = process.terminationStatus
                    self.runningProcesses.removeValue(forKey: token)
                    if let handle = self.runningLogHandles.removeValue(forKey: token) {
                        try? handle.close()
                    }
                    self.runningActionCount = self.runningProcesses.count
                    if status == 0 {
                        self.lastActionMessage = "\(title) 完成：\(record.name)。日志：\(record.managerLogURL.path)"
                    } else {
                        self.lastActionMessage = "\(title) 失败：\(record.name)，exit=\(status)。日志：\(record.managerLogURL.path)"
                    }
                    await self.refresh()
                }
            }

            try process.run()
            runningProcesses[token] = process
            runningLogHandles[token] = logHandle
            runningActionCount = runningProcesses.count
            lastActionMessage = "\(title) 已启动：\(record.name)。日志：\(record.managerLogURL.path)"
        } catch {
            showAlert(title: title, message: "\(error)", style: .warning)
        }
    }

    private func runHostCommand(
        executable: String,
        arguments: [String],
        environment extraEnvironment: [String: String] = [:],
        title: String,
        record: VPhoneInstanceRecord
    ) {
        do {
            try FileManager.default.createDirectory(
                at: record.logsURL,
                withIntermediateDirectories: true
            )
            let logHandle = try openLogHandle(logURL: record.managerLogURL)
            writeLogHeader(
                logHandle,
                title: title,
                executable: executable,
                arguments: arguments
            )

            let process = Process()
            let token = UUID()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = projectRootURL
            process.environment = processEnvironment(extraEnvironment)
            process.standardOutput = logHandle
            process.standardError = logHandle
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard let self else { return }
                    let status = process.terminationStatus
                    self.runningProcesses.removeValue(forKey: token)
                    if let handle = self.runningLogHandles.removeValue(forKey: token) {
                        try? handle.close()
                    }
                    self.runningActionCount = self.runningProcesses.count
                    if status == 0 {
                        self.lastActionMessage = "\(title) 完成：\(record.name)。日志：\(record.managerLogURL.path)"
                    } else {
                        self.lastActionMessage = "\(title) 失败：\(record.name)，exit=\(status)。日志：\(record.managerLogURL.path)"
                    }
                    await self.refresh()
                }
            }

            try process.run()
            runningProcesses[token] = process
            runningLogHandles[token] = logHandle
            runningActionCount = runningProcesses.count
            lastActionMessage = "\(title) 已启动：\(record.name)。日志：\(record.managerLogURL.path)"
        } catch {
            showAlert(title: title, message: "\(error)", style: .warning)
        }
    }

    private func processEnvironment(_ extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        env["PATH"] = [
            "\(projectRootURL.path)/.tools/shims",
            "\(projectRootURL.path)/.tools/bin",
            "\(projectRootURL.path)/.venv/bin",
            "\(home)/Library/Python/3.9/bin",
            "\(home)/Library/Python/3.14/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ].joined(separator: ":")
        for (key, value) in extra {
            env[key] = value
        }
        return env
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
        _ handle: FileHandle,
        title: String,
        executable: String,
        arguments: [String]
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

    // MARK: - Instance Helpers

    private func cleanBaseRecord() -> VPhoneInstanceRecord? {
        if let clean = records.first(where: { $0.name == "trollstore-clean" }) {
            return clean
        }
        return records.first { record in
            record.status == .stopped
                && record.variantLabel.contains("TrollStore")
                && record.name.localizedCaseInsensitiveContains("clean")
        }
    }

    private func nextAvailableInstanceName(preferred: String) -> String {
        let safePreferred = sanitizeInstanceName(preferred).isEmpty
            ? "phone-01"
            : sanitizeInstanceName(preferred)
        if !FileManager.default.fileExists(atPath: instancesRootURL.appendingPathComponent(safePreferred).path) {
            return safePreferred
        }

        var index = 2
        while true {
            let candidate = "\(safePreferred)-\(String(format: "%02d", index))"
            if !FileManager.default.fileExists(atPath: instancesRootURL.appendingPathComponent(candidate).path) {
                return candidate
            }
            index += 1
        }
    }

    private func sanitizeInstanceName(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        var result = ""
        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("-")
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    // MARK: - Panels

    private func promptText(
        title: String,
        message: String,
        defaultValue: String,
        confirmTitle: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")

        let field = NSTextField(string: defaultValue)
        field.placeholderString = "实例名，例如 phone-01"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func promptCloneOptions(defaultPrefix: String) -> (nameOrPrefix: String, count: Int)? {
        let alert = NSAlert()
        alert.messageText = "克隆实例"
        alert.informativeText = "来源实例必须已关机。克隆体会清空 machineIdentifier，首次启动后生成新的 ECID/UDID。"
        alert.addButton(withTitle: "克隆")
        alert.addButton(withTitle: "取消")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 72)

        let nameField = NSTextField(string: defaultPrefix)
        nameField.placeholderString = "新实例名/前缀，留空自动"
        let countField = NSTextField(string: "1")
        countField.placeholderString = "克隆数量"

        stack.addArrangedSubview(NSTextField(labelWithString: "新实例名/前缀"))
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(NSTextField(labelWithString: "克隆数量"))
        stack.addArrangedSubview(countField)
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = max(1, Int(countField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1)
        return (name, count)
    }

    private func confirm(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
        error = style == .warning ? message : nil
    }

    private func showTextPanel(title: String, message: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.center()

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 58, width: 680, height: 362))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = message
        scroll.documentView = textView

        let copy = NSButton(frame: NSRect(x: 500, y: 18, width: 90, height: 28))
        copy.title = "复制"
        copy.bezelStyle = .rounded

        let ok = NSButton(frame: NSRect(x: 610, y: 18, width: 90, height: 28))
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
            lastActionMessage = "连接信息已复制到剪贴板。"
        }
    }
}
