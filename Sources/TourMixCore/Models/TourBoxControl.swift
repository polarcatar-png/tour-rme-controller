import Foundation

/// TourBox Lite 机身上的 8 个物理交互控件区域。
public enum TourBoxControlId: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case knob
    case scroll
    case top
    case tall
    case short
    case c1
    case c2
    case tour

    public var id: String { rawValue }

    /// 简短英文标识（用于紧凑徽章显示）
    public var shortTitle: String {
        switch self {
        case .knob: return "Knob"
        case .scroll: return "Scroll"
        case .top: return "Top"
        case .tall: return "Tall"
        case .short: return "Short"
        case .c1: return "C1"
        case .c2: return "C2"
        case .tour: return "Tour"
        }
    }

    /// 中文显示名称
    public var displayName: String {
        switch self {
        case .knob: return "中央大旋钮 (Knob)"
        case .scroll: return "左侧滚轮 (Scroll)"
        case .top: return "顶部横键 (Top)"
        case .tall: return "竖向长键 (Tall)"
        case .short: return "右下短键 (Short)"
        case .c1: return "C1 圆键"
        case .c2: return "C2 圆键"
        case .tour: return "Tour 月牙键"
        }
    }

    /// 机身物理方位与形态说明
    public var locationDescription: String {
        switch self {
        case .knob:
            return "机身中央无极主旋钮，支持顺/逆时针旋转与垂直按压"
        case .scroll:
            return "机身左上方防滑橡胶滚轮，支持上/下滚动与按压"
        case .top:
            return "机身上方中央带一字横杠凸起的长条按键"
        case .tall:
            return "机身右下方带三颗盲点凸起的竖向大长键"
        case .short:
            return "机身最右下角方形短键（位于 Tall 键右侧）"
        case .c1:
            return "机身右上方偏左圆形功能小键"
        case .c2:
            return "机身右上方偏右圆形功能小键"
        case .tour:
            return "机身左下方贴合滚轮下沿的月牙形功能键"
        }
    }

    /// 是否包含旋转/滚动子动作（Knob 与 Scroll 同时具备旋转和按压）
    public var hasRotary: Bool {
        rotaryControl != nil
    }

    /// 关联的旋转/滚轮控件（纯按键返回 `nil`）
    public var rotaryControl: TourBoxRotary? {
        switch self {
        case .knob: return .knob
        case .scroll: return .scroll
        case .top, .tall, .short, .c1, .c2, .tour: return nil
        }
    }

    /// 关联的物理按压按键（含 Knob 按压与 Scroll 按压）
    public var buttonControl: TourBoxButton {
        switch self {
        case .knob: return .knobClick
        case .scroll: return .scrollClick
        case .top: return .top
        case .tall: return .tall
        case .short: return .short
        case .c1: return .c1
        case .c2: return .c2
        case .tour: return .tour
        }
    }
}

/// TourBox Lite 的 8 颗可按压微动开关（按下 `Bit7=0`，释放 `Bit7=1`）。
public enum TourBoxButton: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case tall
    case top
    case short
    case c1
    case c2
    case tour
    case scrollClick
    case knobClick

    public var id: String { rawValue }

    /// 按下触发字节（`Bit7 == 0`）
    public var pressByte: UInt8 {
        switch self {
        case .tall: return 0x00
        case .top: return 0x02
        case .short: return 0x03
        case .c1: return 0x22
        case .c2: return 0x23
        case .tour: return 0x2A
        case .scrollClick: return 0x0A
        case .knobClick: return 0x37
        }
    }

    /// 松开释放字节（`pressByte | 0x80`）
    public var releaseByte: UInt8 {
        pressByte | 0x80
    }

    /// 所属物理控件区域
    public var controlId: TourBoxControlId {
        switch self {
        case .tall: return .tall
        case .top: return .top
        case .short: return .short
        case .c1: return .c1
        case .c2: return .c2
        case .tour: return .tour
        case .scrollClick: return .scroll
        case .knobClick: return .knob
        }
    }

    /// 中文显示名称
    public var displayName: String {
        switch self {
        case .tall: return "Tall 长键"
        case .top: return "Top 顶部键"
        case .short: return "Short 短键"
        case .c1: return "C1 键"
        case .c2: return "C2 键"
        case .tour: return "Tour 键"
        case .scrollClick: return "Scroll 按压"
        case .knobClick: return "Knob 按压"
        }
    }
}

