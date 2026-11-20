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

/// Frosted glass capsule HUD view (`300 x 84`) with animation-free high-frequency meter bar,
/// `0 dB` unity tick line, monospaced dB readout, and `🔒 0 dB MAX` safety clamp badge.
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
                    Color.white.opacity(0.07),
                    Color.black.opacity(0.22)
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
                            .foregroundStyle(Color.white.opacity(0.96))
                            .lineLimit(1)

                        if let subtitle = payload.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.50))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)

                    if payload.hitZeroDbLock {
                        zeroDbLockBadge
                    } else if let badge = payload.badgeText, !badge.isEmpty {
                        customBadge(badge)
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
        .frame(width: 300, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    payload.hitZeroDbLock
                        ? Color(red: 1.0, green: 0.72, blue: 0.22).opacity(0.55)
                        : Color.white.opacity(0.16),
                    lineWidth: 0.9
                )
        )
        .environment(\.colorScheme, .dark)
        .transaction { transaction in
            // Critical (#5 Major-2): disable implicit SwiftUI animations during 30~80 Hz rotary updates
            transaction.disablesAnimations = true
        }
    }

    private var zeroDbLockBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8.5, weight: .bold))
            Text("0 dB MAX")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
        }
        .foregroundStyle(Color(red: 1.0, green: 0.80, blue: 0.32))
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2.5)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 1.0, green: 0.65, blue: 0.12).opacity(0.20))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color(red: 1.0, green: 0.75, blue: 0.25).opacity(0.45), lineWidth: 0.75)
        )
    }

    private func customBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.80))
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.12))
            )
    }

    private func meterBar(for payload: HUDPayload, isOverUnity: Bool) -> some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let fillWidth = max(0, min(width, width * CGFloat(payload.normalizedLevel)))
            let unityX = max(0, min(width - 1.5, width * CGFloat(payload.unityNormalizedPosition)))

            ZStack(alignment: .leading) {
                // Track
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.13))
                    .frame(height: 7)

                // Active level fill (zero implicit animation lag)
                if fillWidth > 0.5 {
                    Capsule(style: .continuous)
                        .fill(barGradient(for: payload, isOverUnity: isOverUnity))
                        .frame(width: max(7, fillWidth), height: 7)
                }

                // 0.0 dB unity reference tick line
                Rectangle()
                    .fill(Color.white.opacity(0.88))
                    .frame(width: 1.5, height: 13)
                    .offset(x: unityX)
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
            return Color(red: 1.0, green: 0.38, blue: 0.36)
        }
        if payload.hitZeroDbLock {
            return Color(red: 1.0, green: 0.76, blue: 0.28)
        }
        return Color(red: 0.32, green: 0.84, blue: 0.96)
    }

    private func readoutColor(for payload: HUDPayload, isOverUnity: Bool) -> Color {
        if payload.isMuted {
            return Color(red: 1.0, green: 0.42, blue: 0.40)
        }
        if payload.hitZeroDbLock || isOverUnity {
            return Color(red: 1.0, green: 0.80, blue: 0.34)
        }
        return Color.white.opacity(0.98)
    }

    private func barGradient(for payload: HUDPayload, isOverUnity: Bool) -> LinearGradient {
        if payload.isMuted {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.26),
                    Color(red: 0.92, green: 0.36, blue: 0.35).opacity(0.65)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        if isOverUnity {
            return LinearGradient(
                colors: [
                    Color(red: 0.24, green: 0.78, blue: 0.95),
                    Color(red: 1.0, green: 0.68, blue: 0.20)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0.20, green: 0.72, blue: 0.96),
                Color(red: 0.28, green: 0.92, blue: 0.78)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
