import Foundation

/// `ControlStateMachine` 解析后的高层语义动作触发事件。
public enum ResolvedControlTrigger: Equatable, Sendable {
    /// 普通按键或「修饰键 + 目标键」按下（普通无双击按键零延迟触发）
    case buttonDown(button: TourBoxButton, modifier: TourBoxButton?)
    /// 普通按键或「修饰键 + 目标键」释放（即使先松修饰键再松目标键，仍携带按下时的 `originalModifier`）
    case buttonUp(button: TourBoxButton, modifier: TourBoxButton?)
    /// 被设为修饰键的按钮在按住期间未触发任何组合动作（`comboUsed == false`），于松开瞬间触发其自身单击动作
    case buttonTapOnRelease(button: TourBoxButton)
    /// 绑定了双击动作的按钮在 `doubleClickWindowSec` 窗口内完成第二次按下时触发
    case buttonDoublePress(button: TourBoxButton)
    /// 旋钮/滚轮有效步进旋转（严格忽略 `.rotaryStop` 停止码！）
    case rotaryTurn(
        rotary: TourBoxRotary,
        direction: RotaryDirection,
        modifier: TourBoxButton?,
        timestamp: TimeInterval
    )
}

/// 纯逻辑、确定性可单元测试的 TourBox 按键、硬件修饰键、双击与乱序释放跟踪状态机。
public struct ControlStateMachine: Sendable {
    public struct ButtonComboKey: Hashable, Codable, Sendable {
        public let modifier: TourBoxButton
        public let targetButton: TourBoxButton

        public init(modifier: TourBoxButton, targetButton: TourBoxButton) {
            self.modifier = modifier
            self.targetButton = targetButton
        }
    }

    public struct RotaryComboKey: Hashable, Codable, Sendable {
        public let modifier: TourBoxButton
        public let rotary: TourBoxRotary

        public init(modifier: TourBoxButton, rotary: TourBoxRotary) {
            self.modifier = modifier
            self.rotary = rotary
        }
    }

    private static let timeEpsilon: TimeInterval = 1e-6

    /// 被配置为硬件修饰键的按钮集合
    public var modifierButtons: Set<TourBoxButton>
    /// 配置了双击动作的按钮集合
    public var doublePressButtons: Set<TourBoxButton>
    /// 双击判定时间窗口（默认 `0.26 s`）
    public var doubleClickWindowSec: TimeInterval
    /// 静态表：已绑定有效动作的「修饰键 + 目标按钮」集合
    public var buttonCombos: Set<ButtonComboKey>
    /// 静态表：已绑定有效动作的「修饰键 + 旋钮/滚轮」集合
    public var rotaryCombos: Set<RotaryComboKey>

    private var buttonComboQuery: (@Sendable (TourBoxButton, TourBoxButton) -> Bool)?
    private var rotaryComboQuery: (@Sendable (TourBoxButton, TourBoxRotary) -> Bool)?

    // MARK: - Runtime Tracking State

    /// 当前按住的硬件修饰键栈（按按下先后排序）
    public private(set) var activeModifiers: [TourBoxButton] = []
    /// 当前按住期间已实际触发过至少一次组合动作的修饰键集合
    public private(set) var comboUsedModifiers: Set<TourBoxButton> = []
    /// 持续型组合键归属表：`activeCombos[targetButton] = originalModifier`（保障乱序松键成对释放）
    public private(set) var activeCombos: [TourBoxButton: TourBoxButton] = [:]
    /// 当前处于按下态的普通单键集合
    public private(set) var activePlainButtons: Set<TourBoxButton> = []

    /// 等待双击窗口确认的首次按下记录：`button -> (pressTimestamp, isReleased)`
    private var pendingDoublePresses: [TourBoxButton: PendingTapState] = [:]
    /// 双击成立后用于吞掉第二次松开事件的集合
    private var swallowNextReleaseButtons: Set<TourBoxButton> = []

    private struct PendingTapState: Equatable, Sendable {
        var firstPressTime: TimeInterval
        var hasReleasedFirstTap: Bool
    }

    public init(
        modifierButtons: Set<TourBoxButton> = [],
        doublePressButtons: Set<TourBoxButton> = [],
        doubleClickWindowSec: TimeInterval = 0.26,
        buttonCombos: Set<ButtonComboKey> = [],
        rotaryCombos: Set<RotaryComboKey> = [],
        hasButtonCombo: (@Sendable (TourBoxButton, TourBoxButton) -> Bool)? = nil,
        hasRotaryCombo: (@Sendable (TourBoxButton, TourBoxRotary) -> Bool)? = nil
    ) {
        self.modifierButtons = modifierButtons
        self.doublePressButtons = doublePressButtons
        self.doubleClickWindowSec = doubleClickWindowSec
        self.buttonCombos = buttonCombos
        self.rotaryCombos = rotaryCombos
        self.buttonComboQuery = hasButtonCombo
        self.rotaryComboQuery = hasRotaryCombo
    }

