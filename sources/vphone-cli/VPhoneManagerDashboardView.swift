import AppKit
import Darwin
import Foundation
import SwiftUI

// MARK: - Standalone Manager Dashboard

private enum VPhoneManagerPalette {
    // Use fixed RGB colors instead of Color.accentColor / borderedProminent.
    // macOS intentionally de-emphasizes accent-colored controls when a window
    // loses focus; for this dashboard that made the blue action buttons appear
    // to disappear.  Fixed colors keep the management UI readable in inactive
    // windows.
    static let blue = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let bluePressed = Color(red: 0.0, green: 0.36, blue: 0.84)
    static let blueDisabled = Color(red: 0.62, green: 0.70, blue: 0.80)
}

struct VPhoneManagerPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.72))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(isEnabled ? 0.16 : 0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else { return VPhoneManagerPalette.blueDisabled }
        return isPressed ? VPhoneManagerPalette.bluePressed : VPhoneManagerPalette.blue
    }
}

enum VPhoneManagerScope: String, CaseIterable, Identifiable {
    case all
    case running
    case stopped
    case trollstore
    case development
    case issue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部云机"
        case .running: "运行中"
        case .stopped: "已关机"
        case .trollstore: "TrollStore"
        case .development: "开发版"
        case .issue: "异常/不完整"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .running: "play.circle"
        case .stopped: "stop.circle"
        case .trollstore: "shippingbox"
        case .development: "hammer"
        case .issue: "exclamationmark.triangle"
        }
    }

    func matches(_ record: VPhoneInstanceRecord) -> Bool {
        switch self {
        case .all:
            true
        case .running:
            record.status == .running || record.status == .starting
        case .stopped:
            record.status == .stopped
        case .trollstore:
            record.variantLabel.localizedCaseInsensitiveContains("TrollStore")
                || record.variant.localizedCaseInsensitiveContains("jb")
        case .development:
            record.variantLabel.localizedCaseInsensitiveContains("开发")
                || record.variant.localizedCaseInsensitiveContains("dev")
        case .issue:
            record.status == .incomplete
        }
    }
}

struct VPhoneManagerDashboardView: View {
    @Bindable var model: VPhoneInstanceManager

    @State private var scope: VPhoneManagerScope = .all
    @AppStorage("vphoneManagerSlotCount") private var slotCount = 12

    private let columns = [
        GridItem(.adaptive(minimum: 255, maximum: 320), spacing: 14, alignment: .top),
    ]

    private var visibleRecords: [VPhoneInstanceRecord] {
        model.filteredRecords.filter { scope.matches($0) }
    }

    private var emptySlotCount: Int {
        guard scope == .all else { return 0 }
        return max(0, slotCount - visibleRecords.count)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            mainPanel
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refresh() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("vphone")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("本地多开实例控制台")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)

            TextField("搜索实例 / UDID / ECID", text: $model.searchText)
                .textFieldStyle(.roundedBorder)

            VStack(spacing: 6) {
                ForEach(VPhoneManagerScope.allCases) { item in
                    sidebarButton(item)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                statRow("总实例", "\(model.records.count)")
                statRow("运行中", "\(model.records.filter { $0.status == .running || $0.status == .starting }.count)")
                statRow("已关机", "\(model.records.filter { $0.status == .stopped }.count)")
                statRow("选中", "\(model.selection.count)")
            }
            .font(.system(.caption, design: .monospaced))

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("坑位数量")
                    Spacer()
                    Stepper("\(slotCount)", value: $slotCount, in: 4...64)
                        .labelsHidden()
                }

