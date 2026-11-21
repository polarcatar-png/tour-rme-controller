import AppKit
import Observation
import SwiftUI

/// Pure value payload rendered by the non-activating floating HUD capsule.
public struct HUDPayload: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var dbText: String
    public var normalizedLevel: Double
    public var unityNormalizedPosition: Double
    public var safetyLimitNormalizedPosition: Double?
    public var isMuted: Bool
    public var hitZeroDbLock: Bool
    public var badgeText: String?
    public var systemIcon: String

    public init(
        title: String,
        subtitle: String? = nil,
        dbText: String,
        normalizedLevel: Double,
        unityNormalizedPosition: Double = 836.0 / 1023.0,
        safetyLimitNormalizedPosition: Double? = nil,
        isMuted: Bool = false,
        hitZeroDbLock: Bool = false,
        badgeText: String? = nil,
        systemIcon: String = "hifispeaker.2.fill"
    ) {
        self.title = title
        self.subtitle = subtitle
        self.dbText = dbText
        self.normalizedLevel = min(1.0, max(0.0, normalizedLevel))
        self.unityNormalizedPosition = min(1.0, max(0.0, unityNormalizedPosition))
        self.safetyLimitNormalizedPosition = safetyLimitNormalizedPosition.map { min(1.0, max(0.0, $0)) }
        self.isMuted = isMuted
        self.hitZeroDbLock = hitZeroDbLock
        self.badgeText = badgeText
        self.systemIcon = systemIcon
    }
}

/// Observable holder reused by `HUDPanelController` so 30~80 Hz rotary updates never recreate `NSHostingView`.
@MainActor
@Observable
public final class HUDViewModel {
    public var payload: HUDPayload

    public init(
        payload: HUDPayload = HUDPayload(
            title: "AN 1/2",
            subtitle: "Hardware Output",
            dbText: "-20.0 dB",
            normalizedLevel: 0.52
        )
    ) {
        self.payload = payload
    }
}

/// Native AppKit dark vibrancy backdrop ensuring consistent HUD translucency over both bright and dark fullscreen spaces.
private struct HUDVibrancyBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}

/// Frosted glass capsule HUD view (`336 x 84`) with animation-free high-frequency meter bar,
/// `0 dB` unity tick line, custom safety ceiling zone/tick, monospaced dB readout, and dynamic MAX lock badge.
public struct HUDContentView: View {
    private enum Source {
        case observed(HUDViewModel)
        case constant(HUDPayload)
    }

    private let source: Source

    public init(model: HUDViewModel) {
        self.source = .observed(model)
    }

    public init(payload: HUDPayload) {
        self.source = .constant(payload)
    }

    private var currentPayload: HUDPayload {
        switch source {
        case .observed(let model):
            return model.payload
        case .constant(let payload):
            return payload
        }
    }

    public var body: some View {
        let payload = currentPayload
        let isOverUnity = !payload.isMuted && payload.normalizedLevel > payload.unityNormalizedPosition + 0.002

        ZStack {
            HUDVibrancyBackground()

            LinearGradient(
                colors: [
                    TotalMixTheme.stripSurfaceTop.opacity(0.62),
                    TotalMixTheme.chassisDeep.opacity(0.76)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: payload.isMuted ? "speaker.slash.fill" : payload.systemIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconColor(for: payload))
                        .frame(width: 18, alignment: .center)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(payload.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(TotalMixTheme.textPrimary)
                            .lineLimit(1)

                        if let subtitle = payload.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(TotalMixTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)

                    if payload.hitZeroDbLock {
                        lockBadge(text: payload.badgeText ?? "0 dB MAX")
                    } else if let badge = payload.badgeText, !badge.isEmpty {
                        customBadge(badge, isMuted: payload.isMuted)
                    }

                    Text(payload.isMuted ? "MUTED" : payload.dbText)
                        .font(.system(size: 15.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(readoutColor(for: payload, isOverUnity: isOverUnity))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                meterBar(for: payload, isOverUnity: isOverUnity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .frame(width: 336, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderColor(for: payload), lineWidth: 1.0)
        )
        .environment(\.colorScheme, .dark)
        .transaction { transaction in
            // Critical (#5 Major-2): disable implicit SwiftUI animations during 30~80 Hz rotary updates
            transaction.disablesAnimations = true
        }
    }

    private func borderColor(for payload: HUDPayload) -> Color {
        if payload.hitZeroDbLock {
            return TotalMixTheme.rmeAmber.opacity(0.85)
        }
        if payload.isMuted {
            return TotalMixTheme.rmeRed.opacity(0.75)
        }
        return TotalMixTheme.borderBevel.opacity(0.78)
    }

    private func lockBadge(text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8.5, weight: .bold))
            Text(text)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(TotalMixTheme.rmeAmber)
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2.5)
        .background(
            Capsule(style: .continuous)
                .fill(TotalMixTheme.rmeAmber.opacity(0.20))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(TotalMixTheme.rmeAmber.opacity(0.55), lineWidth: 0.75)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private func customBadge(_ text: String, isMuted: Bool) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(isMuted ? TotalMixTheme.textPrimary : TotalMixTheme.textSecondary)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous)
                    .fill(isMuted ? TotalMixTheme.rmeRedDeep : TotalMixTheme.surfaceControl)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isMuted ? TotalMixTheme.rmeRed.opacity(0.7) : TotalMixTheme.borderSubtle,
                        lineWidth: 0.75
                    )
            )
            .fixedSize(horizontal: true, vertical: false)
    }

