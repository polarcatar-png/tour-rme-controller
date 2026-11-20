import AppKit
import SwiftUI
import TourMixCore

/// 菜单栏弹出监听控制面板（固定宽 `336 pt`，自适应 `1..N` 个已绑定输出通道）。
@MainActor
public struct MenuBarPopoverView: View {
    private let engine: CoordinatorEngine
    private let launchManager: LaunchAtLoginManager
    private let onOpenKeymapper: () -> Void
    private let onOpenDiagnostics: () -> Void
    private let onQuit: () -> Void

    @State private var isSetupGuideExpanded: Bool = true

    public init(
        engine: CoordinatorEngine,
        launchManager: LaunchAtLoginManager,
        onOpenKeymapper: @escaping () -> Void,
        onOpenDiagnostics: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.engine = engine
        self.launchManager = launchManager
        self.onOpenKeymapper = onOpenKeymapper
        self.onOpenDiagnostics = onOpenDiagnostics
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar

            if !engine.totalMix.isConnected {
                oscSetupGuideCard
            }

            channelsSection

            controlRoomStrip

            if !launchManager.isInstalledInApplications {
                installToApplicationsBanner
            }

            Divider()
                .overlay(Color.white.opacity(0.08))

            footerBar
        }
        .padding(12)
        .frame(width: 336)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.12, blue: 0.14),
                    Color(red: 0.08, green: 0.09, blue: 0.11),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .preferredColorScheme(.dark)
    }

    // MARK: - 1. Top Status & Profile Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                tourBoxStatusBadge
                totalMixStatusBadge
            }

            Spacer(minLength: 4)

            profilePickerMenu
        }
    }

    private var tourBoxStatusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tourBoxDotColor)
                .frame(width: 7, height: 7)
                .shadow(color: tourBoxDotColor.opacity(0.6), radius: 3)

            Text(tourBoxShortStatus)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1)

            if case .portBusy = engine.tourBoxState {
                Button("重连") {
                    engine.reconnectTourBoxNow()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.16), in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.06), in: Capsule())
        .help(engine.tourBoxState.displayText)
    }

    private var totalMixStatusBadge: some View {
        Button {
            if !engine.totalMix.isConnected {
                onOpenDiagnostics()
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(totalMixDotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: totalMixDotColor.opacity(0.6), radius: 3)

                Text(totalMixShortStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(
            engine.totalMix.isConnected
                ? "已连接 \(engine.totalMix.detectedDeviceName)"
                : "等待 TotalMix FX Global OSC 响应（点击查看连接诊断）"
        )
    }

    private var profilePickerMenu: some View {
        Menu {
            ForEach(engine.configuration.profiles) { profile in
                Button {
                    engine.selectProfile(id: profile.id)
                } label: {
                    HStack {
                        Text(profile.name)
                        if profile.id == engine.activeProfile.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button("管理预设与按键映射…") {
                onOpenKeymapper()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                Text(engine.activeProfile.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 122)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - 2. Offline TotalMix Smart Guide Card

    private var oscSetupGuideCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isPortConflict ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPortConflict ? .red : .orange)

                Text(isPortConflict ? "OSC 本地监听端口冲突" : "等待连接 TotalMix FX Global OSC")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    isSetupGuideExpanded.toggle()
                } label: {
                    Image(systemName: isSetupGuideExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isSetupGuideExpanded {
                if case .portInUse(_, let message) = engine.totalMix.transportState {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("1. TotalMix 菜单勾选 Options → Enable OSC Control")
                        Text("2. Settings → OSC 勾选 In Use，地址填 127.0.0.1，端口 \(engine.totalMix.outgoingPort)/\(engine.totalMix.incomingPort)")
                        Text("3. Compatibility 选择 Global OSC（开启后无需重启自动秒连）")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                    if let diag = engine.totalMix.offlineDiagnostic, !diag.issues.isEmpty {
                        Text(diag.offlineHintSummary)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }

                HStack(spacing: 8) {
                    Button("立即探测") {
                        engine.totalMix.requestStateHeartbeat()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))

                    Button("查看连接诊断…") {
                        onOpenDiagnostics()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.cyan)

                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isPortConflict ? Color.red.opacity(0.12) : Color.orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isPortConflict ? Color.red.opacity(0.35) : Color.orange.opacity(0.28),
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - 3. Adaptive 1~N Output Channels Section

    @ViewBuilder
    private var channelsSection: some View {
        let bound = engine.boundOutputChannels

        if bound.isEmpty {
            emptyChannelCard
        } else if bound.count == 1, let single = bound.first {
            VStack(alignment: .leading, spacing: 6) {
                PrimaryOutputMonitorCard(
                    engine: engine,
                    channelIndex: single.channelIndex,
                    safetyClamp0dB: single.safetyClamp0dB
                )

                Button {
                    onOpenKeymapper()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("绑定更多通道或物理按键…")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        } else if bound.count <= 4 {
            VStack(spacing: 7) {
                ForEach(bound, id: \.channelIndex) { item in
                    CompactOutputMonitorCard(
                        engine: engine,
                        channelIndex: item.channelIndex,
                        safetyClamp0dB: item.safetyClamp0dB
                    )
                }
            }
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 7) {
                    ForEach(bound, id: \.channelIndex) { item in
                        CompactOutputMonitorCard(
                            engine: engine,
                            channelIndex: item.channelIndex,
                            safetyClamp0dB: item.safetyClamp0dB
                        )
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 280)
        }
    }

    private var emptyChannelCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "dial.medium")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("当前预设未绑定 RME 输出推子")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Button("打开按键映射工作台配置…") {
                onOpenKeymapper()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 4. Control Room Quick Strip

    private var controlRoomStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("监听室快捷栏")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Main: \(engine.totalMix.mainOutDisplayName)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.85))
            }

            HStack(spacing: 6) {
                controlRoomPill(
                    title: "TotalMix",
                    icon: "macwindow",
                    isActive: false,
                    activeColor: .blue
                ) {
                    _ = engine.totalMix.toggleTotalMixWindow()
                }

                controlRoomPill(
                    title: "DIM",
                    icon: "speaker.minus.fill",
                    isActive: engine.totalMix.controlRoom.dim,
                    activeColor: .orange
                ) {
                    _ = engine.totalMix.toggleControlRoom(.dim)
                }

                controlRoomPill(
                    title: "MONO",
                    icon: "circle.grid.cross.fill",
                    isActive: engine.totalMix.controlRoom.mono,
                    activeColor: .teal
                ) {
                    _ = engine.totalMix.toggleControlRoom(.mono)
                }

                controlRoomPill(
                    title: "SPK B",
                    icon: "hifispeaker.2.fill",
                    isActive: engine.totalMix.controlRoom.speakerB,
                    activeColor: .cyan
                ) {
                    _ = engine.totalMix.toggleControlRoom(.speakerB)
                }
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func controlRoomPill(
        title: String,
        icon: String,
        isActive: Bool,
        activeColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .foregroundStyle(isActive ? Color.black : Color.primary.opacity(0.88))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? activeColor : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 5. /Applications Hint & Footer Bar

    private var installToApplicationsBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 11))
                .foregroundStyle(.cyan)
            Text("当前未在 /Applications 运行，移入后自启更稳定")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("移入") {
                _ = launchManager.installToApplications(relaunch: false)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.cyan)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.cyan.opacity(0.15), in: Capsule())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Button {
                onOpenKeymapper()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "dial.high.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("按键映射工作台…")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.cyan.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(Color.cyan)
            }
            .buttonStyle(.plain)

            Spacer()

            // 屏幕毛玻璃 HUD 快捷开关
            Button {
                engine.setShowHUD(!engine.configuration.showHUD)
            } label: {
                Image(systemName: engine.configuration.showHUD ? "rectangle.inset.bottomleading.filled" : "rectangle.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(engine.configuration.showHUD ? Color.cyan : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help(engine.configuration.showHUD ? "屏幕音量 HUD：已开启" : "屏幕音量 HUD：已关闭")

            // 开机自启快捷开关
            Button {
                launchManager.toggle()
            } label: {
                Image(systemName: launchManager.isEnabled ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(launchManager.isEnabled ? Color.green : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help(launchManager.isEnabled ? "开机自动启动：已开启" : "开机自动启动：已关闭")

            Button {
                onQuit()
            } label: {
                Text("退出")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Derived Status Helpers

    private var tourBoxDotColor: Color {
        switch engine.tourBoxState {
        case .connected:
            return .green
        case .connecting, .portBusy:
            return .orange
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }

    private var tourBoxShortStatus: String {
        switch engine.tourBoxState {
        case .connected:
            return "TourBox"
        case .connecting:
            return "握手…"
        case .portBusy:
            return "串口占用"
        case .disconnected:
            return "未插线"
        case .error:
            return "串口异常"
        }
    }

    private var isPortConflict: Bool {
        if case .portInUse = engine.totalMix.transportState {
            return true
        }
        return false
    }

    private var totalMixDotColor: Color {
        if engine.totalMix.isConnected {
            return .green
        }
        if isPortConflict {
            return .red
        }
        return .orange
    }

    private var totalMixShortStatus: String {
        if engine.totalMix.isConnected {
            return "UCX OSC"
        }
        if isPortConflict {
            return "端口占用"
        }
        return "等待 OSC"
    }
}

// MARK: - Single-Channel Hero Monitor Card (Default AN 1/2)

@MainActor
private struct PrimaryOutputMonitorCard: View {
    let engine: CoordinatorEngine
    let channelIndex: Int
    let safetyClamp0dB: Bool

    private var channelState: MixerChannelState {
        engine.totalMix.outputChannel(at: channelIndex) ?? MixerChannelState(
            index: channelIndex,
            bus: .output,
            displayName: FirefaceUCXProfile.stereoDefaultLabel(bus: .output, evenIndex: channelIndex)
        )
    }

    var body: some View {
        let ch = channelState
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ch.displayName)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(ch.isStereo ? "STEREO" : "MONO")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.white.opacity(0.10), in: Capsule())
                            .foregroundStyle(.secondary)
                    }

                    Text("Hardware Output · Knob 主旋钮直控")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(readoutText(for: ch))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ch.isMuted ? Color.cyan : Color.white)
            }

            RMEFaderBar(
                normalizedValue: ch.normalizedFader,
                isMuted: ch.isMuted,
                safetyClamp0dB: safetyClamp0dB,
                height: 18
            ) { newNorm in
                engine.setOutputChannelFaderNormalized(channelIndex: channelIndex, normalized: newNorm)
            } onDoubleClickUnity: {
                _ = engine.totalMix.setOutputFaderDb(
                    channel: channelIndex,
                    db: 0.0,
                    safetyClamp0dB: safetyClamp0dB
                )
            }

            HStack(spacing: 8) {
                Button {
                    _ = engine.toggleOutputChannelMute(channelIndex: channelIndex)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: ch.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(ch.isMuted ? "已静音 (MUTED)" : "单通道静音")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ch.isMuted ? Color.cyan : Color.white.opacity(0.08))
                    )
                    .foregroundStyle(ch.isMuted ? Color.black : Color.primary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    engine.setOutputChannelSafetyClamp(channelIndex: channelIndex, enabled: !safetyClamp0dB)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: safetyClamp0dB ? "lock.fill" : "lock.open")
                            .font(.system(size: 10, weight: .bold))
                        Text("0 dB 保护")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(safetyClamp0dB ? Color.orange.opacity(0.22) : Color.white.opacity(0.06))
                    )
                    .foregroundStyle(safetyClamp0dB ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("开启后顺时针拧旋钮最高停在 0.0 dB，防止监听音箱意外过载")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private func readoutText(for ch: MixerChannelState) -> String {
        if ch.isMuted {
            return "MUTED"
        }
        return ch.hasConfirmedValue ? ch.formattedDb : "--.- dB"
    }
}

// MARK: - Multi-Channel Compact Monitor Card (2..N Channels)

@MainActor
private struct CompactOutputMonitorCard: View {
    let engine: CoordinatorEngine
    let channelIndex: Int
    let safetyClamp0dB: Bool

    private var channelState: MixerChannelState {
        engine.totalMix.outputChannel(at: channelIndex) ?? MixerChannelState(
            index: channelIndex,
            bus: .output,
            displayName: FirefaceUCXProfile.stereoDefaultLabel(bus: .output, evenIndex: channelIndex)
        )
    }

    var body: some View {
        let ch = channelState
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(ch.displayName)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                Text(ch.isMuted ? "MUTED" : (ch.hasConfirmedValue ? ch.formattedDb : "--.- dB"))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ch.isMuted ? Color.cyan : Color.primary)

                Button {
                    engine.setOutputChannelSafetyClamp(channelIndex: channelIndex, enabled: !safetyClamp0dB)
                } label: {
                    Image(systemName: safetyClamp0dB ? "lock.fill" : "lock.open")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(safetyClamp0dB ? Color.orange : Color.secondary)
                        .frame(width: 22, height: 20)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("切换 0.0 dB 过载保护锁")

                Button {
                    _ = engine.toggleOutputChannelMute(channelIndex: channelIndex)
                } label: {
                    Text("M")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundStyle(ch.isMuted ? Color.black : Color.primary)
                        .frame(width: 22, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(ch.isMuted ? Color.cyan : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("单通道静音 (/output/\(channelIndex)/mute)")
            }

            RMEFaderBar(
                normalizedValue: ch.normalizedFader,
                isMuted: ch.isMuted,
                safetyClamp0dB: safetyClamp0dB,
                height: 12
            ) { newNorm in
                engine.setOutputChannelFaderNormalized(channelIndex: channelIndex, normalized: newNorm)
            } onDoubleClickUnity: {
                _ = engine.totalMix.setOutputFaderDb(
                    channel: channelIndex,
                    db: 0.0,
                    safetyClamp0dB: safetyClamp0dB
                )
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

// MARK: - Zero-Lag Horizontal Fader Bar with 0.0 dB Unity Tick

private struct RMEFaderBar: View {
    let normalizedValue: Double
    let isMuted: Bool
    let safetyClamp0dB: Bool
    let height: CGFloat
    let onScrub: (Double) -> Void
    let onDoubleClickUnity: () -> Void

    private let unityPosition = RMEFaderCurve.zeroDbNormalized

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let clamped = min(1.0, max(0.0, normalizedValue))
            let fillWidth = width * clamped
            let unityX = width * unityPosition

            ZStack(alignment: .leading) {
                // 轨道底槽
                Capsule()
                    .fill(Color.black.opacity(0.45))

                // 若开启 0dB 安全锁，在 >0dB 区间铺设柔和警戒暗纹提示
                if safetyClamp0dB {
                    Rectangle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: max(0, width - unityX))
                        .offset(x: unityX)
                }

                // 实时音量填充条（禁用隐式补间防高频延迟）
                Capsule()
                    .fill(fillGradient)
                    .frame(width: max(0, fillWidth))
                    .transaction { tx in
                        tx.disablesAnimations = true
                    }

                // 0.0 dB (836/1023) 刻度白线
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 1.5, height: height)
                    .offset(x: min(width - 1.5, max(0, unityX - 0.75)))

                // 推子滑块游标
                Circle()
                    .fill(Color.white)
                    .frame(width: height - 2, height: height - 2)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .offset(x: min(width - (height - 2), max(0, fillWidth - (height - 2) * 0.5)))
                    .transaction { tx in
                        tx.disablesAnimations = true
                    }
            }
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let ratio = Double(min(max(0, gesture.location.x), width) / width)
                        onScrub(ratio)
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        onDoubleClickUnity()
                    }
            )
        }
        .frame(height: height)
    }

    private var fillGradient: LinearGradient {
        if isMuted {
            return LinearGradient(
                colors: [Color.cyan.opacity(0.45), Color.cyan.opacity(0.75)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        if normalizedValue > unityPosition + 0.002 {
            return LinearGradient(
                colors: [Color.green.opacity(0.85), Color.orange.opacity(0.95)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [Color(red: 0.16, green: 0.68, blue: 0.92), Color(red: 0.22, green: 0.86, blue: 0.72)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
