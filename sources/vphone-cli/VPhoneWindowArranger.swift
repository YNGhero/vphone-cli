import AppKit
import Darwin
import Foundation

// MARK: - Multi-Instance Window Arrangement

struct VPhoneWindowArrangeResult {
    let targetCount: Int
    let successCount: Int
}

enum VPhoneWindowArranger {
    static let compactWindowSize = NSSize(width: 275, height: 550)
    private static let tileGap: CGFloat = 8

    @MainActor
    static func arrangeRunningInstanceWindows(projectRootURL: URL) async -> VPhoneWindowArrangeResult {
        let screenFrame = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let records = await Task.detached(priority: .userInitiated) {
            VPhoneInstanceScanner.scan(projectRootURL: projectRootURL)
        }.value

        let targets = records.filter { record in
            (record.status == .running || record.status == .starting)
                && record.socketExists
        }
        guard !targets.isEmpty else {
            return VPhoneWindowArrangeResult(targetCount: 0, successCount: 0)
        }

        let frames = compactFrames(count: targets.count, in: screenFrame)
        let requests = zip(targets, frames).compactMap { record, frame in
            makeRequest(socketPath: record.vmURL.appendingPathComponent("vphone.sock").path, frame: frame)
        }

        let successCount = await Task.detached(priority: .userInitiated) {
            var count = 0
            for request in requests {
                if VPhoneWindowArrangeSocketClient.send(request) {
                    count += 1
                }
            }
            return count
        }.value

        return VPhoneWindowArrangeResult(targetCount: targets.count, successCount: successCount)
    }

    private static func compactFrames(count: Int, in visibleFrame: NSRect) -> [NSRect] {
        let size = compactWindowSize
        let columns = max(1, Int((visibleFrame.width + tileGap) / (size.width + tileGap)))
        let rows = max(1, Int((visibleFrame.height + tileGap) / (size.height + tileGap)))
        let pageSize = max(1, columns * rows)

        return (0..<count).map { index in
            let page = index / pageSize
            let pageIndex = index % pageSize
            let column = pageIndex % columns
            let row = pageIndex / columns
            let pageOffset = CGFloat(page) * 18

            let x = visibleFrame.minX
                + CGFloat(column) * (size.width + tileGap)
                + pageOffset
            let y = max(
                visibleFrame.minY,
                visibleFrame.maxY
                    - size.height
                    - CGFloat(row) * (size.height + tileGap)
                    - pageOffset
            )

            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
    }

    private static func makeRequest(socketPath: String, frame: NSRect) -> VPhoneWindowArrangeRequest? {
        let payload: [String: Any] = [
            "t": "arrange_window",
            "x": Double(frame.minX),
            "y": Double(frame.minY),
            "w": Double(frame.width),
            "h": Double(frame.height),
            "screen": false,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }
        data.append(contentsOf: [0x0A])
        return VPhoneWindowArrangeRequest(socketPath: socketPath, data: data)
    }
}

private struct VPhoneWindowArrangeRequest: Sendable {
    let socketPath: String
    let data: Data
}

private enum VPhoneWindowArrangeSocketClient {
    static func send(_ request: VPhoneWindowArrangeRequest) -> Bool {
        guard FileManager.default.fileExists(atPath: request.socketPath) else { return false }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(request.socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }

        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (index, byte) in pathBytes.enumerated() {
                    dst[index] = byte
                }
            }
        }

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        guard writeAll(fd: fd, data: request.data) else { return false }

        guard let response = readLine(fd: fd, maxBytes: 64 * 1024),
              let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
        else {
            return false
        }
        return (json["ok"] as? Bool) == true
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    private static func readLine(fd: Int32, maxBytes: Int) -> Data? {
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while accumulated.count < maxBytes {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count <= 0 { break }

            if let newlineIndex = buffer[..<count].firstIndex(of: 0x0A) {
                accumulated.append(buffer, count: newlineIndex)
                return accumulated
            }

            accumulated.append(buffer, count: count)
        }

        return accumulated.isEmpty ? nil : accumulated
    }
}
