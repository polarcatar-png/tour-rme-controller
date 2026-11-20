import AppKit
import SwiftUI
import TourMixCore

/// Top-level navigation tabs in the TourMix Keymapper & Console window.
public enum KeymapperTab: String, CaseIterable, Identifiable, Sendable {
    case bindings
    case preferences
    case diagnostics

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bindings: return "按键与旋钮映射"
        case .preferences: return "全局偏好"
        case .diagnostics: return "连接与报文诊断"
        }
    }

    public var systemIcon: String {
        switch self {
        case .bindings: return "dial.medium.fill"
        case .preferences: return "slider.horizontal.3"
        case .diagnostics: return "waveform.path.ecg"
        }
    }
}

/// Main TourMix configuration workbench (`~920 x 620`).
@MainActor
public struct KeymapperWindowView: View {
    public let engine: CoordinatorEngine
    public let launchManager: LaunchAtLoginManager
    @Binding public var selectedTab: KeymapperTab

    @State private var selectedControl: TourBoxControlId = .knob
    @State private var editingModifier: TourBoxButton? = nil

    @State private var showingNewProfileSheet = false
    @State private var copyFromCurrentOnCreate = false
    @State private var profileDraftName = ""

    @State private var showingRenameProfileSheet = false
    @State private var showingResetConfirmation = false
    @State private var scriptTestStatus: String?

    public init(
        engine: CoordinatorEngine,
        launchManager: LaunchAtLoginManager,
        selectedTab: Binding<KeymapperTab>
    ) {
        self.engine = engine
        self.launchManager = launchManager
        self._selectedTab = selectedTab
    }

