import ArgumentParser
import Foundation

struct SetupToolsCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup-tools",
        abstract: "Install required host tools without shell wrappers"
    )

    @Option(help: "Project root path", transform: URL.init(fileURLWithPath:))
    var projectRoot: URL = VPhoneHost.currentDirectoryURL()

    mutating func run() async throws {
        let projectRoot = projectRoot.standardizedFileURL
        let toolsPrefix = resolveToolsPrefix(projectRoot: projectRoot)

        try requireCommand("brew")

        try await installBrewPackages([
            "gnu-tar",
            "openssl@3",
            "ldid-procursus",
            "sshpass",
            "git-lfs",
        ])

        try await installTrustcache(toolsPrefix: toolsPrefix)
        try await installInsertDylib(toolsPrefix: toolsPrefix)

        print("")
        print("Tools installed in \(toolsPrefix.path)")
    }

    func resolveToolsPrefix(projectRoot: URL) -> URL {
        if let override = ProcessInfo.processInfo.environment["TOOLS_PREFIX"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return projectRoot.appendingPathComponent(".tools", isDirectory: true)
    }

    func requireCommand(_ command: String) throws {
        let result = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/\(command)")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/\(command)")
            || which(command) != nil
        if !result {
            throw ValidationError("Missing required command: \(command)")
        }
    }

    func which(_ command: String) -> String? {
        ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent(command).path }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    func installBrewPackages(_ packages: [String]) async throws {
        print("[1/3] Checking Homebrew packages...")
        var missing: [String] = []

        for package in packages {
            let result = try await VPhoneHost.runCommand("brew", arguments: ["list", package])
            if !result.terminationStatus.isSuccess {
                missing.append(package)
            }
        }

        if missing.isEmpty {
            print("  All brew packages installed")
            return
        }

        print("  Installing: \(missing.joined(separator: ", "))")
        _ = try await VPhoneHost.runCommand("brew", arguments: ["install"] + missing, requireSuccess: true)
    }

    func installTrustcache(toolsPrefix: URL) async throws {
        let trustcacheBinary = toolsPrefix.appendingPathComponent("bin/trustcache")
        print("[2/3] trustcache")
        if FileManager.default.isExecutableFile(atPath: trustcacheBinary.path) {
            print("  Already built: \(trustcacheBinary.path)")
            return
        }

        let buildRoot = try VPhoneHost.tempDirectory(prefix: "vphone-trustcache")
        defer { try? FileManager.default.removeItem(at: buildRoot) }

        let sourceURL = buildRoot.appendingPathComponent("trustcache", isDirectory: true)
        _ = try await VPhoneHost.runCommand(
            "git",
            arguments: ["clone", "--depth", "1", "https://github.com/CRKatri/trustcache.git", sourceURL.path],
            requireSuccess: true
        )

        let opensslPrefix = VPhoneHost.stringValue(
            try await VPhoneHost.runCommand("brew", arguments: ["--prefix", "openssl@3"], requireSuccess: true)
        )
        let cpuCount = VPhoneHost.stringValue(
            try await VPhoneHost.runCommand("sysctl", arguments: ["-n", "hw.logicalcpu"], requireSuccess: true)
        )

        _ = try await VPhoneHost.runCommand(
            "make",
            arguments: [
                "-C", sourceURL.path,
                "OPENSSL=1",
                "CFLAGS=-I\(opensslPrefix)/include -DOPENSSL -w",
                "LDFLAGS=-L\(opensslPrefix)/lib",
                "-j\(cpuCount)",
            ],
            requireSuccess: true
        )

        try FileManager.default.createDirectory(at: toolsPrefix.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: trustcacheBinary.path) {
            try FileManager.default.removeItem(at: trustcacheBinary)
        }
        try FileManager.default.copyItem(at: sourceURL.appendingPathComponent("trustcache"), to: trustcacheBinary)
        print("  Installed: \(trustcacheBinary.path)")
    }

    func installInsertDylib(toolsPrefix: URL) async throws {
        let insertDylibBinary = toolsPrefix.appendingPathComponent("bin/insert_dylib")
        print("[3/3] insert_dylib")
        if FileManager.default.isExecutableFile(atPath: insertDylibBinary.path) {
            print("  Already built: \(insertDylibBinary.path)")
            return
        }

        let sourceURL = toolsPrefix.appendingPathComponent("src/insert_dylib", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: sourceURL.appendingPathComponent(".git").path) {
            _ = try await VPhoneHost.runCommand("git", arguments: ["-C", sourceURL.path, "fetch", "--depth", "1", "origin"], requireSuccess: true)
            _ = try await VPhoneHost.runCommand("git", arguments: ["-C", sourceURL.path, "reset", "--hard", "FETCH_HEAD"], requireSuccess: true)
            _ = try await VPhoneHost.runCommand("git", arguments: ["-C", sourceURL.path, "clean", "-fdx"], requireSuccess: true)
        } else {
            _ = try await VPhoneHost.runCommand(
                "git",
                arguments: ["clone", "--depth", "1", "https://github.com/tyilo/insert_dylib", sourceURL.path],
                requireSuccess: true
            )
        }

        try FileManager.default.createDirectory(at: toolsPrefix.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        _ = try await VPhoneHost.runCommand(
            "clang",
            arguments: [
                "-o", insertDylibBinary.path,
                sourceURL.appendingPathComponent("insert_dylib/main.c").path,
                "-framework", "Security",
                "-O2",
            ],
            requireSuccess: true
        )
        print("  Installed: \(insertDylibBinary.path)")
    }
}
