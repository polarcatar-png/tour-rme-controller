import AppKit
import SwiftUI
import TourMixCore

/// 连接健康度、OSC 端口配置、权限引导与实时串口/OSC 报文诊断视图。
@MainActor
public struct DiagnosticsView: View {
    private let engine: CoordinatorEngine
    private let launchManager: LaunchAtLoginManager

    @State private var hostDraft: String = "127.0.0.1"
    @State private var outgoingPortDraft: String = "7001"
    @State private var incomingPortDraft: String = "9001"
    @State private var portValidationMessage: String?
    @State private var xmlSnapshot: TotalMixConfigDiagnostic?
    @State private var isAccessibilityTrusted: Bool = false
    @State private var copiedResetCommand: Bool = false

    public init(
        engine: CoordinatorEngine,
        launchManager: LaunchAtLoginManager
    ) {
        self.engine = engine
        self.launchManager = launchManager
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                connectionAndOSCConfigSection
                installAndPermissionsSection
                liveMonitorsSection
            }
            .padding(18)
        }
        .onAppear {
            syncDraftsFromEngine()
            refreshSnapshotAndPermissions()
        }
    }

    // MARK: - 1. Dual-End Connection Health & OSC Port Config

    private var connectionAndOSCConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "双端连接健康度与 Global OSC 端口配置",
                icon: "point.3.connected.trianglepath.dotted"
            )

            HStack(alignment: .top, spacing: 12) {
                // 左卡：TourBox Lite 串口状态
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(tourBoxColor)
                            .frame(width: 9, height: 9)
                        Text("TourBox Lite 硬件串口")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("立即重连") {
                            engine.reconnectTourBoxNow()
                        }
                        .controlSize(.small)
                    }

                    Text(engine.tourBoxState.displayText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if let port = engine.tourBoxState.port {
                        Text("设备节点：\(port)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("匹配 VID:PID = 0xCAFE:0x4001 (115200 8N1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

                // 右卡：TotalMix FX Global OSC 状态
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(engine.totalMix.isConnected ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text("TotalMix FX Global OSC")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(engine.totalMix.isConnected ? "实时在线" : "等待响应")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(engine.totalMix.isConnected ? .green : .orange)
                    }

                    Text("设备型号：\(engine.totalMix.detectedDeviceName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Text("Control Room Main Out：\(engine.totalMix.mainOutDisplayName)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let dsp = engine.totalMix.dspLoad {
                            Text(String(format: "DSP: %.1f%%", dsp))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }

            // 若本地 UDP 接收端口冲突（如 9001 被 TouchOSC / Companion 占用），醒目红字警告并提供一键切换
            if case .portInUse(let busyPort, let message) = engine.totalMix.transportState {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UDP 监听端口 \(busyPort) 被占用")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary.opacity(0.9))
                    }
                    Spacer()
                    Button("一键改用 7002 / 9002") {
                        hostDraft = "127.0.0.1"
                        outgoingPortDraft = "7002"
                        incomingPortDraft = "9002"
                        applyOSCPortChanges()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            }

            // OSC 端点编辑表单
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TotalMix 地址 (Host)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("127.0.0.1", text: $hostDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 140)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("发送端口 (TotalMix Incoming)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("7001", text: $outgoingPortDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 150)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("接收端口 (TotalMix Outgoing)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("9001", text: $incomingPortDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 150)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(" ")
                        .font(.system(size: 11))
                    HStack(spacing: 6) {
                        Button("保存并重连") {
                            applyOSCPortChanges()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("默认 7001/9001") {
                            hostDraft = "127.0.0.1"
                            outgoingPortDraft = "7001"
                            incomingPortDraft = "9001"
                            applyOSCPortChanges()
                        }
                        .controlSize(.small)
                    }
                }

                Spacer()
            }

            if let portValidationMessage {
                Text(portValidationMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }

            // 离线 XML 配置快照明细
            if let snapshot = engine.totalMix.offlineDiagnostic ?? xmlSnapshot {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("TotalMix 磁盘 XML 快照辅助自检（注：TotalMix 默认退出时才写盘，实时状态以 UDP 为准）")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("重新读取 XML") {
                            refreshSnapshotAndPermissions()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }

                    if let fileURL = snapshot.xmlFileURL {
                        Text("快照文件：\(fileURL.lastPathComponent) · Enable OSC=\(snapshot.oscMasterEnabled ? "ON" : "OFF") · 模式=\(snapshot.matchedRemote?.compatibility.displayName ?? "N/A") · 快照 MainOut=\(snapshot.mainChannelDisplayName ?? "N/A")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if !engine.totalMix.isConnected {
                        Text(snapshot.offlineHintSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 2. App Installation & Accessibility Permissions

    private var installAndPermissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "应用安装路径、开机自启与 macOS 辅助功能权限",
                icon: "checkmark.shield"
            )

            HStack(alignment: .top, spacing: 12) {
                // 左卡：安装路径与 LaunchAgent 自启
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("运行位置与开机自启")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Toggle(
                            "登录时自动启动",
                            isOn: Binding(
                                get: { launchManager.isEnabled },
                                set: { launchManager.setEnabled($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    Text("当前路径：\(launchManager.currentBundlePath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Label(
                            launchManager.isRunningFromApplications ? "已从 /Applications 运行" : "当前未从 /Applications 运行",
                            systemImage: launchManager.isRunningFromApplications ? "checkmark.circle.fill" : "info.circle"
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(launchManager.isRunningFromApplications ? .green : .orange)

                        Spacer()

                        if !launchManager.isRunningFromApplications {
                            Button("一键安装至 /Applications") {
                                _ = launchManager.installToApplications(relaunch: false)
                            }
                            .controlSize(.small)
                        }
                    }

                    if let err = launchManager.lastError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

                // 右卡：辅助功能权限（仅键盘快捷键合成需要）
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("辅助功能权限 (Accessibility)")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(isAccessibilityTrusted ? "已授权" : "未授权（纯 RME 控制无需此权限）")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isAccessibilityTrusted ? .green : .secondary)
                    }

                    Text("控制 RME 音量/静音/监听室及系统媒体键完全无需任何隐私权限；仅当您为按键绑定「自定义电脑键盘快捷键」时才需开启。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button("请求授权 / 打开设置") {
                            _ = engine.actionExecutor.isAccessibilityTrusted(prompt: true)
                            engine.actionExecutor.openAccessibilitySettings()
                            refreshSnapshotAndPermissions()
                        }
                        .controlSize(.small)

                        Button("刷新状态") {
                            refreshSnapshotAndPermissions()
                        }
                        .controlSize(.small)

                        Button(copiedResetCommand ? "已复制重置命令 ✓" : "复制权限重置命令") {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString("tccutil reset Accessibility com.soundlab.TourMix", forType: .string)
                            copiedResetCommand = true
                        }
                        .controlSize(.small)
                        .help("若重新编译覆盖应用后快捷键偶发失效，可在终端运行 tccutil reset Accessibility com.soundlab.TourMix 后重新勾选")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 3 & 4. Live Serial Byte Stream & OSC Packet Monitors

    private var liveMonitorsSection: some View {
        HStack(alignment: .top, spacing: 14) {
            // 实时串口字节监视器
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionHeader(title: "TourBox 实时串口字节流", icon: "cable.connector.horizontal")
                    Spacer()
                    Text("\(engine.serialDiagnostics.count) 条")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        let items = Array(engine.serialDiagnostics.suffix(80).reversed())
                        if items.isEmpty {
                            Text("暂无串口报文（转动旋钮或按下任意键即可实时观测原始 Hex 字节）")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(8)
                        } else {
                            ForEach(items) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(entry.direction)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(entry.direction == "IN" ? .cyan : .orange)
                                        .frame(width: 34, alignment: .leading)
                                    Text(entry.hex)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.primary)
                                    Text(entry.note)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(height: 220)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            // 实时 OSC 报文监视器
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionHeader(title: "TotalMix OSC 实时报文流", icon: "waveform.path.ecg")
                    Spacer()
                    Button("/sendstate") {
                        engine.totalMix.requestStateHeartbeat()
                    }
                    .controlSize(.mini)
                    Button("/sendall 2") {
                        engine.totalMix.requestFullSync()
                    }
                    .controlSize(.mini)
                }

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        let items = Array(engine.totalMix.recentDiagnostics.suffix(80).reversed())
                        if items.isEmpty {
                            Text("暂无 OSC 报文")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(8)
                        } else {
                            ForEach(items) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(item.direction)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(oscDirectionColor(item.direction))
                                        .frame(width: 48, alignment: .leading)
                                    Text(item.summary)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.primary.opacity(0.92))
                                        .lineLimit(1)
                                }
                                .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(height: 220)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Actions & Helpers

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.cyan)
            Text(title)
                .font(.system(size: 13.5, weight: .bold))
        }
    }

    private func syncDraftsFromEngine() {
        hostDraft = engine.configuration.oscHost
        outgoingPortDraft = String(engine.configuration.oscOutgoingPort)
        incomingPortDraft = String(engine.configuration.oscIncomingPort)
    }

    private func refreshSnapshotAndPermissions() {
        launchManager.refresh()
        isAccessibilityTrusted = engine.actionExecutor.isAccessibilityTrusted(prompt: false)
        xmlSnapshot = TotalMixConfigInspector.inspect(
            expectedOutgoingPort: engine.totalMix.outgoingPort,
            expectedIncomingPort: engine.totalMix.incomingPort
        )
    }

    private func applyOSCPortChanges() {
        guard let outPort = UInt16(outgoingPortDraft.trimmingCharacters(in: .whitespaces)),
              let inPort = UInt16(incomingPortDraft.trimmingCharacters(in: .whitespaces)),
              outPort > 0, inPort > 0, outPort != inPort
        else {
            portValidationMessage = "请输入 1...65535 之间且互不相同的有效发送/接收端口号（例如 7001 与 9001）。"
            return
        }
        portValidationMessage = nil
        engine.updateOSCEndpoint(
            host: hostDraft,
            outgoingPort: outPort,
            incomingPort: inPort
        )
        refreshSnapshotAndPermissions()
    }

    private var tourBoxColor: Color {
        switch engine.tourBoxState {
        case .connected: return .green
        case .connecting, .portBusy: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private func oscDirectionColor(_ dir: String) -> Color {
        if dir == "RX" { return .green }
        if dir == "TX" { return .cyan }
        return .orange
    }
}
