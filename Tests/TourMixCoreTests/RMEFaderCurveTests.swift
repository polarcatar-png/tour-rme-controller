import Foundation
import Testing
@testable import TourMixCore

@Suite("RMEFaderCurve 1023 步非线性曲线精度测试")
struct RMEFaderCurveTests {
    @Test("极小值 -300.0 dB 与 -65.0 dB 正确映射为归一化 0.0 与 -∞ dB")
    func bottomExtremeValues() {
        #expect(RMEFaderCurve.dbToNormalized(-300.0) == 0.0)
        #expect(RMEFaderCurve.dbToNormalized(-65.0) == 0.0)
        #expect(RMEFaderCurve.dbToNormalized(-.infinity) == 0.0)
        #expect(RMEFaderCurve.dbToNormalized(.nan) == 0.0)

        #expect(RMEFaderCurve.normalizedToDb(0.0) == -65.0)
        #expect(RMEFaderCurve.normalizedToDb(-0.5) == -65.0)

        #expect(RMEFaderCurve.formatDb(-300.0) == "-∞ dB")
        #expect(RMEFaderCurve.formatDb(-65.0) == "-∞ dB")
    }

    @Test("0.0 dB 精确对应 836 / 1023 且格式化无负零")
    func zeroDbExactAnchor() {
        let expectedZeroNorm = 836.0 / 1023.0
        let norm = RMEFaderCurve.dbToNormalized(0.0)
        #expect(abs(norm - expectedZeroNorm) < 1e-9)

        let roundTripDb = RMEFaderCurve.normalizedToDb(expectedZeroNorm)
        #expect(abs(roundTripDb - 0.0) < 0.001)

        #expect(RMEFaderCurve.formatDb(0.0) == "0.0 dB")
        #expect(RMEFaderCurve.formatDb(-0.02) == "0.0 dB")
        #expect(RMEFaderCurve.formatDb(0.02) == "0.0 dB")
    }

    @Test("上限 +6.0 dB 与越界钳位正确")
    func upperBoundClamping() {
        #expect(RMEFaderCurve.dbToNormalized(6.0) == 1.0)
        #expect(RMEFaderCurve.dbToNormalized(12.0) == 1.0)
        #expect(RMEFaderCurve.dbToNormalized(.infinity) == 1.0)

        #expect(RMEFaderCurve.normalizedToDb(1.0) == 6.0)
        #expect(RMEFaderCurve.normalizedToDb(1.5) == 6.0)
        #expect(RMEFaderCurve.formatDb(6.0) == "6.0 dB")
    }

    @Test("关键刻度点 (-50, -30, -20, -12, -6, -3, 0, +3, +6 dB) 双向往返误差 < 0.01 dB")
    func keyCheckpointsRoundTripAccuracy() {
        let checkpoints: [Double] = [-50.0, -40.0, -30.0, -20.0, -12.0, -6.0, -3.0, 0.0, 3.0, 6.0]
        for targetDb in checkpoints {
            let norm = RMEFaderCurve.dbToNormalized(targetDb)
            let recoveredDb = RMEFaderCurve.normalizedToDb(norm)
            #expect(
                abs(recoveredDb - targetDb) < 0.01,
                "目标 \(targetDb) dB 往返得到 \(recoveredDb) dB，超出 0.01 dB 误差阈值"
            )
        }

        // 验证 -6.0 dB 分段折点位于 649 / 1023
        let kneeNorm = RMEFaderCurve.dbToNormalized(-6.0)
        #expect(abs(kneeNorm - (649.0 / 1023.0)) < 1e-4)
    }

    @Test("全部 1023 个硬件步进点严格单调递增")
    func strictMonotonicityAcross1023Steps() {
        var previousDb = RMEFaderCurve.normalizedToDb(0.0)
        for step in 1...1023 {
            let norm = Double(step) / 1023.0
            let currentDb = RMEFaderCurve.normalizedToDb(norm)
            #expect(currentDb > previousDb, "步进 \(step) 非单调：\(currentDb) <= \(previousDb)")
            previousDb = currentDb
        }
    }
}
