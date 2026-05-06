import Foundation

// MARK: - Instance Records

enum VPhoneInstanceStatus: String, CaseIterable, Hashable {
    case running = "运行中"
    case starting = "启动中"
    case stopped = "已关机"
    case incomplete = "不完整"

    var sortRank: Int {
        switch self {
        case .running: 0
        case .starting: 1
        case .stopped: 2
        case .incomplete: 3
        }
    }
}

struct VPhoneInstanceRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let vmURL: URL
    let status: VPhoneInstanceStatus
    let variant: String
    let variantLabel: String
    let udid: String?
    let ecid: String?
    let sshPort: String?
    let vncPort: String?
    let rpcPort: String?
    let cpuCount: Int?
    let memoryBytes: UInt64?
    let diskBytes: UInt64?
    let language: String?
    let locale: String?
    let networkMode: String?
    let networkInterface: String?
    let createdAt: String?
    let bootPID: Int32?
    let socketExists: Bool

    var logsURL: URL {
        vmURL.appendingPathComponent("logs", isDirectory: true)
    }

    var bootLogURL: URL {
        logsURL.appendingPathComponent("boot.log")
    }

    var managerLogURL: URL {
        logsURL.appendingPathComponent("manager-actions.log")
    }

    var connectionInfoURL: URL {
        vmURL.appendingPathComponent("connection_info.txt")
    }

    var canLaunchGUI: Bool {
        status == .stopped || status == .running
    }

    var canStop: Bool {
        status == .running || status == .starting
    }

    var canClone: Bool {
        status == .stopped
    }

    var canDelete: Bool {
        status == .stopped || status == .incomplete
    }

    var canInstallPackage: Bool {
        status != .incomplete
    }

    var canUseSSHActions: Bool {
        status == .running && sshPort != nil
    }

    var canUseHostControlActions: Bool {
        status == .running && socketExists
    }

    var displayLanguage: String {
        let lang = clean(language)
        return lang.isEmpty ? "default" : lang
    }

    var displayLocale: String {
        let loc = clean(locale)
        return loc.isEmpty ? "auto/default" : loc
    }

    var displayNetwork: String {
        let mode = clean(networkMode).isEmpty ? "nat" : clean(networkMode)
        let iface = clean(networkInterface)
        return iface.isEmpty ? mode : "\(mode) (\(iface))"
    }

    var displayCPU: String {
        cpuCount.map(String.init) ?? "-"
    }

    var displayMemory: String {
        guard let memoryBytes else { return "-" }
        return Self.formatBytes(memoryBytes, unit: "GB")
    }

    var displayDisk: String {
        guard let diskBytes else { return "-" }
        return Self.formatBytes(diskBytes, unit: "GB")
    }

    var displayPorts: String {
        let ssh = sshPort.map { "SSH \($0)" } ?? "SSH -"
        let vnc = vncPort.map { "VNC \($0)" } ?? "VNC -"
        let rpc = rpcPort.map { "RPC \($0)" } ?? "RPC -"
        return "\(ssh) · \(vnc) · \(rpc)"
    }

    var connectionInfoText: String {
        if let content = try? String(contentsOf: connectionInfoURL, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var lines: [String] = []
        lines.append("Instance: \(name)")
        lines.append("VM_DIR: \(vmURL.path)")
        if let udid { lines.append("UDID: \(udid)") }
        if let ecid { lines.append("ECID: \(ecid)") }
        lines.append("")
        lines.append("Native GUI/control socket:")
        lines.append("  \(vmURL.appendingPathComponent("vphone.sock").path)")
        lines.append("")
        lines.append("SSH:")
        if let sshPort {
            lines.append("  sshpass -p alpine ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p \(sshPort) root@127.0.0.1")
        } else {
            lines.append("  -")
        }
        lines.append("")
        lines.append("VNC:")
        lines.append(vncPort.map { "  vnc://127.0.0.1:\($0)" } ?? "  -")
        lines.append("")
        lines.append("RPC:")
        lines.append(rpcPort.map { "  127.0.0.1:\($0)" } ?? "  -")
        lines.append("")
        lines.append("Logs:")
        lines.append("  \(bootLogURL.path)")
        lines.append("")
        lines.append("Guest configuration:")
        lines.append("  Variant: \(variantLabel)")
        lines.append("  Language: \(displayLanguage)")
        lines.append("  Locale: \(displayLocale)")
        lines.append("  Network: \(displayNetwork)")
        return lines.joined(separator: "\n")
    }

    private func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func formatBytes(_ bytes: UInt64, unit: String) -> String {
        switch unit {
        case "GB":
            let gb = Double(bytes) / 1024 / 1024 / 1024
            if abs(gb.rounded() - gb) < 0.05 {
                return "\(Int(gb.rounded()))GB"
            }
            return String(format: "%.1fGB", gb)
        default:
            return "\(bytes)"
        }
    }
}
