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
                .overlay(TotalMixTheme.borderSubtle)

            footerBar
        }
        .padding(12)
        .frame(width: 336)
        .background(TotalMixTheme.windowGradient)
        .tint(TotalMixTheme.accent)
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
                .foregroundStyle(TotalMixTheme.textPrimary)
                .lineLimit(1)

            if case .portBusy = engine.tourBoxState {
                Button("重连") {
                    engine.reconnectTourBoxNow()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TotalMixTheme.rmeAmber)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(TotalMixTheme.rmeAmber.opacity(0.18), in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(TotalMixTheme.stripSurfaceTop)
                .overlay(
                    Capsule()
                        .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.75)
                )
        )
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
                    .foregroundStyle(TotalMixTheme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(TotalMixTheme.stripSurfaceTop)
                    .overlay(
                        Capsule()
                            .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.75)
                    )
            )
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
                    .foregroundStyle(TotalMixTheme.accent)
                Text(engine.activeProfile.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TotalMixTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(TotalMixTheme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 122)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(TotalMixTheme.stripSurfaceTop)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.75)
                    )
            )
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
                    .foregroundStyle(isPortConflict ? TotalMixTheme.rmeRed : TotalMixTheme.rmeAmber)

                Text(isPortConflict ? "OSC 本地监听端口冲突" : "等待连接 TotalMix FX Global OSC")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(TotalMixTheme.textPrimary)

                Spacer()

                Button {
                    isSetupGuideExpanded.toggle()
                } label: {
                    Image(systemName: isSetupGuideExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(TotalMixTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if isSetupGuideExpanded {
                if case .portInUse(_, let message) = engine.totalMix.transportState {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(TotalMixTheme.rmeRed)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("1. TotalMix 菜单勾选 Options → Enable OSC Control")
                        Text("2. Settings → OSC 勾选 In Use，地址填 127.0.0.1，端口 \(engine.totalMix.outgoingPort)/\(engine.totalMix.incomingPort)")
                        Text("3. Compatibility 选择 Global OSC（开启后无需重启自动秒连）")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(TotalMixTheme.textSecondary)

                    if let diag = engine.totalMix.offlineDiagnostic, !diag.issues.isEmpty {
                        Text(diag.offlineHintSummary)
                            .font(.system(size: 10))
                            .foregroundStyle(TotalMixTheme.rmeAmber)
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
                    .foregroundStyle(TotalMixTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(TotalMixTheme.surfaceControl, in: RoundedRectangle(cornerRadius: 5))

                    Button("查看连接诊断…") {
                        onOpenDiagnostics()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(TotalMixTheme.accent)

                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(TotalMixTheme.stripSurfaceBottom)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isPortConflict ? TotalMixTheme.rmeRed.opacity(0.65) : TotalMixTheme.rmeAmber.opacity(0.50),
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
                    safetyClamp0dB: single.safetyClamp0dB,
                    safetyMaxDb: single.safetyMaxDb
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
                    .foregroundStyle(TotalMixTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(TotalMixTheme.stripSurfaceBottom)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(TotalMixTheme.borderSubtle.opacity(0.7), lineWidth: 0.7)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        } else if bound.count <= 4 {
            VStack(spacing: 7) {
                ForEach(bound, id: \.channelIndex) { item in
                    CompactOutputMonitorCard(
                        engine: engine,
                        channelIndex: item.channelIndex,
                        safetyClamp0dB: item.safetyClamp0dB,
                        safetyMaxDb: item.safetyMaxDb
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
                            safetyClamp0dB: item.safetyClamp0dB,
                            safetyMaxDb: item.safetyMaxDb
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
                .foregroundStyle(TotalMixTheme.textSecondary)
            Text("当前预设未绑定 RME 输出推子")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TotalMixTheme.textSecondary)
            Button("打开按键映射工作台配置…") {
                onOpenKeymapper()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(TotalMixTheme.stripCardGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.8)
                )
        )
    }

    // MARK: - 4. Control Room Quick Strip

    private var controlRoomStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("监听室快捷栏")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TotalMixTheme.textSecondary)
                Spacer()
                Text("Main: \(engine.totalMix.mainOutDisplayName)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TotalMixTheme.textMuted)
            }

            HStack(spacing: 6) {
                controlRoomPill(
                    title: "TotalMix",
                    icon: "macwindow",
                    isActive: false,
                    activeColor: TotalMixTheme.accentDeep,
                    inactiveIconColor: TotalMixTheme.accent
                ) {
                    _ = engine.totalMix.toggleTotalMixWindow()
                }

                controlRoomPill(
                    title: "DIM",
                    icon: "speaker.minus.fill",
                    isActive: engine.totalMix.controlRoom.dim,
                    activeColor: TotalMixTheme.rmeAmber,
                    activeTextColor: TotalMixTheme.chassisDeep
                ) {
                    _ = engine.totalMix.toggleControlRoom(.dim)
                }

                controlRoomPill(
                    title: "MONO",
                    icon: "circle.grid.cross.fill",
                    isActive: engine.totalMix.controlRoom.mono,
                    activeColor: TotalMixTheme.accentDeep,
                    activeTextColor: TotalMixTheme.textPrimary
                ) {
                    _ = engine.totalMix.toggleControlRoom(.mono)
                }

                controlRoomPill(
                    title: "SPK B",
                    icon: "hifispeaker.2.fill",
                    isActive: engine.totalMix.controlRoom.speakerB,
                    activeColor: TotalMixTheme.accent,
                    activeTextColor: TotalMixTheme.chassisDeep
                ) {
                    _ = engine.totalMix.toggleControlRoom(.speakerB)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(TotalMixTheme.stripSurfaceBottom)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.8)
                )
        )
    }

    private func controlRoomPill(
        title: String,
        icon: String,
        isActive: Bool,
        activeColor: Color,
        activeTextColor: Color = TotalMixTheme.chassisDeep,
        inactiveIconColor: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isActive ? activeTextColor : (inactiveIconColor ?? TotalMixTheme.textPrimary))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isActive ? activeTextColor : TotalMixTheme.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? activeColor : TotalMixTheme.surfaceControl)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isActive ? activeColor.opacity(0.9) : TotalMixTheme.borderSubtle, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 5. /Applications Hint & Footer Bar

    private var installToApplicationsBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 11))
                .foregroundStyle(TotalMixTheme.accent)
            Text("当前未在 /Applications 运行，移入后自启更稳定")
                .font(.system(size: 10))
                .foregroundStyle(TotalMixTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("移入") {
                _ = launchManager.installToApplications(relaunch: false)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(TotalMixTheme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(TotalMixTheme.accentDeep.opacity(0.28), in: Capsule())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(TotalMixTheme.stripSurfaceBottom, in: RoundedRectangle(cornerRadius: 7))
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
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(TotalMixTheme.accentDeep.opacity(0.32))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(TotalMixTheme.accent.opacity(0.55), lineWidth: 0.8)
                        )
                )
                .foregroundStyle(TotalMixTheme.accentLight)
            }
            .buttonStyle(.plain)

            Spacer()

            // 屏幕毛玻璃 HUD 快捷开关
            Button {
                engine.setShowHUD(!engine.configuration.showHUD)
            } label: {
                Image(systemName: engine.configuration.showHUD ? "rectangle.inset.bottomleading.filled" : "rectangle.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(engine.configuration.showHUD ? TotalMixTheme.accent : TotalMixTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(TotalMixTheme.surfaceControl, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help(engine.configuration.showHUD ? "屏幕音量 HUD：已开启" : "屏幕音量 HUD：已关闭")

            // 开机自启快捷开关
            Button {
                launchManager.toggle()
            } label: {
                Image(systemName: launchManager.isEnabled ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(launchManager.isEnabled ? TotalMixTheme.rmeGreen : TotalMixTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(TotalMixTheme.surfaceControl, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help(launchManager.isEnabled ? "开机自动启动：已开启" : "开机自动启动：已关闭")

            Button {
                onQuit()
            } label: {
                Text("退出")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TotalMixTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(TotalMixTheme.surfaceControl, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Derived Status Helpers

    private var tourBoxDotColor: Color {
        switch engine.tourBoxState {
        case .connected:
            return TotalMixTheme.rmeGreen
        case .connecting, .portBusy:
            return TotalMixTheme.rmeAmber
        case .disconnected:
            return TotalMixTheme.textMuted
        case .error:
            return TotalMixTheme.rmeRed
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
            return TotalMixTheme.rmeGreen
        }
        if isPortConflict {
            return TotalMixTheme.rmeRed
        }
        return TotalMixTheme.rmeAmber
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
    let safetyMaxDb: Double

    @State private var isEditingSafetyLimit: Bool = false

    private var channelState: MixerChannelState {
        engine.totalMix.outputChannel(at: channelIndex) ?? MixerChannelState(
            index: channelIndex,
            bus: .output,
            displayName: FirefaceUCXProfile.stereoDefaultLabel(bus: .output, evenIndex: channelIndex)
        )
    }

    var body: some View {
        let ch = channelState
        let effectiveMaxDb = VolumeSafetyLimit.clampCeilingDb(safetyMaxDb)
        let isAtSafetyCeiling = safetyClamp0dB && ch.hasConfirmedValue && ch.dbValue >= effectiveMaxDb - 0.05

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(ch.isMuted ? TotalMixTheme.rmeRed : TotalMixTheme.accent)
                            .frame(width: 3, height: 15)

                        Text(ch.displayName)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(TotalMixTheme.textPrimary)

                        Text(ch.isStereo ? "STEREO" : "MONO")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(TotalMixTheme.surfaceControl, in: Capsule())
                            .foregroundStyle(TotalMixTheme.textSecondary)
                    }

                    Text("Hardware Output · Knob 主旋钮直控")
                        .font(.system(size: 10))
                        .foregroundStyle(TotalMixTheme.textSecondary)
                }

                Spacer()

                Text(readoutText(for: ch))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(readoutColor(for: ch, atCeiling: isAtSafetyCeiling))
            }

            RMEFaderBar(
                normalizedValue: ch.normalizedFader,
                isMuted: ch.isMuted,
                safetyClamp0dB: safetyClamp0dB,
                safetyMaxDb: effectiveMaxDb,
                height: 18
            ) { newNorm in
                engine.setOutputChannelFaderNormalized(channelIndex: channelIndex, normalized: newNorm)
            } onDoubleClickUnity: {
                _ = engine.totalMix.setOutputFaderDb(
                    channel: channelIndex,
                    db: 0.0,
                    safetyClamp0dB: safetyClamp0dB,
                    safetyMaxDb: effectiveMaxDb
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
                            .fill(ch.isMuted ? TotalMixTheme.rmeRedDeep : TotalMixTheme.surfaceControl)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        ch.isMuted ? TotalMixTheme.rmeRed : TotalMixTheme.borderSubtle,
                                        lineWidth: 0.75
                                    )
                            )
                    )
                    .foregroundStyle(TotalMixTheme.textPrimary)
                }
                .buttonStyle(.plain)

                Spacer()

                // 音量上限保护分体开关：左侧开关保护，右侧展开自定义 dB 上限抽屉
                HStack(spacing: 0) {
                    Button {
                        engine.setOutputChannelSafetyLimit(
                            channelIndex: channelIndex,
                            enabled: !safetyClamp0dB,
                            maxDb: effectiveMaxDb
                        )
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: safetyClamp0dB ? "lock.fill" : "lock.open")
                                .font(.system(size: 9.5, weight: .bold))
                            Text(safetyClamp0dB ? "上限 \(VolumeSafetyLimit.formatLimitDb(effectiveMaxDb))" : "保护已关")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 6)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .help("开启或关闭旋钮音量保护上限（当前上限 \(VolumeSafetyLimit.formatLimitDb(effectiveMaxDb))）")

                    Rectangle()
                        .fill(safetyClamp0dB ? TotalMixTheme.rmeAmber.opacity(0.35) : TotalMixTheme.borderSubtle)
                        .frame(width: 1, height: 14)

                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isEditingSafetyLimit.toggle()
                        }
                    } label: {
                        Image(systemName: isEditingSafetyLimit ? "chevron.up" : "slider.horizontal.3")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .help("展开并自由调整保护上限分贝值 (-60 ... +6 dB)")
                }
                .foregroundStyle(safetyClamp0dB ? TotalMixTheme.rmeAmber : TotalMixTheme.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(safetyClamp0dB ? TotalMixTheme.rmeAmber.opacity(0.18) : TotalMixTheme.surfaceControl)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    safetyClamp0dB ? TotalMixTheme.rmeAmber.opacity(0.50) : TotalMixTheme.borderSubtle,
                                    lineWidth: 0.75
                                )
                        )
                )
            }

            if isEditingSafetyLimit {
                inlineSafetyLimitDrawer(effectiveMaxDb: effectiveMaxDb)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(TotalMixTheme.stripCardGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 1)
                )
        )
    }

    private func inlineSafetyLimitDrawer(effectiveMaxDb: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("保护上限")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(TotalMixTheme.textSecondary)

                Text(VolumeSafetyLimit.formatLimitDb(effectiveMaxDb))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(TotalMixTheme.rmeAmber)

                Spacer()

                Button {
                    engine.setOutputChannelSafetyLimit(
                        channelIndex: channelIndex,
                        enabled: true,
                        maxDb: effectiveMaxDb - 0.5
                    )
                } label: {
                    Text("-0.5")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(TotalMixTheme.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TotalMixTheme.surfaceControl, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)

                Button {
                    engine.setOutputChannelSafetyLimit(
                        channelIndex: channelIndex,
                        enabled: true,
                        maxDb: effectiveMaxDb + 0.5
                    )
                } label: {
                    Text("+0.5")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(TotalMixTheme.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TotalMixTheme.surfaceControl, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 4) {
                ForEach(VolumeSafetyLimit.quickPresetsDb, id: \.self) { preset in
                    let selected = abs(effectiveMaxDb - preset) < 0.25
                    Button {
                        engine.setOutputChannelSafetyLimit(
                            channelIndex: channelIndex,
                            enabled: true,
                            maxDb: preset
                        )
                    } label: {
                        Text(preset == 0 ? "0" : (preset > 0 ? "+\(Int(preset))" : "\(Int(preset))"))
                            .font(.system(size: 9.5, weight: selected ? .bold : .medium, design: .rounded))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .foregroundStyle(selected ? TotalMixTheme.chassisDeep : TotalMixTheme.textPrimary)
                            .background(
                                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                    .fill(selected ? TotalMixTheme.rmeAmber : TotalMixTheme.surfaceControl)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Slider(
                value: Binding(
                    get: { effectiveMaxDb },
                    set: { rawVal in
                        let snapped = (rawVal * 2.0).rounded() / 2.0
                        engine.setOutputChannelSafetyLimit(
                            channelIndex: channelIndex,
                            enabled: true,
                            maxDb: snapped
                        )
                    }
                ),
                in: VolumeSafetyLimit.minConfigurableDb...VolumeSafetyLimit.maxConfigurableDb
            )
            .tint(TotalMixTheme.rmeAmber)
            .controlSize(.mini)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TotalMixTheme.chassisDeep)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.75)
                )
        )
    }

    private func readoutText(for ch: MixerChannelState) -> String {
        if ch.isMuted {
            return "MUTED"
        }
        return ch.hasConfirmedValue ? ch.formattedDb : "--.- dB"
    }

    private func readoutColor(for ch: MixerChannelState, atCeiling: Bool) -> Color {
        if ch.isMuted {
            return TotalMixTheme.rmeRed
        }
        if atCeiling || (ch.hasConfirmedValue && ch.dbValue > 0.05) {
            return TotalMixTheme.rmeAmber
        }
        return TotalMixTheme.textPrimary
    }
}

// MARK: - Multi-Channel Compact Monitor Card (2..N Channels)

@MainActor
private struct CompactOutputMonitorCard: View {
    let engine: CoordinatorEngine
    let channelIndex: Int
    let safetyClamp0dB: Bool
    let safetyMaxDb: Double

    private var channelState: MixerChannelState {
        engine.totalMix.outputChannel(at: channelIndex) ?? MixerChannelState(
            index: channelIndex,
            bus: .output,
            displayName: FirefaceUCXProfile.stereoDefaultLabel(bus: .output, evenIndex: channelIndex)
        )
    }

    var body: some View {
        let ch = channelState
        let effectiveMaxDb = VolumeSafetyLimit.clampCeilingDb(safetyMaxDb)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(ch.isMuted ? TotalMixTheme.rmeRed : TotalMixTheme.accent)
                    .frame(width: 2.5, height: 12)

                Text(ch.displayName)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(TotalMixTheme.textPrimary)

                Spacer()

                Text(ch.isMuted ? "MUTED" : (ch.hasConfirmedValue ? ch.formattedDb : "--.- dB"))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ch.isMuted ? TotalMixTheme.rmeRed : TotalMixTheme.textPrimary)

                Menu {
                    Button {
                        engine.setOutputChannelSafetyLimit(
                            channelIndex: channelIndex,
                            enabled: !safetyClamp0dB,
                            maxDb: effectiveMaxDb
                        )
                    } label: {
                        Label(
                            safetyClamp0dB ? "关闭上限保护" : "开启上限保护 (\(VolumeSafetyLimit.formatLimitDb(effectiveMaxDb)))",
                            systemImage: safetyClamp0dB ? "lock.open" : "lock.fill"
                        )
                    }
                    Divider()
                    ForEach(VolumeSafetyLimit.quickPresetsDb, id: \.self) { preset in
                        Button {
                            engine.setOutputChannelSafetyLimit(
                                channelIndex: channelIndex,
                                enabled: true,
                                maxDb: preset
                            )
                        } label: {
                            HStack {
                                Text("上限设为 \(VolumeSafetyLimit.formatLimitDb(preset))")
                                if safetyClamp0dB && abs(effectiveMaxDb - preset) < 0.25 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: safetyClamp0dB ? "lock.fill" : "lock.open")
                            .font(.system(size: 9, weight: .bold))
                        if safetyClamp0dB {
                            Text(VolumeSafetyLimit.formatLimitDb(effectiveMaxDb))
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(safetyClamp0dB ? TotalMixTheme.rmeAmber : TotalMixTheme.textSecondary)
                    .padding(.horizontal, 5.5)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(safetyClamp0dB ? TotalMixTheme.rmeAmber.opacity(0.18) : TotalMixTheme.surfaceControl)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("点击配置音量保护上限（当前：\(safetyClamp0dB ? VolumeSafetyLimit.formatLimitDb(effectiveMaxDb) : "已关闭")）")

                Button {
                    _ = engine.toggleOutputChannelMute(channelIndex: channelIndex)
                } label: {
                    Text("M")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundStyle(TotalMixTheme.textPrimary)
                        .frame(width: 22, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(ch.isMuted ? TotalMixTheme.rmeRedDeep : TotalMixTheme.surfaceControl)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(ch.isMuted ? TotalMixTheme.rmeRed : TotalMixTheme.borderSubtle, lineWidth: 0.7)
                        )
                }
                .buttonStyle(.plain)
                .help("单通道静音 (/output/\(channelIndex)/mute)")
            }

            RMEFaderBar(
                normalizedValue: ch.normalizedFader,
                isMuted: ch.isMuted,
                safetyClamp0dB: safetyClamp0dB,
                safetyMaxDb: effectiveMaxDb,
                height: 12
            ) { newNorm in
                engine.setOutputChannelFaderNormalized(channelIndex: channelIndex, normalized: newNorm)
            } onDoubleClickUnity: {
                _ = engine.totalMix.setOutputFaderDb(
                    channel: channelIndex,
                    db: 0.0,
                    safetyClamp0dB: safetyClamp0dB,
                    safetyMaxDb: effectiveMaxDb
                )
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(TotalMixTheme.stripCardGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.9)
                )
        )
    }
}

// MARK: - Zero-Lag Horizontal Fader Bar with Custom Ceiling Marker & Unity Tick

private struct RMEFaderBar: View {
    let normalizedValue: Double
    let isMuted: Bool
    let safetyClamp0dB: Bool
    let safetyMaxDb: Double
    let height: CGFloat
    let onScrub: (Double) -> Void
    let onDoubleClickUnity: () -> Void

    private let unityPosition = RMEFaderCurve.zeroDbNormalized

    var body: some View {
        let limitPosition = RMEFaderCurve.dbToNormalized(VolumeSafetyLimit.clampCeilingDb(safetyMaxDb))
        let thumbWidth: CGFloat = height >= 16 ? 11 : 9
        let thumbHeight: CGFloat = max(8, height - 1)

        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let clamped = min(1.0, max(0.0, normalizedValue))
            let fillWidth = width * clamped
            let unityX = width * unityPosition
            let limitX = width * limitPosition

            ZStack(alignment: .leading) {
                // 轨道底槽
                Capsule()
                    .fill(TotalMixTheme.chassisDeep)

                // 若开启音量保护上限，在 > limitDb 区间铺设 RME 琥珀色警戒区间
                if safetyClamp0dB {
                    Rectangle()
                        .fill(TotalMixTheme.rmeAmber.opacity(0.18))
                        .frame(width: max(0, width - limitX))
                        .offset(x: limitX)
                }

                // 实时音量填充条（禁用隐式补间防高频延迟）
                Capsule()
                    .fill(fillGradient)
                    .frame(width: max(0, fillWidth))
                    .transaction { tx in
                        tx.disablesAnimations = true
                    }

                // 0.0 dB (836/1023) 统一参考刻度线
                Rectangle()
                    .fill(TotalMixTheme.textPrimary.opacity(0.72))
                    .frame(width: 1.5, height: height)
                    .offset(x: min(width - 1.5, max(0, unityX - 0.75)))

                // 自定义安全保护上限高亮标记线
                if safetyClamp0dB {
                    Rectangle()
                        .fill(TotalMixTheme.rmeAmber)
                        .frame(width: 2.0, height: height)
                        .offset(x: min(width - 2.0, max(0, limitX - 1.0)))
                }

                // TotalMix 拟物滑块推子帽（带中心黑槽）
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [TotalMixTheme.faderCapTop, TotalMixTheme.faderCapBottom],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Rectangle()
                        .fill(TotalMixTheme.faderCapGroove)
                        .frame(width: 1.5, height: max(5, thumbHeight - 5))
                }
                .frame(width: thumbWidth, height: thumbHeight)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .offset(x: min(width - thumbWidth, max(0, fillWidth - thumbWidth * 0.5)))
                .transaction { tx in
                    tx.disablesAnimations = true
                }
            }
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(TotalMixTheme.borderSubtle, lineWidth: 0.85)
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
                colors: [TotalMixTheme.rmeRedDeep.opacity(0.68), TotalMixTheme.rmeRed.opacity(0.86)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        if normalizedValue > unityPosition + 0.002 {
            return LinearGradient(
                colors: [TotalMixTheme.rmeGreen, TotalMixTheme.rmeAmber, TotalMixTheme.rmeRed],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [TotalMixTheme.rmeGreenDeep, TotalMixTheme.rmeGreen, TotalMixTheme.rmeGreenBright],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