    public var body: some View {
        VStack(spacing: 0) {
            topToolbar
            Divider()
                .overlay(Color.white.opacity(0.08))

            Group {
                switch selectedTab {
                case .bindings:
                    bindingsWorkbench
                case .preferences:
                    preferencesWorkbench
                case .diagnostics:
                    DiagnosticsView(engine: engine, launchManager: launchManager)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, idealWidth: 940, minHeight: 560, idealHeight: 630)
        .background(Color(red: 0.08, green: 0.09, blue: 0.11))
        .preferredColorScheme(.dark)
        .onChange(of: engine.activeProfile.id) { _, _ in
            if let mod = editingModifier, !engine.activeProfile.modifierButtons.contains(mod) {
                editingModifier = nil
            }
        }
        .onChange(of: engine.activeProfile.modifierButtons) { _, newMods in
            if let mod = editingModifier, !newMods.contains(mod) {
                editingModifier = nil
            }
        }
        .sheet(isPresented: $showingNewProfileSheet) {
            profileNameSheet(
                title: copyFromCurrentOnCreate ? "复制当前预设" : "新建空白预设",
                prompt: "输入预设名称",
                confirmTitle: "创建"
            ) { name in
                engine.createProfile(name: name, copyFromActive: copyFromCurrentOnCreate)
            }
        }
        .sheet(isPresented: $showingRenameProfileSheet) {
            profileNameSheet(
                title: "重命名预设",
                prompt: "输入新的预设名称",
                confirmTitle: "保存"
            ) { name in
                engine.renameProfile(id: engine.activeProfile.id, newName: name)
            }
        }
        .confirmationDialog(
            "确认将当前预设「\(engine.activeProfile.name)」恢复为出厂默认？",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("恢复出厂默认（仅保留 Knob → AN 1/2 音量）", role: .destructive) {
                editingModifier = nil
                engine.resetActiveProfileToFactoryDefault()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("恢复后中央大旋钮控制硬件输出 AN 1/2 音量（开启 0.0 dB 保护锁），其余所有旋钮与按键绑定将清空。")
        }
    }

    // MARK: - Top Toolbar

    private var topToolbar: some View {
        HStack(spacing: 14) {
            // Left: Profile Switcher & CRUD Menu
            HStack(spacing: 8) {
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
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color(red: 0.34, green: 0.84, blue: 0.98))
                        Text(engine.activeProfile.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    Button {
                        copyFromCurrentOnCreate = false
                        profileDraftName = "预设 \(engine.configuration.profiles.count + 1)"
                        showingNewProfileSheet = true
                    } label: {
                        Label("新建默认预设…", systemImage: "plus")
                    }

                    Button {
                        copyFromCurrentOnCreate = true
                        profileDraftName = "\(engine.activeProfile.name) 副本"
                        showingNewProfileSheet = true
                    } label: {
                        Label("复制当前预设…", systemImage: "doc.on.doc")
                    }

                    Button {
                        profileDraftName = engine.activeProfile.name
                        showingRenameProfileSheet = true
                    } label: {
                        Label("重命名当前预设…", systemImage: "pencil")
                    }

                    Divider()

                    Button {
                        showingResetConfirmation = true
                    } label: {
                        Label("恢复出厂默认映射…", systemImage: "arrow.counterclockwise")
                    }

                    if engine.configuration.profiles.count > 1 {
                        Button(role: .destructive) {
                            engine.deleteProfile(id: engine.activeProfile.id)
                        } label: {
                            Label("删除当前预设", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("管理预设（新建 / 复制 / 重命名 / 恢复出厂默认）")
            }

            Spacer(minLength: 8)

            // Center: Tab Switcher
            HStack(spacing: 4) {
                ForEach(KeymapperTab.allCases) { tab in
                    let active = (selectedTab == tab)
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.systemIcon)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(tab.title)
                                .font(.system(size: 12, weight: active ? .semibold : .medium))
                        }
                        .foregroundStyle(active ? Color.white : Color.white.opacity(0.62))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Color(red: 0.20, green: 0.52, blue: 0.86).opacity(0.45) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    active ? Color(red: 0.36, green: 0.82, blue: 0.98).opacity(0.65) : Color.clear,
                                    lineWidth: 0.9
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.28))
            )

            Spacer(minLength: 8)

            // Right: Live Connection Status Badges
            HStack(spacing: 8) {
                connectionPill(
                    title: "TourBox",
                    isOnline: engine.tourBoxState.isConnected,
                    isWarning: isPortBusy(engine.tourBoxState)
                ) {
                    selectedTab = .diagnostics
                }

                connectionPill(
                    title: "TotalMix",
                    isOnline: engine.totalMix.isConnected,
                    isWarning: false
                ) {
                    selectedTab = .diagnostics
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.10, green: 0.11, blue: 0.14))
    }

    private func connectionPill(
        title: String,
        isOnline: Bool,
        isWarning: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(
                        isOnline
                            ? Color(red: 0.22, green: 0.88, blue: 0.52)
                            : (isWarning ? Color.orange : Color.white.opacity(0.30))
                    )
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.84))
            }
            .padding(.horizontal, 8.5)
            .padding(.vertical, 4.5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .help("点击查看连接与报文诊断")
    }

    private func isPortBusy(_ state: TourBoxConnectionState) -> Bool {
        if case .portBusy = state { return true }
        return false
    }

    // MARK: - Tab 1: Bindings Workbench (Left Canvas + Right Dual-Action Inspector)

    private var bindingsWorkbench: some View {
        HSplitView {
            leftCanvasColumn
                .frame(minWidth: 380, idealWidth: 430, maxWidth: 500)

            rightInspectorColumn
                .frame(minWidth: 440, maxWidth: .infinity)
        }
    }

    private var leftCanvasColumn: some View {
        let profile = engine.activeProfile
        let sortedModifiers = TourBoxButton.allCases.filter { profile.modifierButtons.contains($0) }
        let summaries = profile.allBindingSummaries(activeModifier: editingModifier) { bus, idx in
            engine.channelDisplayName(bus: bus, index: idx)
        }
        let modifierControlIds = Set(profile.modifierButtons.map(\.controlId))

        return VStack(spacing: 10) {
            // Layer Switcher Capsule Bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    layerCapsuleButton(
                        title: "基础层",
                        icon: "square.layers.3d.down.right",
                        isSelected: editingModifier == nil,
                        isPhysicallyHeld: engine.currentActiveModifier == nil && !engine.activePhysicalControls.isEmpty
                    ) {
                        editingModifier = nil
                    }

                    ForEach(sortedModifiers) { modButton in
                        layerCapsuleButton(
                            title: "按住 \(modButton.controlId.shortTitle) 组合层",
                            icon: "command.square.fill",
                            isSelected: editingModifier == modButton,
                            isPhysicallyHeld: engine.activeHardwareModifiers.contains(modButton)
                        ) {
                            editingModifier = modButton
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }

            // Vector Hardware Canvas
            TourBoxLiteCanvas(
                selectedControl: $selectedControl,
                activePhysicalControls: engine.activePhysicalControls,
                modifierControls: modifierControlIds,
                bindingSummaries: summaries
            )
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom Subtle Legend
            HStack(spacing: 12) {
                Label("点选任意部位编辑映射", systemImage: "hand.point.up.left.fill")
                Spacer()
                Label("转动或按压真机实时发光", systemImage: "bolt.horizontal.fill")
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.white.opacity(0.45))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
    }

    private func layerCapsuleButton(
        title: String,
        icon: String,
        isSelected: Bool,
        isPhysicallyHeld: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                if isPhysicallyHeld {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.75, blue: 0.25))
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.68))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isSelected
                            ? Color(red: 0.18, green: 0.58, blue: 0.88).opacity(0.42)
                            : Color.white.opacity(0.06)
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color(red: 0.36, green: 0.84, blue: 0.98).opacity(0.75)
                            : Color.white.opacity(0.10),
                        lineWidth: 0.85
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right Inspector Column

    private var rightInspectorColumn: some View {
        let profile = engine.activeProfile
        let button = selectedControl.buttonControl

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controlHeaderCard(profile: profile, button: button)

                if let activeMod = editingModifier, activeMod == button && !selectedControl.hasRotary {
                    // Self-modifier notice when editing that modifier's own combo layer
                    inspectorCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("当前正在编辑「按住 \(activeMod.displayName)」组合层", systemImage: "info.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(red: 0.34, green: 0.86, blue: 0.96))
                            Text("在此层级下按住 \(activeMod.displayName) 的同时旋转 Knob/Scroll 或点按其它按键即可触发组合动作。若需设置单独轻点 \(activeMod.displayName) 松开时的自身动作，请切回「基础层」。")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.68))
                            Button("切回基础层编辑自身单击动作") {
                                editingModifier = nil
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                } else if let rotary = selectedControl.rotaryControl {
                    // Dual-Action Cards side-by-side vertically for Knob & Scroll (#5 Minor-2)
                    rotaryActionCard(for: rotary, profile: profile)

                    if editingModifier != button {
                        buttonActionCard(
                            title: "\(button.displayName)（单击动作）",
                            subtitle: editingModifier == nil
                                ? "垂直按下编码器时触发（出厂默认留空）"
                                : "按住 \(editingModifier!.displayName) + \(button.displayName) 时触发",
                            currentAction: currentSingleButtonAction(for: button, in: profile),
                            onUpdate: { newAction in
                                engine.setButtonBinding(button, modifier: editingModifier, action: newAction)
                            }
                        )
                    }

                    if editingModifier == nil {
                        buttonActionCard(
                            title: "\(button.displayName) · 双击动作（可选）",
                            subtitle: "260 ms 内连续快速按压两次触发",
                            currentAction: profile.doublePressBindings[button] ?? .none,
                            onUpdate: { newAction in
                                engine.setDoublePressBinding(button, action: newAction)
                            }
                        )
                    }
                } else {
                    // Standalone Physical Button (Top, Tall, Short, C1, C2, Tour)
                    buttonActionCard(
                        title: editingModifier == nil
                            ? (profile.modifierButtons.contains(button)
                                ? "\(button.displayName) · 单击动作（松开触发）"
                                : "\(button.displayName) · 单击动作")
                            : "组合动作：按住 \(editingModifier!.displayName) + \(button.displayName)",
                        subtitle: editingModifier == nil
                            ? (profile.modifierButtons.contains(button)
                                ? "已开启硬件修饰键模式：按住期间若未触发任何组合动作，松开瞬间执行此单击动作"
                                : "按下瞬间零延迟触发（出厂默认留空）")
                            : "支持乱序松键成对释放保护",
                        currentAction: currentSingleButtonAction(for: button, in: profile),
                        onUpdate: { newAction in
                            engine.setButtonBinding(button, modifier: editingModifier, action: newAction)
                        }
                    )

                    if editingModifier == nil {
                        buttonActionCard(
                            title: "\(button.displayName) · 双击动作（可选）",
                            subtitle: "260 ms 内连续快速按压两次触发",
                            currentAction: profile.doublePressBindings[button] ?? .none,
                            onUpdate: { newAction in
                                engine.setDoublePressBinding(button, action: newAction)
                            }
                        )
                    }
                }
            }
            .padding(18)
        }
        .background(Color(red: 0.09, green: 0.10, blue: 0.13))
    }

    private func controlHeaderCard(profile: ProfileConfig, button: TourBoxButton) -> some View {
        let isStandaloneButton = !selectedControl.hasRotary
        let isModifier = profile.modifierButtons.contains(button)

        return inspectorCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(selectedControl.displayName)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color.white)

                            Text(editingModifier == nil ? "基础层" : "按住 \(editingModifier!.controlId.shortTitle) 组合层")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.36, green: 0.86, blue: 0.98))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color(red: 0.20, green: 0.62, blue: 0.92).opacity(0.22))
                                )
                        }

                        Text(selectedControl.locationDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.58))
                    }

                    Spacer()
                }

                if isStandaloneButton && editingModifier == nil {
                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    Toggle(
                        isOn: Binding(
                            get: { isModifier },
                            set: { enabled in
                                engine.setModifierButton(button, isModifier: enabled)
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("设为硬件组合修饰键 (Modifier)")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("开启后可按住此键配合 Knob / Scroll 或其它按键组成第二层快捷映射")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.52))
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
    }

    private func currentSingleButtonAction(for button: TourBoxButton, in profile: ProfileConfig) -> ButtonBindingAction {
        if let mod = editingModifier {
            let key = ControlStateMachine.ButtonComboKey(modifier: mod, targetButton: button)
            return profile.buttonComboBindings[key] ?? .none
        }
        return profile.buttonBindings[button] ?? .none
    }

    // MARK: - Rotary Action Editor Card

    private enum RotaryCategory: String, CaseIterable, Identifiable {
        case none = "未绑定（留空）"
        case rmeOutput = "RME 硬件输出通道音量"
        case rmeSubmix = "RME 子混音矩阵发送音量"
        case mouseScroll = "触控板双指滑动 / 鼠标滚轮"
        case systemVolume = "macOS 系统音量"
        case keyPair = "自定义正反转按键 / 快捷键"

        var id: String { rawValue }
    }

    private enum BallisticsPresetChoice: String, CaseIterable, Identifiable {
        case standard = "动态三级加速 · 标准 (慢拧 0.5 dB)"
        case fine = "动态三级加速 · 精细 (慢拧 0.2 dB)"
        case fixed = "固定恒定步进"

        var id: String { rawValue }
    }

    private func rotaryCategory(for action: RotaryBindingAction) -> RotaryCategory {
        switch action {
        case .none: return .none
        case .rmeOutputFader: return .rmeOutput
        case .rmeSubmixFader: return .rmeSubmix
        case .mouseScroll: return .mouseScroll
        case .systemVolume: return .systemVolume
        case .keyPair: return .keyPair
        }
    }

    private func ballisticsChoice(for config: RotaryBallisticsConfig) -> BallisticsPresetChoice {
        switch config.mode {
        case .fixed:
            return .fixed
        case .dynamic:
            return config.slowStepDb <= 0.25 ? .fine : .standard
        }
    }

    private func rotaryActionCard(for rotary: TourBoxRotary, profile: ProfileConfig) -> some View {
        let currentAction: RotaryBindingAction = {
            if let mod = editingModifier {
                let key = ControlStateMachine.RotaryComboKey(modifier: mod, rotary: rotary)
                return profile.rotaryComboBindings[key] ?? .none
            }
            return profile.rotaryBindings[rotary] ?? .none
        }()

        let selectedCategory = rotaryCategory(for: currentAction)

        return inspectorCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        editingModifier == nil
                            ? "\(rotary.displayName)（旋转动作）"
                            : "组合旋转：按住 \(editingModifier!.displayName) + \(rotary.displayName)",
                        systemImage: rotary == .knob ? "dial.medium.fill" : "arrow.up.and.down.circle.fill"
                    )
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(Color.white)

                    Spacer()

                    if !currentAction.isNone {
                        Button("清空为未绑定") {
                            engine.setRotaryBinding(rotary, modifier: editingModifier, action: .none)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                    }
                }

                Picker(
                    "动作类型",
                    selection: Binding<RotaryCategory>(
                        get: { selectedCategory },
                        set: { newCat in
                            let defaultAction: RotaryBindingAction = switch newCat {
                            case .none:
                                .none
                            case .rmeOutput:
                                .rmeOutputFader(channelIndex: 0, ballistics: .standard, safetyClamp0dB: true)
                            case .rmeSubmix:
                                .rmeSubmixFader(sourceBus: .playback, sourceIndex: 0, outputIndex: 0, ballistics: .standard, safetyClamp0dB: true)
                            case .mouseScroll:
                                .mouseScroll(.standard)
                            case .systemVolume:
                                .systemVolume
                            case .keyPair:
                                .keyPair(
                                    cw: KeyCombo(keyCode: 0x18, command: true),  // Cmd + =
                                    ccw: KeyCombo(keyCode: 0x1B, command: true)  // Cmd + -
                                )
                            }
                            engine.setRotaryBinding(rotary, modifier: editingModifier, action: defaultAction)
                        }
                    )
                ) {
                    ForEach(RotaryCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                .pickerStyle(.menu)

                switch currentAction {
                case .none:
                    Text("当前未绑定任何动作，旋转时不会发送指令。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.white.opacity(0.48))

                case .rmeOutputFader(let chIndex, let ballistics, let safetyClamp):
                    Divider().overlay(Color.white.opacity(0.08))
                    channelPickerRow(
                        label: "目标输出通道",
                        bus: .output,
                        selectedIndex: chIndex
                    ) { newCh in
                        engine.setRotaryBinding(
                            rotary,
                            modifier: editingModifier,
                            action: .rmeOutputFader(channelIndex: newCh, ballistics: ballistics, safetyClamp0dB: safetyClamp)
                        )
                    }

                    ballisticsEditorSection(config: ballistics) { updatedBallistics in
                        engine.setRotaryBinding(
                            rotary,
                            modifier: editingModifier,
                            action: .rmeOutputFader(channelIndex: chIndex, ballistics: updatedBallistics, safetyClamp0dB: safetyClamp)
                        )
                    }

                    Toggle(
                        "开启 0.0 dB 过载安全限位锁（防止顺时针快拧冲过 0 dB 爆音）",
                        isOn: Binding(
                            get: { safetyClamp },
                            set: { newClamp in
                                engine.setRotaryBinding(
                                    rotary,
                                    modifier: editingModifier,
                                    action: .rmeOutputFader(channelIndex: chIndex, ballistics: ballistics, safetyClamp0dB: newClamp)
                                )
                            }
                        )
                    )
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .controlSize(.small)

                case .rmeSubmixFader(let srcBus, let srcIdx, let outIdx, let ballistics, let safetyClamp):
                    Divider().overlay(Color.white.opacity(0.08))

                    Picker(
                        "音源总线",
                        selection: Binding<MixerBus>(
                            get: { srcBus },
                            set: { newBus in
                                engine.setRotaryBinding(
                                    rotary,
                                    modifier: editingModifier,
                                    action: .rmeSubmixFader(sourceBus: newBus, sourceIndex: 0, outputIndex: outIdx, ballistics: ballistics, safetyClamp0dB: safetyClamp)
                                )
                            }
                        )
                    ) {
                        Text(MixerBus.input.displayName).tag(MixerBus.input)
                        Text(MixerBus.playback.displayName).tag(MixerBus.playback)
                    }

                    channelPickerRow(label: "发送源通道", bus: srcBus, selectedIndex: srcIdx) { newSrc in
                        engine.setRotaryBinding(
                            rotary,
                            modifier: editingModifier,
                            action: .rmeSubmixFader(sourceBus: srcBus, sourceIndex: newSrc, outputIndex: outIdx, ballistics: ballistics, safetyClamp0dB: safetyClamp)
                        )
                    }

                    channelPickerRow(label: "发往硬件输出", bus: .output, selectedIndex: outIdx) { newOut in
                        engine.setRotaryBinding(
                            rotary,
                            modifier: editingModifier,
                            action: .rmeSubmixFader(sourceBus: srcBus, sourceIndex: srcIdx, outputIndex: newOut, ballistics: ballistics, safetyClamp0dB: safetyClamp)
                        )
                    }

                    ballisticsEditorSection(config: ballistics) { updatedBallistics in
                        engine.setRotaryBinding(
                            rotary,
                            modifier: editingModifier,
                            action: .rmeSubmixFader(sourceBus: srcBus, sourceIndex: srcIdx, outputIndex: outIdx, ballistics: updatedBallistics, safetyClamp0dB: safetyClamp)
                        )
                    }

                    Toggle(
                        "开启 0.0 dB 发送上限保护锁",
                        isOn: Binding(
                            get: { safetyClamp },
                            set: { newClamp in
                                engine.setRotaryBinding(
                                    rotary,
                                    modifier: editingModifier,
                                    action: .rmeSubmixFader(sourceBus: srcBus, sourceIndex: srcIdx, outputIndex: outIdx, ballistics: ballistics, safetyClamp0dB: newClamp)
                                )
                            }
                        )
                    )
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .controlSize(.small)

                case .mouseScroll(let scrollCfg):
                    Divider().overlay(Color.white.opacity(0.08))
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(
                            "滚动手感模式",
                            selection: Binding<MouseScrollConfig.Mode>(
                                get: { scrollCfg.mode },
                                set: { newMode in
                                    var updated = scrollCfg
                                    updated.mode = newMode
                                    engine.setRotaryBinding(rotary, modifier: editingModifier, action: .mouseScroll(updated))
                                }
                            )
                        ) {
                            ForEach(MouseScrollConfig.Mode.allCases) { item in
                                Text(item.displayName).tag(item)
                            }
                        }

                        Picker(
                            "滚动方向轴",
                            selection: Binding<MouseScrollConfig.Axis>(
                                get: { scrollCfg.axis },
                                set: { newAxis in
                                    var updated = scrollCfg
                                    updated.axis = newAxis
                                    engine.setRotaryBinding(rotary, modifier: editingModifier, action: .mouseScroll(updated))
                                }
                            )
                        ) {
                            ForEach(MouseScrollConfig.Axis.allCases) { item in
                                Text(item.displayName).tag(item)
                            }
                        }

                        HStack(spacing: 6) {
                            Text("每格步幅速度：")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.82))
                            ForEach([(1, "1 慢"), (2, "2 柔"), (3, "3 标准"), (4, "4 快"), (5, "5 极快")], id: \.0) { tier, label in
                                Button(label) {
                                    var updated = scrollCfg
                                    updated.speed = tier
                                    engine.setRotaryBinding(rotary, modifier: editingModifier, action: .mouseScroll(updated))
                                }
                                .buttonStyle(.bordered)
                                .tint(scrollCfg.speed == tier ? .accentColor : .secondary)
                                .controlSize(.small)
                            }
                        }

                        Toggle(
                            "快速连续拨动时自动惯性加速（长网页/长文档快速翻页）",
                            isOn: Binding(
                                get: { scrollCfg.dynamicAcceleration },
                                set: { val in
                                    var updated = scrollCfg
                                    updated.dynamicAcceleration = val
                                    engine.setRotaryBinding(rotary, modifier: editingModifier, action: .mouseScroll(updated))
                                }
                            )
                        )
                        .font(.system(size: 12))
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Toggle(
                            "反转上下滚动方向（适配个人「自然滚动」习惯）",
                            isOn: Binding(
                                get: { scrollCfg.invertDirection },
                                set: { val in
                                    var updated = scrollCfg
                                    updated.invertDirection = val
                                    engine.setRotaryBinding(rotary, modifier: editingModifier, action: .mouseScroll(updated))
                                }
                            )
                        )
                        .font(.system(size: 12))
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        Text("小提示：若想同时获得完整鼠标中键体验，可在下方「按压动作」卡片中选择「鼠标中键 / 左键 / 右键点击」。")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.55))

                        accessibilityPermissionBannerIfNeeded
                    }

                case .systemVolume:
                    Text("通过 macOS 原生媒体事件直接调节当前系统默认音频输出音量（无需辅助功能权限）。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.white.opacity(0.60))

                case .keyPair(let cw, let ccw):
                    Divider().overlay(Color.white.opacity(0.08))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(rotary.directionDisplayName(.cw))
                                .font(.system(size: 12))
                                .frame(width: 128, alignment: .leading)
                            ShortcutRecorderView(combo: cw) { updated in
                                if let updated {
                                    engine.setRotaryBinding(rotary, modifier: editingModifier, action: .keyPair(cw: updated, ccw: ccw))
                                }
                            }
                        }

                        HStack {
                            Text(rotary.directionDisplayName(.ccw))
                                .font(.system(size: 12))
                                .frame(width: 128, alignment: .leading)
                            ShortcutRecorderView(combo: ccw) { updated in
                                if let updated {
                                    engine.setRotaryBinding(rotary, modifier: editingModifier, action: .keyPair(cw: cw, ccw: updated))
                                }
                            }
                        }

                        accessibilityPermissionBannerIfNeeded
                    }
                }
            }
        }
    }

    private func ballisticsEditorSection(
        config: RotaryBallisticsConfig,
        onChange: @escaping (RotaryBallisticsConfig) -> Void
    ) -> some View {
        let choice = ballisticsChoice(for: config)
        let fixedValue: Double = {
            if case .fixed(let db) = config.mode { return db }
            return 0.5
        }()

        return VStack(alignment: .leading, spacing: 8) {
            Picker(
                "旋转手感与步进",
                selection: Binding<BallisticsPresetChoice>(
                    get: { choice },
                    set: { newChoice in
                        switch newChoice {
                        case .standard: onChange(.standard)
                        case .fine: onChange(.fine)
                        case .fixed: onChange(.fixed(db: 0.5))
                        }
                    }
                )
            ) {
                ForEach(BallisticsPresetChoice.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }

            if case .fixed = config.mode {
                HStack(spacing: 8) {
                    Text("每格固定步进：")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.75))
                    ForEach([0.2, 0.5, 1.0, 2.0], id: \.self) { step in
                        let selected = abs(fixedValue - step) < 0.01
                        Button(String(format: "%.1f dB", step)) {
                            onChange(.fixed(db: step))
                        }
                        .buttonStyle(.bordered)
                        .tint(selected ? .accentColor : .secondary)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Button Action Editor Card

    private enum ButtonCategory: String, CaseIterable, Identifiable {
        case none = "未绑定（留空）"
        case rmeOutputMute = "RME 指定输出通道静音"
        case rmeSetOutputDb = "RME 一键跳转指定分贝值"
        case rmeChannelMute = "RME 输入 / 回放通道静音"
        case rmeControlRoom = "RME 监听室开关 (Main Out)"
        case rmeSnapshot = "RME 快照调用 (Snapshot 1..8)"
        case rmeLayout = "RME 布局调用 (Layout 1..6)"
        case rmeToggleWindow = "显示 / 隐藏 TotalMix 窗口"
        case keyShortcut = "电脑键盘按键 / 快捷键"
        case mouseClick = "鼠标中键 / 左键 / 右键点击"
        case mediaKey = "系统媒体键 (播放 / 切歌 / 音量)"
        case cycleProfile = "切换下一套预设"
        case openKeymapper = "打开 TourMix 控制台窗口"
        case shellCommand = "执行 Shell 脚本命令"
        case appleScript = "执行 AppleScript"

        var id: String { rawValue }
    }

    private func buttonCategory(for action: ButtonBindingAction) -> ButtonCategory {
        switch action {
        case .none: return .none
        case .rmeOutputMute: return .rmeOutputMute
        case .rmeSetOutputDb: return .rmeSetOutputDb
        case .rmeChannelMute: return .rmeChannelMute
        case .rmeControlRoom: return .rmeControlRoom
        case .rmeSnapshot: return .rmeSnapshot
        case .rmeLayout: return .rmeLayout
        case .rmeToggleWindow: return .rmeToggleWindow
        case .keyShortcut: return .keyShortcut
        case .mouseClick: return .mouseClick
        case .mediaKey: return .mediaKey
        case .cycleProfile: return .cycleProfile
        case .openKeymapper: return .openKeymapper
        case .shellCommand: return .shellCommand
        case .appleScript: return .appleScript
        }
    }

    private func buttonActionCard(
        title: String,
        subtitle: String,
        currentAction: ButtonBindingAction,
        onUpdate: @escaping (ButtonBindingAction) -> Void
    ) -> some View {
        let category = buttonCategory(for: currentAction)

        return inspectorCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(Color.white)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.52))
                    }

                    Spacer()

                    if !currentAction.isNone {
                        Button("清空") {
                            onUpdate(.none)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                    }
                }

                Picker(
                    "动作类型",
                    selection: Binding<ButtonCategory>(
                        get: { category },
                        set: { newCat in
                            let fallback: ButtonBindingAction = switch newCat {
                            case .none: .none
                            case .rmeOutputMute: .rmeOutputMute(channelIndex: 0)
                            case .rmeSetOutputDb: .rmeSetOutputDb(channelIndex: 0, targetDb: -20.0)
                            case .rmeChannelMute: .rmeChannelMute(bus: .input, channelIndex: 0)
                            case .rmeControlRoom: .rmeControlRoom(.dim)
                            case .rmeSnapshot: .rmeSnapshot(1)
                            case .rmeLayout: .rmeLayout(1)
                            case .rmeToggleWindow: .rmeToggleWindow
                            case .keyShortcut: .keyShortcut(KeyCombo(keyCode: 0x06, command: true)) // Cmd+Z
                            case .mouseClick: .mouseClick(.middle)
                            case .mediaKey: .mediaKey(.playPause)
                            case .cycleProfile: .cycleProfile
                            case .openKeymapper: .openKeymapper
                            case .shellCommand: .shellCommand("")
                            case .appleScript: .appleScript("")
                            }
                            onUpdate(fallback)
                        }
                    )
                ) {
                    ForEach(ButtonCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                .pickerStyle(.menu)

                buttonActionDetailEditor(action: currentAction, onUpdate: onUpdate)
            }
        }
    }

    @ViewBuilder
    private func buttonActionDetailEditor(
        action: ButtonBindingAction,
        onUpdate: @escaping (ButtonBindingAction) -> Void
    ) -> some View {
        switch action {
        case .none:
            EmptyView()

        case .rmeOutputMute(let chIndex):
            Divider().overlay(Color.white.opacity(0.08))
            channelPickerRow(label: "静音输出通道", bus: .output, selectedIndex: chIndex) { newCh in
                onUpdate(.rmeOutputMute(channelIndex: newCh))
            }
            Text("发送单通道独立静音 `/output/\(chIndex)/mute`（不影响其它硬件输出）。")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.52))

        case .rmeSetOutputDb(let chIndex, let targetDb):
            Divider().overlay(Color.white.opacity(0.08))
            channelPickerRow(label: "目标输出通道", bus: .output, selectedIndex: chIndex) { newCh in
                onUpdate(.rmeSetOutputDb(channelIndex: newCh, targetDb: targetDb))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("目标分贝值：")
                        .font(.system(size: 12))
                    Text(RMEFaderCurve.formatDb(targetDb))
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(red: 0.36, green: 0.86, blue: 0.98))
                    Spacer()
                }

                HStack(spacing: 6) {
                    ForEach([-65.0, -30.0, -20.0, -12.0, -6.0, 0.0], id: \.self) { preset in
                        Button(preset <= -65.0 ? "-∞" : String(format: "%.0f dB", preset)) {
                            onUpdate(.rmeSetOutputDb(channelIndex: chIndex, targetDb: preset))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                Slider(
                    value: Binding(
                        get: { targetDb },
                        set: { val in
                            let rounded = (val * 2.0).rounded() / 2.0
                            onUpdate(.rmeSetOutputDb(channelIndex: chIndex, targetDb: rounded))
                        }
                    ),
                    in: -65.0...6.0
                )
            }

        case .rmeChannelMute(let bus, let chIndex):
            Divider().overlay(Color.white.opacity(0.08))
            Picker(
                "通道总线",
                selection: Binding<MixerBus>(
                    get: { bus },
                    set: { newBus in
                        onUpdate(.rmeChannelMute(bus: newBus, channelIndex: 0))
                    }
                )
            ) {
                ForEach(MixerBus.allCases, id: \.self) { b in
                    Text(b.displayName).tag(b)
                }
            }

            channelPickerRow(label: "目标通道", bus: bus, selectedIndex: chIndex) { newCh in
                onUpdate(.rmeChannelMute(bus: bus, channelIndex: newCh))
            }

        case .rmeControlRoom(let fn):
            Divider().overlay(Color.white.opacity(0.08))
            Picker(
                "监听室功能",
                selection: Binding<ControlRoomFunction>(
                    get: { fn },
                    set: { onUpdate(.rmeControlRoom($0)) }
                )
            ) {
                ForEach(ControlRoomFunction.allCases, id: \.self) { item in
                    Text(item.displayName).tag(item)
                }
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "speaker.wave.2.bubble.left.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                Text("作用于 TotalMix Control Room 的 Main Out（当前为 \(engine.totalMix.mainOutDisplayName)）。若需单独静音 AN 1/2 等指定输出，请选择「RME 指定输出通道静音」。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.62))
            }

        case .rmeSnapshot(let slot):
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 6) {
                Text("快照槽位：")
                    .font(.system(size: 12))
                ForEach(1...8, id: \.self) { idx in
                    Button("\(idx)") {
                        onUpdate(.rmeSnapshot(idx))
                    }
                    .buttonStyle(.bordered)
                    .tint(slot == idx ? .accentColor : .secondary)
                    .controlSize(.small)
                }
            }

        case .rmeLayout(let preset):
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 6) {
                Text("布局预设：")
                    .font(.system(size: 12))
                ForEach(1...6, id: \.self) { idx in
                    Button("\(idx)") {
                        onUpdate(.rmeLayout(idx))
                    }
                    .buttonStyle(.bordered)
                    .tint(preset == idx ? .accentColor : .secondary)
                    .controlSize(.small)
                }
            }

        case .rmeToggleWindow:
            Text("一键在前台唤出或隐藏 RME TotalMix FX 混音窗口（`/showwindow`）。")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.58))

        case .keyShortcut(let combo):
            Divider().overlay(Color.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("绑定按键：")
                        .font(.system(size: 12))
                    ShortcutRecorderView(combo: combo) { newCombo in
                        if let newCombo {
                            onUpdate(.keyShortcut(newCombo))
                        } else {
                            onUpdate(.none)
                        }
                    }
                }
                Text("支持直接录入任意单个按键（如 Space、B、Delete、Esc、方向键）、单独修饰键（点按一下 Shift / Option / Command 即可绑定按住生效）或组合快捷键，也可点右侧键盘菜单直接点选。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                accessibilityPermissionBannerIfNeeded
            }

        case .mouseClick(let mouseBtn):
            Divider().overlay(Color.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    "鼠标按键",
                    selection: Binding<MouseClickButton>(
                        get: { mouseBtn },
                        set: { onUpdate(.mouseClick($0)) }
                    )
                ) {
                    ForEach(MouseClickButton.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                Text("支持单击与按住持续生效（例如将 Scroll 按压设为「鼠标中键」，既能单击关闭网页标签/后台打开链接，也能按住滚轮在 DAW / Figma / 3D 软件中拖拽平移画布）。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                accessibilityPermissionBannerIfNeeded
            }

        case .mediaKey(let media):
            Divider().overlay(Color.white.opacity(0.08))
            Picker(
                "媒体功能",
                selection: Binding<MediaKeyAction>(
                    get: { media },
                    set: { onUpdate(.mediaKey($0)) }
                )
            ) {
                ForEach(MediaKeyAction.allCases) { item in
                    Label(item.displayName, systemImage: item.systemIcon).tag(item)
                }
            }

        case .cycleProfile:
            Text("在已创建的 \(engine.configuration.profiles.count) 套预设之间循环切换，并在屏幕弹出 HUD 提示。")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.58))

        case .openKeymapper:
            Text("一键打开并置顶本 TourMix 控制台窗口。")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.58))

        case .shellCommand(let cmd):
            Divider().overlay(Color.white.opacity(0.08))
            scriptEditorSection(
                placeholder: "例如: open -a 'Totalmix'",
                text: cmd,
                onTextChange: { onUpdate(.shellCommand($0)) },
                onTestRun: {
                    Task {
                        let res = await engine.actionExecutor.runShellCommand(cmd)
                        scriptTestStatus = res.succeeded ? "执行成功" : (res.errorMessage ?? "执行失败")
                    }
                }
            )

        case .appleScript(let source):
            Divider().overlay(Color.white.opacity(0.08))
            scriptEditorSection(
                placeholder: "例如: tell application \"Music\" to playpause",
                text: source,
                onTextChange: { onUpdate(.appleScript($0)) },
                onTestRun: {
                    Task {
                        let res = await engine.actionExecutor.runAppleScript(source)
                        scriptTestStatus = res.succeeded ? "执行成功" : (res.errorMessage ?? "执行失败")
                    }
                }
            )
        }
    }

    private func channelPickerRow(
        label: String,
        bus: MixerBus,
        selectedIndex: Int,
        onSelect: @escaping (Int) -> Void
    ) -> some View {
        let channels: [MixerChannelState] = {
            let visible: [MixerChannelState] = switch bus {
            case .input: engine.totalMix.visibleInputChannels
            case .playback: engine.totalMix.visiblePlaybackChannels
            case .output: engine.totalMix.visibleOutputChannels
            }
            if visible.contains(where: { $0.index == selectedIndex }) {
                return visible
            }
            let fallbackName = engine.channelDisplayName(bus: bus, index: selectedIndex)
            var copy = visible
            copy.append(MixerChannelState(index: selectedIndex, bus: bus, displayName: fallbackName))
            return copy.sorted { $0.index < $1.index }
        }()

        return Picker(
            label,
            selection: Binding<Int>(
                get: { selectedIndex },
                set: { onSelect($0) }
            )
        ) {
            ForEach(channels) { ch in
                Text("\(ch.displayName)  (#\(ch.index + 1))").tag(ch.index)
            }
        }
    }

    @ViewBuilder
    private var accessibilityPermissionBannerIfNeeded: some View {
        if !engine.actionExecutor.isAccessibilityTrusted(prompt: false) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
                Text("发送键盘快捷键需在系统设置中勾选「辅助功能」权限（仅控 RME 无需此权限）。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.78))
                Spacer()
                Button("请求授权") {
                    _ = engine.actionExecutor.isAccessibilityTrusted(prompt: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)

                Button("打开设置") {
                    engine.actionExecutor.openAccessibilitySettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
        }
    }

    private func scriptEditorSection(
        placeholder: String,
        text: String,
        onTextChange: @escaping @MainActor (String) -> Void,
        onTestRun: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                placeholder,
                text: Binding(get: { text }, set: { onTextChange($0) }),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11.5, design: .monospaced))
            .lineLimit(2...5)

            HStack {
                Button("测试运行", action: onTestRun)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                if let status = scriptTestStatus {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
            }
        }
    }

    // MARK: - Tab 2: Global Preferences Workbench

    private var preferencesWorkbench: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. HUD & MenuBar Display
                inspectorCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("视觉反馈与菜单栏显示", systemImage: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 14, weight: .bold))

                        Toggle(
                            isOn: Binding(
                                get: { engine.configuration.showHUD },
                                set: { engine.setShowHUD($0) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("启用无焦点毛玻璃音量 HUD")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text("转动旋钮或静音时在当前光标所在屏幕底部浮现音量条，穿透全屏 DAW / 视频且绝不抢夺焦点")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                        }
                        .toggleStyle(.switch)

                        Divider().overlay(Color.white.opacity(0.08))

                        Toggle(
                            isOn: Binding(
                                get: { engine.configuration.showDbInMenuBar },
                                set: { engine.setShowDbInMenuBar($0) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("在菜单栏图标旁实时显示主控通道分贝读数")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text("采用等宽数字字体零抖动展示当前预设主通道（如 AN 1/2）实时音量")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }

                // 2. Frontmost App Auto-Switch
                inspectorCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("按前台应用自动切换预设", systemImage: "app.badge.checkmark.fill")
                            .font(.system(size: 14, weight: .bold))

                        Toggle(
                            "当关联应用切至前台时自动激活对应预设",
                            isOn: Binding(
                                get: { engine.configuration.autoSwitchByFrontmostApp },
                                set: { engine.setAutoSwitchByFrontmostApp($0) }
                            )
                        )
                        .font(.system(size: 12.5, weight: .semibold))
                        .toggleStyle(.switch)

                        Divider().overlay(Color.white.opacity(0.08))

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(engine.configuration.profiles) { profile in
                                HStack(spacing: 10) {
                                    Text(profile.name)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .frame(width: 160, alignment: .leading)
                                        .lineLimit(1)

                                    TextField(
                                        "未关联（例如 com.apple.logic10）",
                                        text: Binding(
                                            get: { profile.associatedBundleIdentifier ?? "" },
                                            set: { engine.setProfileBundleIdentifier(id: profile.id, bundleIdentifier: $0) }
                                        )
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))

                                    Menu("拾取运行中应用") {
                                        let runningApps = NSWorkspace.shared.runningApplications.filter {
                                            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                                        }
                                        ForEach(runningApps, id: \.processIdentifier) { app in
                                            if let bid = app.bundleIdentifier {
                                                Button("\(app.localizedName ?? bid) (\(bid))") {
                                                    engine.setProfileBundleIdentifier(id: profile.id, bundleIdentifier: bid)
                                                }
                                            }
                                        }
                                        if profile.associatedBundleIdentifier != nil {
                                            Divider()
                                            Button("清除关联") {
                                                engine.setProfileBundleIdentifier(id: profile.id, bundleIdentifier: nil)
                                            }
                                        }
                                    }
                                    .controlSize(.small)
                                    .fixedSize()
                                }
                            }
                        }
                    }
                }

                // 3. Installation & Launch at Login
                inspectorCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("安装位置与开机自启", systemImage: "power.circle.fill")
                            .font(.system(size: 14, weight: .bold))

                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("当前运行路径")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(launchManager.currentBundlePath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.58))
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if !launchManager.isRunningFromApplications {
                                Button("一键安装至 /Applications") {
                                    _ = launchManager.installToApplications(relaunch: false)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else {
                                Label("已位于 Applications", systemImage: "checkmark.seal.fill")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.24, green: 0.88, blue: 0.54))
                            }
                        }

                        Divider().overlay(Color.white.opacity(0.08))

                        Toggle(
                            isOn: Binding(
                                get: { launchManager.isEnabled },
                                set: { launchManager.setEnabled($0) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("登录 macOS 时自动后台启动 TourMix")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text("基于 ~/Library/LaunchAgents/com.soundlab.tourmix.plist 持久化，升级覆盖应用后依然稳定生效")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                        }
                        .toggleStyle(.switch)

                        if let err = launchManager.lastError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.red)
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Shared Card & Sheet Builders

    private func inspectorCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.85)
            )
    }

    private func profileNameSheet(
        title: String,
        prompt: String,
        confirmTitle: String,
        onConfirm: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .bold))

            TextField(prompt, text: $profileDraftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit {
                    onConfirm(profileDraftName)
                    showingNewProfileSheet = false
                    showingRenameProfileSheet = false
                }

            HStack {
                Spacer()
                Button("取消") {
                    showingNewProfileSheet = false
                    showingRenameProfileSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button(confirmTitle) {
                    onConfirm(profileDraftName)
                    showingNewProfileSheet = false
                    showingRenameProfileSheet = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