    /// 动态热更新当前预设的修饰键、双击与组合键查询规则（保留或按需安全衔接当前状态）。
    public mutating func updateConfiguration(
        modifierButtons: Set<TourBoxButton>,
        doublePressButtons: Set<TourBoxButton> = [],
        doubleClickWindowSec: TimeInterval = 0.26,
        buttonCombos: Set<ButtonComboKey> = [],
        rotaryCombos: Set<RotaryComboKey> = [],
        hasButtonCombo: (@Sendable (TourBoxButton, TourBoxButton) -> Bool)? = nil,
        hasRotaryCombo: (@Sendable (TourBoxButton, TourBoxRotary) -> Bool)? = nil
    ) {
        self.modifierButtons = modifierButtons
        self.doublePressButtons = doublePressButtons
        self.doubleClickWindowSec = doubleClickWindowSec
        self.buttonCombos = buttonCombos
        self.rotaryCombos = rotaryCombos
        self.buttonComboQuery = hasButtonCombo
        self.rotaryComboQuery = hasRotaryCombo
    }

    /// 最近一个双击超时待结算截止时间（若无挂起双击则返回 `nil`）。
    public var nextPendingDeadline: TimeInterval? {
        pendingDoublePresses.values
            .map { $0.firstPressTime + doubleClickWindowSec }
            .min()
    }

    /// 推进时钟以结算已超过 `doubleClickWindowSec` 的单击回退事件。
    public mutating func advanceTime(now: TimeInterval) -> [ResolvedControlTrigger] {
        guard !pendingDoublePresses.isEmpty else { return [] }
        var triggers: [ResolvedControlTrigger] = []

        for button in TourBoxButton.allCases {
            guard let pending = pendingDoublePresses[button] else { continue }
            if now + Self.timeEpsilon >= pending.firstPressTime + doubleClickWindowSec {
                pendingDoublePresses.removeValue(forKey: button)
                if modifierButtons.contains(button) {
                    if pending.hasReleasedFirstTap {
                        triggers.append(.buttonTapOnRelease(button: button))
                    }
                } else if pending.hasReleasedFirstTap {
                    triggers.append(.buttonDown(button: button, modifier: nil))
                    triggers.append(.buttonUp(button: button, modifier: nil))
                } else {
                    activePlainButtons.insert(button)
                    triggers.append(.buttonDown(button: button, modifier: nil))
                }
            }
        }
        return triggers
    }

    /// 处理单个已解码的 TourBox 硬件字节事件，返回 0..N 个高层语义触发器。
    public mutating func process(
        _ decoded: TourBoxDecodedByte,
        timestamp: TimeInterval
    ) -> [ResolvedControlTrigger] {
        var triggers = advanceTime(now: timestamp)

        switch decoded {
        case .rotaryStop:
            // 关键规则：0xC4/0x84/0xC9/0x89 停止码严格忽略，既不产出步进也不污染修饰键 comboUsed！
            return triggers

        case .rotaryStep(let rotary, let direction):
            if let mod = matchingHeldModifier(forRotary: rotary) {
                comboUsedModifiers.insert(mod)
                triggers.append(
                    .rotaryTurn(rotary: rotary, direction: direction, modifier: mod, timestamp: timestamp)
                )
            } else {
                triggers.append(
                    .rotaryTurn(rotary: rotary, direction: direction, modifier: nil, timestamp: timestamp)
                )
            }
            return triggers

        case .buttonPress(let button):
            handleButtonPress(button, timestamp: timestamp, into: &triggers)
            return triggers

        case .buttonRelease(let button):
            handleButtonRelease(button, timestamp: timestamp, into: &triggers)
            return triggers
        }
    }

    /// 在断连、系统休眠或 40ms 污染隔离重置时调用：成对释放所有尚未松开的组合键与普通按键，绝不残留卡键。
    public mutating func reset() -> [ResolvedControlTrigger] {
        var releases: [ResolvedControlTrigger] = []

        // 按固定枚举顺序释放所有未松开的持续型组合键
        for button in TourBoxButton.allCases {
            if let originalModifier = activeCombos[button] {
                releases.append(.buttonUp(button: button, modifier: originalModifier))
            }
        }

        // 按固定枚举顺序释放所有未松开的普通单键
        for button in TourBoxButton.allCases where activePlainButtons.contains(button) {
            releases.append(.buttonUp(button: button, modifier: nil))
        }

        activeCombos.removeAll()
        activePlainButtons.removeAll()
        activeModifiers.removeAll()
        comboUsedModifiers.removeAll()
        pendingDoublePresses.removeAll()
        swallowNextReleaseButtons.removeAll()

        return releases
    }