/// TourBox Lite 的 2 个旋转编码器控件。
public enum TourBoxRotary: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case knob
    case scroll

    public var id: String { rawValue }

    /// 所属物理控件区域
    public var controlId: TourBoxControlId {
        switch self {
        case .knob: return .knob
        case .scroll: return .scroll
        }
    }

    /// 中文显示名称
    public var displayName: String {
        switch self {
        case .knob: return "Knob 旋转"
        case .scroll: return "Scroll 滚动"
        }
    }

    /// 对应方向的步进触发字节（`Bit7 == 0`）
    public func stepByte(for direction: RotaryDirection) -> UInt8 {
        switch (self, direction) {
        case (.knob, .cw): return 0x44
        case (.knob, .ccw): return 0x04
        case (.scroll, .cw): return 0x49   // Scroll Up
        case (.scroll, .ccw): return 0x09  // Scroll Down
        }
    }

    /// 对应方向的步进停止字节（`stepByte | 0x80`，严禁计入步进！）
    public func stopByte(for direction: RotaryDirection) -> UInt8 {
        stepByte(for: direction) | 0x80
    }

    /// 针对具体旋钮/滚轮映射方向 UI 文案（对 `scroll` 而言 `cw = 向上滚动`, `ccw = 向下滚动`）
    public func directionDisplayName(_ direction: RotaryDirection) -> String {
        direction.displayName(for: self)
    }
}

/// 编码器旋转方向（对 `scroll` 滚轮而言：`cw` 对应向上滚动 `Up`，`ccw` 对应向下滚动 `Down`）。
public enum RotaryDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case cw
    case ccw

    public var isClockwise: Bool {
        self == .cw
    }

    /// 正向步进符号（`cw` 为 `+1`，`ccw` 为 `-1`）
    public var sign: Int {
        self == .cw ? 1 : -1
    }

    /// 根据目标控件返回准确的中文方向文案
    public func displayName(for rotary: TourBoxRotary) -> String {
        switch (rotary, self) {
        case (.knob, .cw): return "顺时针旋转 (CW)"
        case (.knob, .ccw): return "逆时针旋转 (CCW)"
        case (.scroll, .cw): return "向上滚动 (Up)"
        case (.scroll, .ccw): return "向下滚动 (Down)"
        }
    }
}

/// TourBox Lite 单字节输入解码结果。
///
/// 白名单覆盖 TourBox Lite 全部合法单字节（8 颗按键按下/释放共 16 字节 + 2 个编码器双向步进/停止共 8 字节）：
/// - `0x44 / 0x04 / 0x49 / 0x09` 解码为 `.rotaryStep`（计 1 步并用于动态测速）；
/// - `0xC4 / 0x84 / 0xC9 / 0x89` 解码为 `.rotaryStop`（合法消费但计 0 步，防止步进翻倍或污染 Δt 测速）。
public enum TourBoxDecodedByte: Equatable, Hashable, Sendable {
    case buttonPress(TourBoxButton)
    case buttonRelease(TourBoxButton)
    case rotaryStep(TourBoxRotary, RotaryDirection)
    case rotaryStop(TourBoxRotary, RotaryDirection)

    /// TourBox Lite 全部合法单字节白名单集合（所有非白名单字节在运行态将立即触发 40ms 污染隔离窗）。
    public static let validSingleBytes: Set<UInt8> = [
        // 独立按键与编码器下压（Press / Release）
        0x00, 0x80, // Tall
        0x02, 0x82, // Top
        0x03, 0x83, // Short
        0x22, 0xA2, // C1
        0x23, 0xA3, // C2
        0x2A, 0xAA, // Tour
        0x0A, 0x8A, // Scroll Click
        0x37, 0xB7, // Knob Click
        // 旋钮与滚轮（Step / Stop）
        0x44, 0xC4, // Knob CW (step / stop)
        0x04, 0x84, // Knob CCW (step / stop)
        0x49, 0xC9, // Scroll Up (step / stop)
        0x09, 0x89  // Scroll Down (step / stop)
    ]

