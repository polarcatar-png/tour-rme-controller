import Foundation

/// Configuration for physical rotary encoder velocity ballistics or fixed-step dB adjustment.
public struct RotaryBallisticsConfig: Codable, Equatable, Sendable {
    public enum Mode: Codable, Equatable, Sendable {
        /// Three-tier Δt velocity acceleration (slow fine, medium normal, fast coarse).
        case dynamic
        /// Constant step per detent regardless of rotation speed.
        case fixed(db: Double)
    }

    public var mode: Mode
    /// Fine step used when Δt > `slowThresholdSec` (or on first detent / direction reversal). Default: `0.5` dB (configurable e.g. `0.2` dB).
    public var slowStepDb: Double
    /// Normal step used when `fastThresholdSec <= Δt <= slowThresholdSec`. Default: `1.0` dB.
    public var mediumStepDb: Double
    /// Fast step used when `Δt < fastThresholdSec`. Default: `2.5` dB.
    public var fastStepDb: Double
    /// Upper Δt bound (in seconds) separating medium and slow tiers. Default: `0.110` s (`110 ms`).
    public var slowThresholdSec: TimeInterval
    /// Lower Δt bound (in seconds) separating fast and medium tiers. Default: `0.045` s (`45 ms`).
    public var fastThresholdSec: TimeInterval

    public init(
        mode: Mode = .dynamic,
        slowStepDb: Double = 0.5,
        mediumStepDb: Double = 1.0,
        fastStepDb: Double = 2.5,
        slowThresholdSec: TimeInterval = 0.110,
        fastThresholdSec: TimeInterval = 0.045
    ) {
        self.mode = mode
        self.slowStepDb = abs(slowStepDb)
        self.mediumStepDb = abs(mediumStepDb)
        self.fastStepDb = abs(fastStepDb)
        self.slowThresholdSec = slowThresholdSec
        self.fastThresholdSec = fastThresholdSec
    }

    /// Standard three-tier ballistics (`0.5 / 1.0 / 2.5 dB` at `110 ms / 45 ms`).
    public static let standard = RotaryBallisticsConfig()

    /// Alias for standard three-tier ballistics.
    public static let ballistic = RotaryBallisticsConfig.standard

    /// Precision fine-tuning preset (`0.2 / 1.0 / 2.5 dB` at `110 ms / 45 ms`).
    public static let fine = RotaryBallisticsConfig(slowStepDb: 0.2)

    /// Fixed dB step per detent regardless of rotation velocity.
    public static func fixed(db: Double) -> RotaryBallisticsConfig {
        RotaryBallisticsConfig(mode: .fixed(db: abs(db)))
    }
}

/// Stateful per-control rotary velocity tracker.
///
/// Only feed `.rotaryStep` timestamps (`0x44`/`0x04` or `0x49`/`0x09`) — never `.rotaryStop` (`0xc4`/`0x84`).
/// Whenever rotation reverses direction (`CW <-> CCW`), `lastStepTime` is immediately reset so the first detent
/// in the opposite direction uses the slow precision tier instead of jumping `-2.5 dB`.
public struct RotaryBallisticsState: Equatable, Sendable {
    public private(set) var lastStepTime: TimeInterval?
    public private(set) var lastIsClockwise: Bool?

    public init() {
        self.lastStepTime = nil
        self.lastIsClockwise = nil
    }

    /// Clears stored timing and direction history.
    public mutating func reset() {
        lastStepTime = nil
        lastIsClockwise = nil
    }

    /// Computes signed `deltaDb` for a single rotary detent and updates internal velocity tracking state.
    public mutating func step(
        isClockwise: Bool,
        timestamp: TimeInterval,
        config: RotaryBallisticsConfig = .standard
    ) -> Double {
        if let previousDirection = lastIsClockwise, previousDirection != isClockwise {
            lastStepTime = nil
        }

        let magnitude: Double
        switch config.mode {
        case .fixed(let db):
            magnitude = abs(db)
        case .dynamic:
            let epsilon: TimeInterval = 1e-9
            if let previousTime = lastStepTime, timestamp >= previousTime {
                let dt = timestamp - previousTime
                if dt < config.fastThresholdSec - epsilon {
                    magnitude = abs(config.fastStepDb)
                } else if dt <= config.slowThresholdSec + epsilon {
                    magnitude = abs(config.mediumStepDb)
                } else {
                    magnitude = abs(config.slowStepDb)
                }
            } else {
                magnitude = abs(config.slowStepDb)
            }
        }

        lastStepTime = timestamp
        lastIsClockwise = isClockwise

        return isClockwise ? magnitude : -magnitude
    }

    /// Pure helper forwarding to `applySafetyCeilingClamp(currentDb:deltaDb:enabled:maxDb:)`.
    public static func applySafetyCeilingClamp(
        currentDb: Double,
        deltaDb: Double,
        enabled: Bool,
        maxDb: Double = VolumeSafetyLimit.defaultMaxDb
    ) -> (targetDb: Double, hitLimitLock: Bool) {
        TourMixCore_applySafetyCeilingClamp(
            currentDb: currentDb,
            deltaDb: deltaDb,
            enabled: enabled,
            maxDb: maxDb
        )
    }

