import SwiftUI

// MARK: - Instance Manager View

struct VPhoneInstanceListView: View {
    @Bindable var model: VPhoneInstanceManager

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            if model.isRefreshing, model.records.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredRecords.isEmpty {
                ContentUnavailableView(
                    "没有实例",
                    systemImage: "iphone.slash",
                    description: Text("未在 vm.instances/ 下找到 config.plist，或当前搜索没有匹配结果。")
                )
            } else {
                instanceTable
            }
            Divider()
            detailBar
        }
        .searchable(text: $model.searchText, prompt: "搜索实例名 / UDID / ECID / 路径")
        .task { await model.refresh() }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)

            Divider().frame(height: 22)

            Button {
                model.launchSelected()
            } label: {
                Label("启动 GUI", systemImage: "play.fill")
            }
            .disabled(model.selectedRecord?.canLaunchGUI != true)

            Button {
                model.stopSelected()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .disabled(model.selectedRecord?.canStop != true)

            Button {
                model.cloneSelected()
            } label: {
                Label("克隆", systemImage: "plus.square.on.square")
            }
            .disabled(model.selectedRecord?.canClone != true)

            Button(role: .destructive) {
                model.deleteSelectedRecords()
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(model.selectedDeletableRecords.isEmpty)

            Button {
                model.installIPASelected()
            } label: {
                Label("安装 IPA", systemImage: "square.and.arrow.down")
            }
            .disabled(model.selectedRecord?.canInstallPackage != true)

            Spacer()

            Button {
                model.showSelectedConnectionInfo()
            } label: {
                Label("连接信息", systemImage: "info.circle")
            }
            .disabled(model.selectedRecord == nil)

            Button {
                model.copySelectedIdentity()
            } label: {
                Label("复制身份", systemImage: "doc.on.doc")
            }
            .disabled(model.selectedRecord == nil)

            Button {
                model.openSelectedLogs()
            } label: {
                Label("日志", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(model.selectedRecord == nil)

            Button {
                model.openSelectedDirectory()
            } label: {
                Label("目录", systemImage: "folder")
            }
            .disabled(model.selectedRecord == nil)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Table

    private var instanceTable: some View {
        Table(model.filteredRecords, selection: $model.selection) {
            TableColumn("实例") { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(record.vmURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            TableColumn("状态") { record in
                statusBadge(record.status)
            }
            .width(90)

            TableColumn("变体") { record in
                Text(record.variantLabel)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 150)

            TableColumn("规格") { record in
                Text("\(record.displayCPU)C / \(record.displayMemory) / \(record.displayDisk)")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }
            .width(min: 130, ideal: 150)

            TableColumn("端口") { record in
                Text(record.displayPorts)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }
            .width(min: 180, ideal: 230)

            TableColumn("UDID / ECID") { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.udid ?? "-")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Text(record.ecid ?? "-")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 220, ideal: 270)

            TableColumn("语言 / 网络") { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(record.displayLanguage) / \(record.displayLocale)")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Text(record.displayNetwork)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 130, ideal: 160)
        }
        .contextMenu(forSelectionType: VPhoneInstanceRecord.ID.self) { _ in
            Button("启动 GUI") { model.launchSelected() }
                .disabled(model.selectedRecord?.canLaunchGUI != true)
            Button("停止") { model.stopSelected() }
                .disabled(model.selectedRecord?.canStop != true)
            Button("克隆") { model.cloneSelected() }
                .disabled(model.selectedRecord?.canClone != true)
            Button("删除实例", role: .destructive) { model.deleteSelectedRecords() }
                .disabled(model.selectedDeletableRecords.isEmpty)
            Button("安装 IPA/TIPA") { model.installIPASelected() }
                .disabled(model.selectedRecord?.canInstallPackage != true)
            Divider()
            Button("备份 App") { model.appBackupSelected() }
                .disabled(model.selectedRecord?.canUseSSHActions != true)
            Button("一键新机") { model.appNewDeviceSelected() }
                .disabled(model.selectedRecord?.canUseSSHActions != true)
            Button("还原 App") { model.appRestoreSelected() }
                .disabled(model.selectedRecord?.canUseSSHActions != true)
            Button("按 IP 定位") { model.setLocationByIPSelected() }
                .disabled(model.selectedRecord?.canUseHostControlActions != true)
            Divider()
            Button("连接信息") { model.showSelectedConnectionInfo() }
            Button("复制 UDID/ECID") { model.copySelectedIdentity() }
            Button("打开实例目录") { model.openSelectedDirectory() }
            Button("打开日志目录") { model.openSelectedLogs() }
        }
    }

    private func statusBadge(_ status: VPhoneInstanceStatus) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 7, height: 7)
            Text(status.rawValue)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(statusColor(status).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func statusColor(_ status: VPhoneInstanceStatus) -> Color {
        switch status {
        case .running: .green
        case .starting: .orange
        case .stopped: .secondary
        case .incomplete: .red
        }
    }

    // MARK: - Detail Bar

    private var detailBar: some View {
        HStack(spacing: 10) {
            if let selected = model.selectedRecord {
                Text(selected.name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                Text(selected.vmURL.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("选择一个实例后可启动、停止、克隆、安装 IPA 或查看连接信息。")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isRunningAction {
                ProgressView()
                    .controlSize(.small)
                Text("任务运行中")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if let msg = model.lastActionMessage {
                Text(msg)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