    /// 将单个字节按 TourBox Lite 白名单精确解码；非白名单字节返回 `nil`。
    public static func decode(_ byte: UInt8) -> TourBoxDecodedByte? {
        switch byte {
        // Buttons Press
        case 0x00: return .buttonPress(.tall)
        case 0x02: return .buttonPress(.top)
        case 0x03: return .buttonPress(.short)
        case 0x22: return .buttonPress(.c1)
        case 0x23: return .buttonPress(.c2)
        case 0x2A: return .buttonPress(.tour)
        case 0x0A: return .buttonPress(.scrollClick)
        case 0x37: return .buttonPress(.knobClick)

        // Buttons Release
        case 0x80: return .buttonRelease(.tall)
        case 0x82: return .buttonRelease(.top)
        case 0x83: return .buttonRelease(.short)
        case 0xA2: return .buttonRelease(.c1)
        case 0xA3: return .buttonRelease(.c2)
        case 0xAA: return .buttonRelease(.tour)
        case 0x8A: return .buttonRelease(.scrollClick)
        case 0xB7: return .buttonRelease(.knobClick)

        // Rotary Step (Trigger, Bit7 == 0)
        case 0x44: return .rotaryStep(.knob, .cw)
        case 0x04: return .rotaryStep(.knob, .ccw)
        case 0x49: return .rotaryStep(.scroll, .cw)
        case 0x09: return .rotaryStep(.scroll, .ccw)

        // Rotary Stop (Release, Bit7 == 1 — 合法白名单字节，但绝不计入步进！)
        case 0xC4: return .rotaryStop(.knob, .cw)
        case 0x84: return .rotaryStop(.knob, .ccw)
        case 0xC9: return .rotaryStop(.scroll, .cw)
        case 0x89: return .rotaryStop(.scroll, .ccw)

        default:
            return nil
        }
    }

    /// 反向编码对应的原始硬件字节
    public var rawByte: UInt8 {
        switch self {
        case .buttonPress(let button):
            return button.pressByte
        case .buttonRelease(let button):
            return button.releaseByte
        case .rotaryStep(let rotary, let direction):
            return rotary.stepByte(for: direction)
        case .rotaryStop(let rotary, let direction):
            return rotary.stopByte(for: direction)
        }
    }

    /// 关联的机身物理控件区域
    public var controlId: TourBoxControlId {
        switch self {
        case .buttonPress(let button), .buttonRelease(let button):
            return button.controlId
        case .rotaryStep(let rotary, _), .rotaryStop(let rotary, _):
            return rotary.controlId
        }
    }

    /// 是否为需要计入步进与测速的旋钮触发事件
    public var isRotaryStep: Bool {
        if case .rotaryStep = self { return true }
        return false
    }

    /// 是否为应被消费忽略（计 0 步）的旋钮停止码
    public var isRotaryStop: Bool {
        if case .rotaryStop = self { return true }
        return false
    }

    /// 带符号的编码器有效步进增量（仅 `.rotaryStep` 返回 `±1`，`.rotaryStop` 与按键一律返回 `0`）
    public var rotaryStepDelta: Int {
        switch self {
        case .rotaryStep(_, let direction):
            return direction.sign
        case .rotaryStop, .buttonPress, .buttonRelease:
            return 0
        }
    }

    /// 用于诊断监视器的可读描述
    public var diagnosticSummary: String {
        switch self {
        case .buttonPress(let button):
            return "\(button.displayName) 按下"
        case .buttonRelease(let button):
            return "\(button.displayName) 释放"
        case .rotaryStep(let rotary, let direction):
            return "\(rotary.displayName) · \(direction.displayName(for: rotary))"
        case .rotaryStop(let rotary, let direction):
            return "\(rotary.displayName) 停止码 (\(direction.rawValue.uppercased()), 计0步)"
        }
    }
}

/// TourBox 串口设备连接状态。
public enum TourBoxConnectionState: Equatable, Sendable {
    case disconnected
    case connecting(port: String)
    case connected(port: String)
    case portBusy(port: String, message: String)
    case error(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var port: String? {
        switch self {
        case .disconnected, .error:
            return nil
        case .connecting(let port), .connected(let port), .portBusy(let port, _):
            return port
        }
    }

    public var displayText: String {
        switch self {
        case .disconnected:
            return "未检测到 TourBox Lite"
        case .connecting(let port):
            return "正在握手 (\(URL(fileURLWithPath: port).lastPathComponent))…"
        case .connected(let port):
            return "已连接 (\(URL(fileURLWithPath: port).lastPathComponent))"
        case .portBusy(_, let message):
            return message
        case .error(let message):
            return message
        }
    }
}

/// `TourBoxSerialService` 对外投递的 `Sendable` 事件流元素。
public enum TourBoxSerialEvent: Equatable, Sendable {
    case stateChanged(TourBoxConnectionState)
    case input(TourBoxDecodedByte, rawByte: UInt8, timestamp: TimeInterval)
    case rawDiagnostic(direction: String, hex: String, note: String)
}
