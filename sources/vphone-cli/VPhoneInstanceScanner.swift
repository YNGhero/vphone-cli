import Darwin
import Foundation

// MARK: - Instance Scanner

enum VPhoneInstanceScanner {
    static func scan(projectRootURL: URL) -> [VPhoneInstanceRecord] {
        let instancesRoot = projectRootURL.appendingPathComponent("vm.instances", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: instancesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && fm.fileExists(atPath: url.appendingPathComponent("config.plist").path)
            }
            .map { record(vmURL: $0) }
            .sorted {
                let lhsCreated = creationSortTimestamp(for: $0)
                let rhsCreated = creationSortTimestamp(for: $1)
                if lhsCreated != rhsCreated {
                    return lhsCreated < rhsCreated
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private static func record(vmURL: URL) -> VPhoneInstanceRecord {
        let name = readFirstLine(vmURL.appendingPathComponent(".vm_name")) ?? vmURL.lastPathComponent
        let env = readEnv(vmURL.appendingPathComponent("instance.env"))
        let identity = readKeyValueFile(vmURL.appendingPathComponent("udid-prediction.txt"))
        let plist = readPlist(vmURL.appendingPathComponent("config.plist"))
        let variantRaw = clean(
            env["VPHONE_VARIANT"]
                ?? readFirstLine(vmURL.appendingPathComponent(".vphone_variant"))
                ?? "jb"
        )
        let bootPID = readPID(vmURL.appendingPathComponent("logs/boot.pid"))
        let bootPIDAlive = bootPID.map(pidAlive) ?? false
        let diskLocked = isLocked(vmURL.appendingPathComponent("Disk.img"))
            || isLocked(vmURL.appendingPathComponent("SEPStorage"))
            || isLocked(vmURL.appendingPathComponent("nvram.bin"))
        let socketURL = vmURL.appendingPathComponent("vphone.sock")
        let socketExists = FileManager.default.fileExists(atPath: socketURL.path)
        let hasConfig = FileManager.default.fileExists(atPath: vmURL.appendingPathComponent("config.plist").path)
        let status: VPhoneInstanceStatus
        if !hasConfig {
            status = .incomplete
        } else if diskLocked {
            status = .running
        } else if bootPIDAlive {
            status = .starting
        } else {
            status = .stopped
        }

        let networkConfig = plist["networkConfig"] as? [String: Any]
        let memoryBytes = uint64(plist["memorySize"])
        let diskBytes = fileSize(vmURL.appendingPathComponent("Disk.img"))

        return VPhoneInstanceRecord(
            id: vmURL.path,
            name: name,
            vmURL: vmURL,
            status: status,
            variant: variantRaw,
            variantLabel: variantLabel(variantRaw),
            udid: clean(identity["UDID"]).nilIfEmpty,
            ecid: clean(identity["ECID"]).nilIfEmpty,
            sshPort: clean(env["SSH_LOCAL_PORT"] ?? env["VPHONE_SSH_PORT"]).nilIfEmpty,
            vncPort: clean(env["VNC_LOCAL_PORT"] ?? env["VPHONE_VNC_PORT"]).nilIfEmpty,
            rpcPort: clean(env["RPC_LOCAL_PORT"] ?? env["VPHONE_RPC_PORT"]).nilIfEmpty,
            cpuCount: int(plist["cpuCount"]),
            memoryBytes: memoryBytes,
            diskBytes: diskBytes,
            language: clean(env["VPHONE_LANGUAGE"]).nilIfEmpty,
            locale: clean(env["VPHONE_LOCALE"]).nilIfEmpty,
            networkMode: clean(env["NETWORK_MODE"] ?? env["VPHONE_NETWORK_MODE"] ?? networkConfig?["mode"] as? String).nilIfEmpty,
            networkInterface: clean(env["NETWORK_INTERFACE"] ?? env["VPHONE_NETWORK_INTERFACE"] ?? networkConfig?["bridgedInterface"] as? String).nilIfEmpty,
            macAddress: clean(env["VPHONE_MAC_ADDRESS"] ?? env["MAC_ADDRESS"] ?? networkConfig?["macAddress"] as? String).nilIfEmpty,
            proxyURL: clean(env["VPHONE_PROXY_URL"]).nilIfEmpty,
            createdAt: readFirstLine(vmURL.appendingPathComponent(".created_at")),
            bootPID: bootPID,
            socketExists: socketExists
        )
    }

    private static func readEnv(_ url: URL) -> [String: String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = stripShellQuotes(String(parts[1]))
            values[key] = value
        }
        return values
    }

    private static func readKeyValueFile(_ url: URL) -> [String: String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1])
        }
        return values
    }

    private static func readPlist(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any]
        else {
            return [:]
        }
        return plist
    }

    private static func readFirstLine(_ url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return content.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func readPID(_ url: URL) -> Int32? {
        guard let text = readFirstLine(url), let pid = Int32(text) else { return nil }
        return pid
    }

    private static func pidAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func isLocked(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", "--", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return !data.isEmpty
        } catch {
            return false
        }
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else {
            return nil
        }
        return size.uint64Value
    }

    private static func creationSortTimestamp(for record: VPhoneInstanceRecord) -> TimeInterval {
        if let createdAt = record.createdAt,
           let parsed = parseCreatedAt(createdAt)
        {
            return parsed.timeIntervalSince1970
        }

        if let values = try? record.vmURL.resourceValues(forKeys: [.creationDateKey]),
           let creationDate = values.creationDate
        {
            return creationDate.timeIntervalSince1970
        }

        if let values = try? record.vmURL.resourceValues(forKeys: [.contentModificationDateKey]),
           let modificationDate = values.contentModificationDate
        {
            return modificationDate.timeIntervalSince1970
        }

        return 0
    }

    private static func parseCreatedAt(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = localFormatter.date(from: text) {
            return date
        }

        let isoFormatter = ISO8601DateFormatter()
        return isoFormatter.date(from: text)
    }

    private static func stripShellQuotes(_ value: String) -> String {
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

    private static func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? UInt { return UInt64(value) }
        if let value = value as? Int { return value >= 0 ? UInt64(value) : nil }
        if let value = value as? NSNumber { return value.uint64Value }
        if let value = value as? String { return UInt64(value) }
        return nil
    }

    private static func variantLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "regular", "normal":
            return "常规版"
        case "dev", "development":
            return "开发版"
        case "jb", "jailbreak", "trollstore":
            return "越狱版 / TrollStore-JB"
        case "less", "patchless":
            return "Patchless"
        default:
            return value.isEmpty ? "未知" : value
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
