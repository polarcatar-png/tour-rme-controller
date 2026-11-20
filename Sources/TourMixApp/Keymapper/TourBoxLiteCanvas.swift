import SwiftUI
import TourMixCore

/// Interactive industrial-style vector canvas of the TourBox Lite hardware controller.
///
/// - Scales `TourBoxLiteArtwork` (`480 x 455`) via `aspectFitTransform(in:padding:)`
/// - Uses `.contentShape(scaledPath)` for pixel-accurate non-rectangular hit testing & hover states
/// - Visualizes live hardware presses/turns (`activePhysicalControls`), modifier assignments (`modifierControls`),
///   and clean action callout badges (`bindingSummaries`)
public struct TourBoxLiteCanvas: View {
    public typealias BindingSummaryTuple = (primary: String?, secondary: String?)

    public var selectedControl: TourBoxControlId
    public var activePhysicalControls: Set<TourBoxControlId>
    public var modifierControls: Set<TourBoxControlId>
    public var bindingSummaries: [TourBoxControlId: BindingSummaryTuple]
    public var onSelectControl: (TourBoxControlId) -> Void

    @State private var hoveredControl: TourBoxControlId?

    public init(
        selectedControl: TourBoxControlId,
        activePhysicalControls: Set<TourBoxControlId> = [],
        modifierControls: Set<TourBoxControlId> = [],
        bindingSummaries: [TourBoxControlId: (primary: String?, secondary: String?)] = [:],
        onSelectControl: @escaping (TourBoxControlId) -> Void
    ) {
        self.selectedControl = selectedControl
        self.activePhysicalControls = activePhysicalControls
        self.modifierControls = modifierControls
        self.bindingSummaries = bindingSummaries
        self.onSelectControl = onSelectControl
    }

    public init(
        selectedControl: Binding<TourBoxControlId>,
        activePhysicalControls: Set<TourBoxControlId> = [],
        modifierControls: Set<TourBoxControlId> = [],
        bindingSummaries: [TourBoxControlId: (primary: String?, secondary: String?)] = [:]
    ) {
        self.selectedControl = selectedControl.wrappedValue
        self.activePhysicalControls = activePhysicalControls
        self.modifierControls = modifierControls
        self.bindingSummaries = bindingSummaries
        self.onSelectControl = { selectedControl.wrappedValue = $0 }
    }