    /// Pure helper forwarding to `applyZeroDbSafetyClamp(currentDb:deltaDb:enabled:)`.
    public static func applyZeroDbSafetyClamp(
        currentDb: Double,
        deltaDb: Double,
        enabled: Bool
    ) -> (targetDb: Double, hitZeroDbLock: Bool) {
        TourMixCore_applyZeroDbSafetyClamp(currentDb: currentDb, deltaDb: deltaDb, enabled: enabled)
    }
}

/// Constants and formatting helpers for configurable volume safety ceiling protection (`-60.0 ... +6.0 dB`).
public enum VolumeSafetyLimit: Sendable {
    public static let defaultMaxDb: Double = 0.0
    public static let minConfigurableDb: Double = -60.0
    public static let maxConfigurableDb: Double = RMEFaderCurve.maxDb
    public static let quickPresetsDb: [Double] = [-24.0, -18.0, -12.0, -6.0, -3.0, 0.0, 3.0]

    /// Clamps a user-configured ceiling to the safe `-60.0 ... +6.0 dB` range and normalizes `-0.0` to `0.0`.
    public static func clampCeilingDb(_ db: Double) -> Double {
        guard db.isFinite else { return defaultMaxDb }
        let clamped = min(maxConfigurableDb, max(minConfigurableDb, db))
        return abs(clamped) < 0.0005 ? 0.0 : clamped
    }

    /// Formats a ceiling value concisely (e.g. `"0 dB"`, `"-12 dB"`, `"-12.5 dB"`, `"+3 dB"`).
    public static func formatLimitDb(_ db: Double) -> String {
        let clamped = clampCeilingDb(db)
        let rounded = (clamped * 10.0).rounded() / 10.0
        if abs(rounded) < 0.05 {
            return "0 dB"
        }
        let sign = rounded > 0.0 ? "+" : ""
        let isWhole = abs(rounded - rounded.rounded()) < 0.05
        if isWhole {
            return "\(sign)\(Int(rounded.rounded())) dB"
        }
        return String(format: "%@%.1f dB", sign, rounded)
    }

    /// Formats the HUD/lock badge label (e.g. `"0 dB MAX"`, `"-12 dB MAX"`).
    public static func formatMaxBadge(_ db: Double) -> String {
        "\(formatLimitDb(db)) MAX"
    }
}

/// Applies the configurable volume safety ceiling clamp when increasing volume from at or below `maxDb`.
///
/// - When `enabled && deltaDb > 0 && currentDb <= limitDb + 0.001 && currentDb + deltaDb > limitDb`,
///   clamps `targetDb` to `limitDb` and returns `hitLimitLock = true`.
/// - If `currentDb` is already above `limitDb` and the user turns counter-clockwise (`deltaDb < 0`),
///   decreases normally without clamping.
public func applySafetyCeilingClamp(
    currentDb: Double,
    deltaDb: Double,
    enabled: Bool,
    maxDb: Double = VolumeSafetyLimit.defaultMaxDb
) -> (targetDb: Double, hitLimitLock: Bool) {
    TourMixCore_applySafetyCeilingClamp(
        currentDb: currentDb,
        deltaDb: deltaDb,
        enabled: enabled,
        maxDb: maxDb
    )
}

/// Applies the `0.0 dB` overload safety clamp when increasing volume from at or below `0.0 dB`.
///
/// - When `enabled && deltaDb > 0 && currentDb <= 0.001 && currentDb + deltaDb > 0.0`, clamps `targetDb` to `0.0`
///   and returns `hitZeroDbLock = true`.
/// - If `currentDb` is already above `0.0 dB` (e.g. `+2.0 dB` set in TotalMix) and the user turns counter-clockwise
///   (`deltaDb < 0`), decreases normally without clamping.
public func applyZeroDbSafetyClamp(
    currentDb: Double,
    deltaDb: Double,
    enabled: Bool
) -> (targetDb: Double, hitZeroDbLock: Bool) {
    TourMixCore_applyZeroDbSafetyClamp(currentDb: currentDb, deltaDb: deltaDb, enabled: enabled)
}

@inline(__always)
private func TourMixCore_applyZeroDbSafetyClamp(
    currentDb: Double,
    deltaDb: Double,
    enabled: Bool
) -> (targetDb: Double, hitZeroDbLock: Bool) {
    let result = TourMixCore_applySafetyCeilingClamp(
        currentDb: currentDb,
        deltaDb: deltaDb,
        enabled: enabled,
        maxDb: 0.0
    )
    return (targetDb: result.targetDb, hitZeroDbLock: result.hitLimitLock)
}

@inline(__always)
private func TourMixCore_applySafetyCeilingClamp(
    currentDb: Double,
    deltaDb: Double,
    enabled: Bool,
    maxDb: Double
) -> (targetDb: Double, hitLimitLock: Bool) {
    let limitDb = VolumeSafetyLimit.clampCeilingDb(maxDb)
    let candidate = currentDb + deltaDb
    if enabled && deltaDb > 0.0 && currentDb <= limitDb + 0.001 && candidate > limitDb {
        return (targetDb: limitDb, hitLimitLock: true)
    }
    return (targetDb: candidate, hitLimitLock: false)
}