                Button {
                    model.createSlot(defaultName: defaultSlotName(slotNumber: model.records.count + 1))
                } label: {
                    Label("从母盘创建", systemImage: "plus.square.dashed")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(VPhoneManagerPrimaryButtonStyle())
                .controlSize(.small)

                Button {
                    model.arrangeWindows()
                } label: {
                    Label("快速对齐排序", systemImage: "rectangle.3.group")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(VPhoneManagerPrimaryButtonStyle())
                .controlSize(.small)

                Text("默认从 trollstore-clean 克隆。")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(width: 220)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sidebarButton(_ item: VPhoneManagerScope) -> some View {
        Button {
            scope = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.systemImage)
                    .frame(width: 18)
                Text(item.title)
                Spacer()
                Text("\(model.records.filter { item.matches($0) }.count)")
                    .foregroundStyle(.secondary)
            }
            .font(.system(.callout, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(scope == item ? VPhoneManagerPalette.blue.opacity(0.16) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
    }

    // MARK: - Main

    private var mainPanel: some View {
        VStack(spacing: 0) {
            topTabs
            Divider()
            batchToolbar
            Divider()
            cardGrid
            Divider()
            statusBar
        }
    }

    private var topTabs: some View {
        HStack(spacing: 6) {
            ForEach(["主机管理", "云机管理", "镜像管理", "机型管理", "网络管理", "备份管理", "实例管理"], id: \.self) { tab in
                Text(tab)
                    .font(.system(.callout, design: .rounded))
                    .fontWeight(tab == "云机管理" ? .semibold : .regular)
                    .foregroundStyle(tab == "云机管理" ? VPhoneManagerPalette.blue : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(tab == "云机管理" ? VPhoneManagerPalette.blue.opacity(0.12) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task { await model.refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var batchToolbar: some View {
        HStack(spacing: 8) {
            Text(scope.title)
                .font(.system(.headline, design: .rounded))

            Text("\(visibleRecords.count) 台")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Button("全选") {
                model.selectAll(visibleRecords)
            }
            .disabled(visibleRecords.isEmpty)

            Button("取消选择") {
                model.clearSelection()
            }
            .disabled(model.selection.isEmpty)

            Divider().frame(height: 22)

            Button {
                model.launchSelectedRecords()
            } label: {
                Label("批量启动", systemImage: "play.fill")
            }
            .disabled(model.selection.isEmpty)

            Button {
                model.stopSelectedRecords()
            } label: {
                Label("批量停止", systemImage: "stop.fill")
            }
            .disabled(model.selection.isEmpty)

            Button {
                model.installIPASelectedRecords()
            } label: {
                Label("批量安装 IPA", systemImage: "square.and.arrow.down")
            }
            .disabled(model.selection.isEmpty)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var cardGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                    VPhoneInstanceCardView(
                        number: index + 1,
                        record: record,
                        model: model
                    )
                }

                ForEach(0..<emptySlotCount, id: \.self) { index in
                    let slotNumber = visibleRecords.count + index + 1
                    VPhoneEmptySlotCardView(
                        slotNumber: slotNumber,
                        defaultName: defaultSlotName(slotNumber: slotNumber)
                    ) {
                        model.createSlot(defaultName: defaultSlotName(slotNumber: slotNumber))
                    }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isRunningAction {
                ProgressView()
                    .controlSize(.small)
                Text("后台任务运行中（\(model.runningActionCount)）")
                    .foregroundStyle(.secondary)
                Button("清理任务") {
                    model.cancelRunningActions()
                }
                .buttonStyle(VPhoneManagerPrimaryButtonStyle())
                .controlSize(.mini)
            } else if let message = model.lastActionMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("提示：右键实例卡片可安装 IPA、导入图片、清空相册、查看连接信息。")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(model.projectRootURL.path)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func defaultSlotName(slotNumber: Int) -> String {
        "phone-\(String(format: "%02d", slotNumber))"
    }
}

// MARK: - Cards

struct VPhoneInstanceCardView: View {
    let number: Int
    let record: VPhoneInstanceRecord
    @Bindable var model: VPhoneInstanceManager

    private var selectedBinding: Binding<Bool> {
        Binding {
            model.selection.contains(record.id)
        } set: { selected in
            model.setSelected(record, selected: selected)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            preview
            detailRows
            actionRow
        }
        .padding(12)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(model.selection.contains(record.id) ? VPhoneManagerPalette.blue : Color.gray.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contextMenu { contextMenu }
    }

    private var cardBackground: some ShapeStyle {
        model.selection.contains(record.id)
            ? VPhoneManagerPalette.blue.opacity(0.08)
            : Color(nsColor: .windowBackgroundColor)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: selectedBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()

            Text("\(number)")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.gray.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(record.name)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(record.variantLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            StatusBadge(status: record.status)
        }
    }

    private var preview: some View {
        VPhoneInstanceLivePreviewView(record: record, previewGradient: previewGradient)
    }

    private var previewGradient: LinearGradient {
        let base = statusColor(record.status)
        return LinearGradient(
            colors: [
                base.opacity(record.status == .running ? 0.24 : 0.10),
                Color.gray.opacity(0.08),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var detailRows: some View {
        VStack(spacing: 6) {
            infoRow("规格", "\(record.displayCPU)C / \(record.displayMemory) / \(record.displayDisk)")
            infoRow("网络", record.displayNetwork)
            infoRow("UDID", record.udid ?? "-")
            infoRow("ECID", record.ecid ?? "-")
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                model.launch(record)
            } label: {
                Label(record.status == .stopped ? "启动" : "打开", systemImage: "play.fill")
            }
            .buttonStyle(VPhoneManagerPrimaryButtonStyle())

            Button {
                model.stop(record)
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .disabled(record.status == .stopped)

            Button {
                model.installIPA(record)
            } label: {
                Label("安装", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("启动 / 打开 GUI") { model.launch(record) }
        Button("停止实例") { model.stop(record) }
        Divider()
        Button("克隆实例") { model.clone(record) }
        Button("安装 IPA/TIPA") { model.installIPA(record) }
        Button("导入图片到相册") { model.importPhoto(record) }
        Button("清空相册") { model.deletePhotos(record) }
        Button("粘贴输入ASCII") { model.typeClipboardASCII(record) }
        Divider()
        Button("一键重启") { model.reboot(record) }
        Button("Restart SpringBoard") { model.respring(record) }
        Divider()
        Button("连接信息") { model.showConnectionInfo(record) }
        Button("复制 UDID/ECID") { model.copyIdentity(record) }
        Button("打开实例目录") { model.openDirectory(record) }
        Button("打开日志目录") { model.openLogs(record) }
    }
}

struct VPhoneEmptySlotCardView: View {
    let slotNumber: Int
    let defaultName: String
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(slotNumber)")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("空坑位")
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.semibold)
                Spacer()
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                    .foregroundStyle(Color.gray.opacity(0.42))
                    .frame(height: 142)

                VStack(spacing: 8) {
                    Image(systemName: "plus.square.dashed")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(defaultName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                onCreate()
            } label: {
                Label("创建", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VPhoneManagerPrimaryButtonStyle())
            .controlSize(.small)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct StatusBadge: View {
    let status: VPhoneInstanceStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 7, height: 7)
            Text(status.rawValue)
                .font(.system(.caption2, design: .monospaced))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(statusColor(status).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private func statusColor(_ status: VPhoneInstanceStatus) -> Color {
    switch status {
    case .running: .green
    case .starting: .orange
    case .stopped: .secondary
    case .incomplete: .red
    }
}

// MARK: - Live Card Preview

struct VPhoneInstanceLivePreviewView: View {
    let record: VPhoneInstanceRecord
    let previewGradient: LinearGradient

    @State private var image: NSImage?
    @State private var lastError: String?

    private var canPreview: Bool {
        record.status == .running || record.status == .starting
    }

    private var taskID: String {
        "\(record.id)-\(record.status.rawValue)-\(record.socketExists)"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(previewGradient)

            if canPreview, let image {
                liveImage(image)
            } else {
                placeholder
            }
        }
        .frame(height: 142)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(canPreview && image != nil ? 0.14 : 0), lineWidth: 1)
        )
        .task(id: taskID) {
            await previewLoop()
        }
    }

    private func liveImage(_ image: NSImage) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.88)

            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFit()
                .padding(.vertical, 6)
                .padding(.horizontal, 38)

            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("实时预览 · 只读")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.86))
                Spacer()
                Text(record.sshPort.map { "SSH \($0)" } ?? "SSH -")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.70))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.45))
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: record.status == .running ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(record.status == .running ? Color.green : Color.secondary)
            Text(record.status.rawValue)
                .font(.system(.headline, design: .rounded))
            Text(placeholderSubtitle)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
    }

    private var placeholderSubtitle: String {
        if canPreview {
            if let lastError {
                return lastError
            }
            return record.socketExists ? "等待实时画面..." : "打开 GUI 后显示实时画面"
        }
        return record.displayPorts
    }

    @MainActor
    private func previewLoop() async {
        image = nil
        lastError = nil
        guard canPreview else { return }

        while !Task.isCancelled {
            if let data = await VPhoneManagerPreviewClient.captureJPEGData(vmURL: record.vmURL),
               let nextImage = NSImage(data: data)
            {
                image = nextImage
                lastError = nil
            } else if image == nil {
                lastError = record.socketExists ? "暂时无法获取画面" : "打开 GUI 后显示实时画面"
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

private enum VPhoneManagerPreviewClient {
    static func captureJPEGData(vmURL: URL) async -> Data? {
        let socketPath = vmURL.appendingPathComponent("vphone.sock").path
        return await Task.detached(priority: .utility) {
            captureJPEGDataSync(socketPath: socketPath)
        }.value
    }

    private static func captureJPEGDataSync(socketPath: String) -> Data? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }

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
        guard connected == 0 else { return nil }

        let request = #"{"t":"screenshot","screen":false}"# + "\n"
        guard writeAll(fd: fd, data: Data(request.utf8)) else { return nil }
        guard let line = readLine(fd: fd, maxBytes: 1_500_000),
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (json["ok"] as? Bool) == true,
              let base64 = json["image"] as? String,
              let imageData = Data(base64Encoded: base64)
        else {
            return nil
        }

        return imageData
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
        var buffer = [UInt8](repeating: 0, count: 8192)

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