    public var body: some View {
        GeometryReader { geo in
            let transform = TourBoxLiteArtwork.aspectFitTransform(in: geo.size, padding: 26)
            let scale = max(0.35, min(geo.size.width / TourBoxLiteArtwork.viewBox.width, geo.size.height / TourBoxLiteArtwork.viewBox.height))

            ZStack {
                // 1. Hardware Chassis & Recessed Well Layer
                chassisLayer(transform: transform, scale: scale)
                    .allowsHitTesting(false)

                // 2. Interactive Controls Layer (exact non-rectangular .contentShape hit testing)
                ForEach(TourBoxControlId.allCases) { controlId in
                    controlRegionView(
                        for: controlId,
                        transform: transform,
                        scale: scale
                    )
                }

                // 3. Tactile Surface Markings Layer (grooves, blind dots, top bar, knob cap)
                tactileDetailsLayer(transform: transform, scale: scale)
                    .allowsHitTesting(false)

                // 4. Anchor Callout Badges Layer
                ForEach(TourBoxControlId.allCases) { controlId in
                    calloutBadge(
                        for: controlId,
                        in: geo.size,
                        transform: transform
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(TourBoxLiteArtwork.viewBox.width / TourBoxLiteArtwork.viewBox.height, contentMode: .fit)
    }

    // MARK: - Chassis & Tactile Layers

    private func chassisLayer(transform: CGAffineTransform, scale: CGFloat) -> some View {
        let outerPath = Path(TourBoxLiteArtwork.outerBodyPath).applying(transform)
        let innerPath = Path(TourBoxLiteArtwork.innerBodyPath).applying(transform)
        let recessPath = TourBoxLiteArtwork.knobRecessCircle.path(transform: transform)
        let knobActive = activePhysicalControls.contains(.knob)

        return ZStack {
            // Outer molded enclosure
            outerPath
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.16, green: 0.17, blue: 0.20),
                            Color(red: 0.10, green: 0.11, blue: 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.black.opacity(0.45), radius: 16 * scale, x: 0, y: 10 * scale)

            outerPath
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.20),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: max(1.1, 1.4 * scale)
                )

            // Inner sculpted deck
            innerPath
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.13, blue: 0.16),
                            Color(red: 0.09, green: 0.10, blue: 0.12)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            innerPath
                .stroke(Color.white.opacity(0.08), lineWidth: max(0.7, 0.9 * scale))

            // Central knob recess dish
            recessPath
                .fill(
                    RadialGradient(
                        colors: [
                            Color.black.opacity(0.46),
                            Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.85)
                        ],
                        center: .center,
                        startRadius: 10 * scale,
                        endRadius: 72 * scale
                    )
                )

            recessPath
                .stroke(
                    knobActive
                        ? Color(red: 1.0, green: 0.72, blue: 0.24).opacity(0.55)
                        : Color.white.opacity(0.09),
                    lineWidth: max(0.8, 1.1 * scale)
                )

            // 12 precision dial dots around central knob
            ForEach(Array(TourBoxLiteArtwork.knobTickDots.enumerated()), id: \.offset) { _, dot in
                dot.path(transform: transform)
                    .fill(
                        knobActive
                            ? Color(red: 1.0, green: 0.76, blue: 0.30).opacity(0.90)
                            : Color.white.opacity(0.24)
                    )
            }
        }
    }

    private func tactileDetailsLayer(transform: CGAffineTransform, scale: CGFloat) -> some View {
        let knobCapPath = TourBoxLiteArtwork.knobInnerCircle.path(transform: transform)
        let topBar = Path(TourBoxLiteArtwork.topBarPath).applying(transform)
        let scrollGrooves = Path(TourBoxLiteArtwork.scrollGroovesCombinedPath).applying(transform)

        return ZStack {
            // Brushed inner cap on Knob
            knobCapPath
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.10),
                            Color.black.opacity(0.22)
                        ],
                        center: .topLeading,
                        startRadius: 2 * scale,
                        endRadius: 48 * scale
                    )
                )
            knobCapPath
                .stroke(Color.white.opacity(0.20), lineWidth: max(0.8, 1.0 * scale))

            // Raised bar on Top key
            topBar
                .stroke(
                    Color.white.opacity(0.32),
                    style: StrokeStyle(lineWidth: max(2.0, 3.0 * scale), lineCap: .round)
                )

            // 6 rubber tread grooves on Scroll wheel
            scrollGrooves
                .stroke(
                    Color.white.opacity(0.26),
                    style: StrokeStyle(lineWidth: max(1.0, 1.35 * scale), lineCap: .round)
                )

            // 3 blind tactile dots on Tall key
            ForEach(Array(TourBoxLiteArtwork.tallBlindDots.enumerated()), id: \.offset) { _, dot in
                dot.path(transform: transform)
                    .fill(Color.white.opacity(0.30))
            }

            // Center tactile dots on C1 & C2
            TourBoxLiteArtwork.c1CenterDot.path(transform: transform)
                .fill(Color.white.opacity(0.28))

            TourBoxLiteArtwork.c2CenterDot.path(transform: transform)
                .fill(Color.white.opacity(0.28))
        }
    }

    // MARK: - Interactive Control Region

    private func controlRegionView(
        for controlId: TourBoxControlId,
        transform: CGAffineTransform,
        scale: CGFloat
    ) -> some View {
        let artwork = TourBoxLiteArtwork.control(for: controlId)
        let scaledPath = artwork.transformedPath(transform)
        let isSelected = (selectedControl == controlId)
        let isHovered = (hoveredControl == controlId)
        let isPhysicallyActive = activePhysicalControls.contains(controlId)
        let isModifier = modifierControls.contains(controlId)
        let hasBinding = hasAssignedAction(for: controlId)

        return ZStack {
            if isPhysicallyActive {
                scaledPath
                    .fill(Color(red: 1.0, green: 0.68, blue: 0.18).opacity(0.32))
                    .blur(radius: 6 * scale)
            }

            scaledPath
                .fill(
                    controlFillStyle(
                        isSelected: isSelected,
                        isHovered: isHovered,
                        isPhysicallyActive: isPhysicallyActive,
                        hasBinding: hasBinding
                    )
                )

            scaledPath
                .stroke(
                    controlStrokeColor(
                        isSelected: isSelected,
                        isHovered: isHovered,
                        isPhysicallyActive: isPhysicallyActive,
                        isModifier: isModifier,
                        hasBinding: hasBinding
                    ),
                    lineWidth: (isSelected || isPhysicallyActive) ? max(1.8, 2.2 * scale) : max(1.0, 1.3 * scale)
                )

            // Non-rectangular exact hit target
            Color.clear
                .contentShape(scaledPath)
                .onTapGesture {
                    onSelectControl(controlId)
                }
                .onHover { hovering in
                    if hovering {
                        hoveredControl = controlId
                    } else if hoveredControl == controlId {
                        hoveredControl = nil
                    }
                }
        }
    }

    // MARK: - Label Anchor Callouts

    private func calloutBadge(
        for controlId: TourBoxControlId,
        in canvasSize: CGSize,
        transform: CGAffineTransform
    ) -> some View {
        let artwork = TourBoxLiteArtwork.control(for: controlId)
        let rawPt = artwork.labelAnchor.applying(transform)
        let clampedPt = CGPoint(
            x: min(max(48, rawPt.x), max(48, canvasSize.width - 48)),
            y: min(max(16, rawPt.y), max(16, canvasSize.height - 16))
        )

        let isSelected = (selectedControl == controlId)
        let isPhysicallyActive = activePhysicalControls.contains(controlId)
        let isModifier = modifierControls.contains(controlId)
        let summary = bindingSummaries[controlId]
        let primary = normalizedSummary(summary?.primary)
        let secondary = normalizedSummary(summary?.secondary)
        let isBound = (primary != nil || secondary != nil)

        return Button {
            onSelectControl(controlId)
        } label: {
            if isBound || isModifier {
                VStack(spacing: 1.5) {
                    HStack(spacing: 4) {
                        Text(controlId.shortTitle)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                isSelected || isPhysicallyActive
                                    ? Color(red: 0.36, green: 0.86, blue: 0.98)
                                    : Color.white.opacity(0.62)
                            )

                        if isModifier {
                            Text("MOD")
                                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color(red: 0.22, green: 0.92, blue: 0.88))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 0.5)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color(red: 0.16, green: 0.80, blue: 0.80).opacity(0.22))
                                )
                        }

                        if let primary {
                            Text(primary)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.96))
                                .lineLimit(1)
                        }
                    }

                    if let secondary {
                        Text(secondary)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.68))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(red: 0.09, green: 0.11, blue: 0.15).opacity(0.92))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isPhysicallyActive
                                ? Color(red: 1.0, green: 0.74, blue: 0.26).opacity(0.85)
                                : (isSelected
                                    ? Color(red: 0.32, green: 0.82, blue: 0.98).opacity(0.85)
                                    : Color.white.opacity(0.22)),
                            lineWidth: isSelected ? 1.2 : 0.8
                        )
                )
                .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)
            } else {
                // Unbound control: restrained, low-noise label so bound controls stand out clearly
                Text(controlId.shortTitle)
                    .font(.system(size: 10.5, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(
                        isPhysicallyActive
                            ? Color(red: 1.0, green: 0.78, blue: 0.30)
                            : (isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.38))
                    )
                    .padding(.horizontal, isSelected ? 7 : 4)
                    .padding(.vertical, 2)
                    .background(
                        Group {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(Color(red: 0.22, green: 0.64, blue: 0.92).opacity(0.24))
                            }
                        }
                    )
                    .overlay(
                        Group {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .strokeBorder(Color(red: 0.34, green: 0.82, blue: 0.98).opacity(0.70), lineWidth: 1.0)
                            }
                        }
                    )
            }
        }
        .buttonStyle(.plain)
        .position(clampedPt)
    }

    // MARK: - Style Helpers

    private func hasAssignedAction(for controlId: TourBoxControlId) -> Bool {
        guard let summary = bindingSummaries[controlId] else { return false }
        return normalizedSummary(summary.primary) != nil || normalizedSummary(summary.secondary) != nil
    }

    private func normalizedSummary(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private func controlFillStyle(
        isSelected: Bool,
        isHovered: Bool,
        isPhysicallyActive: Bool,
        hasBinding: Bool
    ) -> LinearGradient {
        if isPhysicallyActive {
            return LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.66, blue: 0.20).opacity(0.50),
                    Color(red: 0.85, green: 0.44, blue: 0.12).opacity(0.36)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        if isSelected {
            return LinearGradient(
                colors: [
                    Color(red: 0.22, green: 0.66, blue: 0.94).opacity(0.42),
                    Color(red: 0.14, green: 0.44, blue: 0.78).opacity(0.28)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        if isHovered {
            return LinearGradient(
                colors: [
                    Color.white.opacity(hasBinding ? 0.20 : 0.13),
                    Color.white.opacity(hasBinding ? 0.11 : 0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        if hasBinding {
            return LinearGradient(
                colors: [
                    Color(red: 0.22, green: 0.26, blue: 0.33),
                    Color(red: 0.16, green: 0.19, blue: 0.25)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0.16, green: 0.17, blue: 0.20),
                Color(red: 0.13, green: 0.14, blue: 0.17)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func controlStrokeColor(
        isSelected: Bool,
        isHovered: Bool,
        isPhysicallyActive: Bool,
        isModifier: Bool,
        hasBinding: Bool
    ) -> Color {
        if isPhysicallyActive {
            return Color(red: 1.0, green: 0.78, blue: 0.32)
        }
        if isSelected {
            return Color(red: 0.38, green: 0.86, blue: 1.0)
        }
        if isModifier {
            return Color(red: 0.24, green: 0.88, blue: 0.84).opacity(isHovered ? 0.95 : 0.72)
        }
        if isHovered {
            return Color.white.opacity(0.55)
        }
        if hasBinding {
            return Color(red: 0.36, green: 0.74, blue: 0.94).opacity(0.52)
        }
        return Color.white.opacity(0.18)
    }
}