    // MARK: - Internal Helpers

    private mutating func handleButtonPress(
        _ button: TourBoxButton,
        timestamp: TimeInterval,
        into triggers: inout [ResolvedControlTrigger]
    ) {
        swallowNextReleaseButtons.remove(button)

        // 1. 若当前有其它修饰键按住，且 (modifier, button) 存在有效组合绑定，优先作为组合目标键触发！
        if let mod = matchingHeldModifier(forTargetButton: button) {
            guard activeCombos[button] == nil else { return }
            activeCombos[button] = mod
            comboUsedModifiers.insert(mod)
            triggers.append(.buttonDown(button: button, modifier: mod))
            return
        }

        // 2. 若该键当前挂起了第一次点击（处于双击等待窗口内），第二次按下直接命中双击！
        if let pending = pendingDoublePresses[button],
           timestamp - pending.firstPressTime <= doubleClickWindowSec + Self.timeEpsilon {
            pendingDoublePresses.removeValue(forKey: button)
            swallowNextReleaseButtons.insert(button)
            activeModifiers.removeAll { $0 == button }
            comboUsedModifiers.remove(button)
            triggers.append(.buttonDoublePress(button: button))
            return
        }

        // 3. 若该键被配置为硬件修饰键：按下时不立即触发单击，仅压入修饰键栈等待后续组合或松开
        if modifierButtons.contains(button) {
            if !activeModifiers.contains(button) {
                activeModifiers.append(button)
            }
            comboUsedModifiers.remove(button)
            return
        }

        // 4. 普通按键但配置了双击动作：挂起等待双击窗口
        if doublePressButtons.contains(button) {
            pendingDoublePresses[button] = PendingTapState(
                firstPressTime: timestamp,
                hasReleasedFirstTap: false
            )
            return
        }

        // 5. 普通无双击按键：按下瞬间零延迟触发 .buttonDown
        guard !activePlainButtons.contains(button), activeCombos[button] == nil else { return }
        activePlainButtons.insert(button)
        triggers.append(.buttonDown(button: button, modifier: nil))
    }

    private mutating func handleButtonRelease(
        _ button: TourBoxButton,
        timestamp: TimeInterval,
        into triggers: inout [ResolvedControlTrigger]
    ) {
        if swallowNextReleaseButtons.remove(button) != nil {
            return
        }

        // 1. 优先检查持续型组合键归属表（即使修饰键已提前松开，也能准确释放 originalModifier 组合！）
        if let originalModifier = activeCombos.removeValue(forKey: button) {
            triggers.append(.buttonUp(button: button, modifier: originalModifier))
            return
        }

        // 2. 若该键是正在按住的硬件修饰键
        if let idx = activeModifiers.firstIndex(of: button) {
            activeModifiers.remove(at: idx)
            let wasUsedInCombo = comboUsedModifiers.remove(button) != nil
            guard !wasUsedInCombo else {
                return
            }
            if doublePressButtons.contains(button) {
                pendingDoublePresses[button] = PendingTapState(
                    firstPressTime: timestamp,
                    hasReleasedFirstTap: true
                )
            } else {
                triggers.append(.buttonTapOnRelease(button: button))
            }
            return
        }

        // 3. 若该键正处于双击窗口首次点击期间被松开，记录已释放并继续等待窗口期满或第二次点击
        if var pending = pendingDoublePresses[button] {
            pending.hasReleasedFirstTap = true
            pendingDoublePresses[button] = pending
            return
        }

        // 4. 普通按键释放
        if activePlainButtons.remove(button) != nil {
            triggers.append(.buttonUp(button: button, modifier: nil))
        }
    }

    private func matchingHeldModifier(forTargetButton target: TourBoxButton) -> TourBoxButton? {
        activeModifiers.last { mod in
            mod != target && isValidButtonCombo(modifier: mod, targetButton: target)
        }
    }

    private func matchingHeldModifier(forRotary rotary: TourBoxRotary) -> TourBoxButton? {
        activeModifiers.last { mod in
            isValidRotaryCombo(modifier: mod, rotary: rotary)
        }
    }

    private func isValidButtonCombo(modifier: TourBoxButton, targetButton: TourBoxButton) -> Bool {
        if let query = buttonComboQuery {
            return query(modifier, targetButton)
        }
        return buttonCombos.contains(ButtonComboKey(modifier: modifier, targetButton: targetButton))
    }

    private func isValidRotaryCombo(modifier: TourBoxButton, rotary: TourBoxRotary) -> Bool {
        if let query = rotaryComboQuery {
            return query(modifier, rotary)
        }
        return rotaryCombos.contains(RotaryComboKey(modifier: modifier, rotary: rotary))
    }
}
