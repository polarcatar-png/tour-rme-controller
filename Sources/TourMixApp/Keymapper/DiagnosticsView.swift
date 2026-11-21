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
        .background(TotalMixTheme.windowBackground)
        .onAppear {
            engine.setDiagnosticsCaptureEnabled(true)
            syncDraftsFromEngine()
            refreshSnapshotAndPermissions()
            engine.totalMix.requestStateHeartbeat()
        }
        .onDisappear {
            engine.setDiagnosticsCaptureEnabled(false)
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
                        .foregroundStyle(TotalMixTheme.textSecondary)

                    if let port = engine.tourBoxState.port {
                        Text("设备节点：\(port)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TotalMixTheme.textSecondary)
                    } else {
                        Text("匹配 VID:PID = 0xCAFE:0x4001 (115200 8N1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TotalMixTheme.textSecondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(TotalMixTheme.chassisDeep.opacity(0.65))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.85)
                        )
                )

                // 右卡：TotalMix FX Global OSC 状态
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(engine.totalMix.isConnected ? TotalMixTheme.rmeGreen : TotalMixTheme.rmeAmber)
                            .frame(width: 9, height: 9)
                        Text("TotalMix FX Global OSC")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(engine.totalMix.isConnected ? "实时在线" : "等待响应")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(engine.totalMix.isConnected ? TotalMixTheme.rmeGreen : TotalMixTheme.rmeAmber)
                    }

                    Text("设备型号：\(engine.totalMix.detectedDeviceName)")
                        .font(.system(size: 12))
                        .foregroundStyle(TotalMixTheme.textSecondary)

                    HStack(spacing: 12) {
                        Text("Control Room Main Out：\(engine.totalMix.mainOutDisplayName)")
                            .font(.system(size: 11))
                            .foregroundStyle(TotalMixTheme.textSecondary)
                        if let dsp = engine.totalMix.dspLoad {
                            Text(String(format: "DSP: %.1f%%", dsp))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(TotalMixTheme.textSecondary)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(TotalMixTheme.chassisDeep.opacity(0.65))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.85)
                        )
                )
            }

            // 若本地 UDP 接收端口冲突（如 9001 被 TouchOSC / Companion 占用），醒目红字警告并提供一键切换
            if case .portInUse(let busyPort, let message) = engine.totalMix.transportState {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(TotalMixTheme.rmeRed)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UDP 监听端口 \(busyPort) 被占用")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(TotalMixTheme.rmeRed)
                        Text(message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(TotalMixTheme.textPrimary)
                    }
                    Spacer()
                    Button("一键改用 7002 / 9002") {
                        hostDraft = "127.0.0.1"
                        outgoingPortDraft = "7002"
                        incomingPortDraft = "9002"
                        applyOSCPortChanges()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TotalMixTheme.rmeAmber)
                    .controlSize(.small)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(TotalMixTheme.rmeRed.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(TotalMixTheme.rmeRed.opacity(0.45), lineWidth: 0.9)
                        )
                )
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
                            .foregroundStyle(TotalMixTheme.textSecondary)
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
                            .foregroundStyle(TotalMixTheme.textSecondary)
                    }
                    if !engine.totalMix.isConnected {
                        Text(snapshot.offlineHintSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(TotalMixTheme.rmeAmber)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TotalMixTheme.chassisDeep.opacity(0.65))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.75)
                        )
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TotalMixTheme.stripCardGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.85)
                )
        )
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
                        .foregroundStyle(TotalMixTheme.textSecondary)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Label(
                            launchManager.isRunningFromApplications ? "已从 /Applications 运行" : "当前未从 /Applications 运行",
                            systemImage: launchManager.isRunningFromApplications ? "checkmark.circle.fill" : "info.circle"
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(launchManager.isRunningFromApplications ? TotalMixTheme.rmeGreen : TotalMixTheme.rmeAmber)

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
                            .foregroundStyle(TotalMixTheme.rmeRed)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(TotalMixTheme.chassisDeep.opacity(0.65))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.85)
                        )
                )

                // 右卡：辅助功能权限（仅键盘快捷键合成需要）
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("辅助功能权限 (Accessibility)")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(isAccessibilityTrusted ? "已授权" : "未授权（纯 RME 控制无需此权限）")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isAccessibilityTrusted ? TotalMixTheme.rmeGreen : TotalMixTheme.textSecondary)
                    }

                    Text("控制 RME 音量/静音/监听室及系统媒体键完全无需任何隐私权限；仅当您为按键绑定「自定义电脑键盘快捷键」时才需开启。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(TotalMixTheme.textSecondary)

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
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(TotalMixTheme.chassisDeep.opacity(0.65))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.85)
                        )
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TotalMixTheme.stripCardGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.85)
                )
        )
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
                        .foregroundStyle(TotalMixTheme.textSecondary)
                }

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        let items = Array(engine.serialDiagnostics.suffix(80).reversed())
                        if items.isEmpty {
                            Text("暂无串口报文（转动旋钮或按下任意键即可实时观测原始 Hex 字节）")
                                .font(.system(size: 11))
                                .foregroundStyle(TotalMixTheme.textSecondary)
                                .padding(8)
                        } else {
                            ForEach(items) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(entry.direction)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(entry.direction == "IN" ? TotalMixTheme.rmeGreenBright : TotalMixTheme.rmeAmber)
                                        .frame(width: 34, alignment: .leading)
                                    Text(entry.hex)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(TotalMixTheme.textPrimary)
                                    Text(entry.note)
                                        .font(.system(size: 11))
                                        .foregroundStyle(TotalMixTheme.textSecondary)
                                        .lineLimit(1)
                                }
                                .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(height: 220)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TotalMixTheme.chassisDeep)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.75)
                        )
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(TotalMixTheme.stripCardGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.85)
                    )
            )

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
                                .foregroundStyle(TotalMixTheme.textSecondary)
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
                                        .foregroundStyle(TotalMixTheme.textPrimary)
                                        .lineLimit(1)
                                }
                                .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(height: 220)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TotalMixTheme.chassisDeep)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.75)
                        )
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(TotalMixTheme.stripCardGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.85)
                    )
            )
        }
    }

    // MARK: - Actions & Helpers

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TotalMixTheme.accent)
            Text(title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(TotalMixTheme.textPrimary)
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
        case .connected: return TotalMixTheme.rmeGreen
        case .connecting, .portBusy: return TotalMixTheme.rmeAmber
        case .disconnected: return TotalMixTheme.textMuted
        case .error: return TotalMixTheme.rmeRed
        }
    }

    private func oscDirectionColor(_ dir: String) -> Color {
        if dir == "RX" { return TotalMixTheme.rmeGreen }
        if dir == "TX" { return TotalMixTheme.accent }
        return TotalMixTheme.rmeAmber
    }
}