    private func meterBar(for payload: HUDPayload, isOverUnity: Bool) -> some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let fillWidth = max(0, min(width, width * CGFloat(payload.normalizedLevel)))
            let unityX = max(0, min(width - 1.5, width * CGFloat(payload.unityNormalizedPosition)))

            ZStack(alignment: .leading) {
                // Single clipped 8pt bar housing track, amber guarded zone, and active level fill
                ZStack(alignment: .leading) {
                    TotalMixTheme.chassisDeep.opacity(0.92)

                    if let limitPos = payload.safetyLimitNormalizedPosition {
                        let limitX = max(0, min(width - 2.0, width * CGFloat(limitPos)))
                        TotalMixTheme.rmeAmber.opacity(0.20)
                            .frame(width: max(0, width - limitX))
                            .offset(x: limitX)
                    }

                    if fillWidth > 0.5 {
                        Capsule(style: .continuous)
                            .fill(barGradient(for: payload, isOverUnity: isOverUnity))
                            .frame(width: max(8, fillWidth))
                    }
                }
                .frame(width: width, height: 8)
                .clipShape(Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(TotalMixTheme.borderSubtle.opacity(0.75), lineWidth: 0.7)
                )

                // 0.0 dB unity reference tick line
                Rectangle()
                    .fill(TotalMixTheme.textPrimary.opacity(0.78))
                    .frame(width: 1.5, height: 13)
                    .offset(x: unityX)

                // Custom safety ceiling stop tick line (if enabled)
                if let limitPos = payload.safetyLimitNormalizedPosition {
                    let limitTickX = max(0, min(width - 2.0, width * CGFloat(limitPos) - 1.0))
                    Rectangle()
                        .fill(TotalMixTheme.rmeAmber)
                        .frame(width: 2.0, height: 13)
                        .offset(x: limitTickX)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .transaction { tx in
                tx.disablesAnimations = true
            }
        }
        .frame(height: 13)
    }

    private func iconColor(for payload: HUDPayload) -> Color {
        if payload.isMuted {
            return TotalMixTheme.rmeRed
        }
        if payload.hitZeroDbLock {
            return TotalMixTheme.rmeAmber
        }
        return TotalMixTheme.rmeGreenBright
    }

    private func readoutColor(for payload: HUDPayload, isOverUnity: Bool) -> Color {
        if payload.isMuted {
            return TotalMixTheme.rmeRed
        }
        if payload.hitZeroDbLock || isOverUnity {
            return TotalMixTheme.rmeAmber
        }
        return TotalMixTheme.textPrimary
    }

    private func barGradient(for payload: HUDPayload, isOverUnity: Bool) -> LinearGradient {
        if payload.isMuted {
            return LinearGradient(
                colors: [
                    TotalMixTheme.rmeRedDeep.opacity(0.70),
                    TotalMixTheme.rmeRed.opacity(0.85)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        if isOverUnity {
            return LinearGradient(
                colors: [
                    TotalMixTheme.rmeGreen,
                    TotalMixTheme.rmeAmber,
                    TotalMixTheme.rmeRed
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [
                TotalMixTheme.rmeGreenDeep,
                TotalMixTheme.rmeGreen,
                TotalMixTheme.rmeGreenBright
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
