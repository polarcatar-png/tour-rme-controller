import Foundation

/// RME TotalMix FX 1023 步分段非线性推子曲线双向换算工具。
///
/// 曲线对齐 TotalMix FX 2.10 Global OSC 与 RME 官方 OSC 表：
/// - 总步数：`1023.0`
/// - `0.0 dB` 精确对应 `836.0 / 1023.0` (`≈ 0.8172043`)
/// - `-6.0 dB` 位于分段折点 `649.0 / 1023.0` (`≈ 0.6344086`)
/// - `<= -65.0 dB`（含 TotalMix 推子拉到底回传的 `-300.0 dB`）统一映射为归一化 `0.0`（显示 `"-∞ dB"`）
/// - `>= +6.0 dB` 统一钳位为归一化 `1.0`
public enum RMEFaderCurve: Sendable {
    public static let faderSteps: Double = 1023.0
    public static let minDb: Double = -65.0
    public static let maxDb: Double = 6.0
    public static let zeroDbStep: Double = 836.0
    public static let kneeDbStep: Double = 649.0
    public static let zeroDbNormalized: Double = 836.0 / 1023.0

    private static let upperSlope: Double = 0.0320855615
    private static let upperIntercept: Double = 26.8235294118
    private static let lowerQuadDenominator: Double = 11033.0
    private static let lowerLinearSlope: Double = 0.1497326203

    /// 将任意浮点值安全钳位至 `[0.0, 1.0]`。
    public static func clampNormalized(_ value: Double) -> Double {
        guard value.isFinite else {
            return value == .infinity ? 1.0 : 0.0
        }
        return min(1.0, max(0.0, value))
    }

    /// 归一化推子位置 (`0.0 ... 1.0`) 转换为分贝值 (`-65.0 ... +6.0 dB`)。
    public static func normalizedToDb(_ value: Double) -> Double {
        let normalized = clampNormalized(value)
        if normalized <= 0.0 {
            return minDb
        }
        if normalized >= 1.0 {
            return maxDb
        }

        let position = normalized * faderSteps
        if position >= kneeDbStep {
            let db = position * upperSlope - upperIntercept
            return abs(db) < 0.0005 ? 0.0 : min(maxDb, db)
        }

        let db = (position * position) * (-1.0 / lowerQuadDenominator) + position * lowerLinearSlope - 65.0
        return max(minDb, db)
    }

    /// 分贝值转换为归一化推子位置 (`0.0 ... 1.0`)。
    ///
    /// - 对 `<= -65.0`（含 TotalMix 内部发送的 `-300.0` 极小值）返回 `0.0`。
    /// - 对 `>= 6.0` 返回 `1.0`。
    /// - 对 `0.0 dB` 精确返回 `836.0 / 1023.0`。
    public static func dbToNormalized(_ db: Double) -> Double {
        guard db.isFinite else {
            return db == .infinity ? 1.0 : 0.0
        }
        if db <= minDb {
            return 0.0
        }
        if db >= maxDb {
            return 1.0
        }
        if abs(db) < 1e-7 {
            return zeroDbNormalized
        }

        let position: Double
        if db >= -6.0 {
            position = (db + upperIntercept) / upperSlope
        } else {
            let radicand = max(0.0, -34869.0 - lowerQuadDenominator * db)
            position = 826.0 - radicand.squareRoot()
        }
        return clampNormalized(position / faderSteps)
    }

    /// 格式化分贝显示文本；`<= -65.0`（含 `-300.0`）固定显示 `"-∞ dB"`，`0.0` 附近消除负零显示 `"0.0 dB"`。
    public static func formatDb(_ db: Double) -> String {
        guard db.isFinite else {
            return db > 0 ? "6.0 dB" : "-∞ dB"
        }
        if db <= minDb {
            return "-∞ dB"
        }
        let clamped = min(maxDb, db)
        let roundedTenths = (clamped * 10.0).rounded() / 10.0
        if abs(roundedTenths) < 0.05 {
            return "0.0 dB"
        }
        return String(format: "%.1f dB", roundedTenths)
    }
}
