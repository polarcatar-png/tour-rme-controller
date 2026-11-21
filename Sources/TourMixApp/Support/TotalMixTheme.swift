import AppKit
import SwiftUI

/// RME TotalMix FX 2.10 Dark Mode palette tailored with warm studio amber accents and signal green metering.
///
/// Design DNA:
/// - **Cool blue-slate console chassis** (`#171B1F` – `#2A2F34`), avoiding flat neutral blacks.
/// - **Warm Studio Amber** (`#E89624` / `#A86214`) for active selections, focus borders, Control Room Dim, and safety ceiling locks.
/// - **Studio Signal Green** (`#1F7A2E` – `#6CE04A`) for level meters and online hardware status LEDs.
/// - **Studio Alert Red** (`#E03B24` / `#B82B18`) for channel Mute, over-0dB clipping, and transport conflicts.
public enum TotalMixTheme {
    // MARK: - Console Chassis & Surfaces

    /// Deep recessed well (`#171B1F`) for fader tracks, safety ceiling inset panels, and packet consoles.
    public static let chassisDeep = Color(red: 0.090, green: 0.106, blue: 0.122)

    /// Canvas / recessed hardware deck background (`#1A1E22`).
    public static let canvasDeck = Color(red: 0.102, green: 0.118, blue: 0.133)

    /// Top toolbar & tab housing (`#1C2024`).
    public static let toolbarBackground = Color(red: 0.110, green: 0.125, blue: 0.141)

    /// Primary TotalMix window & control room chassis (`#202428`).
    public static let windowBackground = Color(red: 0.125, green: 0.141, blue: 0.157)

    /// Bottom gradient anchor for popovers & console background (`#1B1F23`).
    public static let windowBackgroundBottom = Color(red: 0.106, green: 0.122, blue: 0.137)

    /// Matching AppKit `NSColor` for `NSWindow.backgroundColor` (`#202428`).
    public static let windowBackgroundNSColor = NSColor(
        srgbRed: 0.125,
        green: 0.141,
        blue: 0.157,
        alpha: 1.0
    )

    /// Elevated mixer channel strip / inspector card top stop (`#2A2F34`).
    public static let stripSurfaceTop = Color(red: 0.165, green: 0.184, blue: 0.204)

    /// Elevated mixer channel strip / inspector card bottom stop (`#23282D`).
    public static let stripSurfaceBottom = Color(red: 0.137, green: 0.157, blue: 0.176)

    /// Raised hardware push-button fill (`#333A40`).
    public static let surfaceControl = Color(red: 0.200, green: 0.227, blue: 0.251)

    /// Hovered or accented hardware push-button fill (`#3E464E`).
    public static let surfaceControlHover = Color(red: 0.243, green: 0.275, blue: 0.306)

    /// Hairline metallic card / pill border (`#3D464E`).
    public static let borderSubtle = Color(red: 0.239, green: 0.275, blue: 0.306)

    /// TotalMix brushed slate bezel highlight (`#505E6A`).
    public static let borderBevel = Color(red: 0.314, green: 0.369, blue: 0.416)

    // MARK: - Studio Amber & Functional LED Accents

    /// Primary backlit studio amber accent (`#E89624`) — active focus, selected tabs/controls, and icons.
    public static let accent = Color(red: 0.910, green: 0.588, blue: 0.141)

    /// Deep amber surface fill (`#A86214`) — active pill/tab backing & highlighted control fill.
    public static let accentDeep = Color(red: 0.659, green: 0.384, blue: 0.078)

    /// Warm pale amber-cream tint (`#FFE0A8`) — crisp highlighted text inside deep amber pills.
    public static let accentLight = Color(red: 1.000, green: 0.878, blue: 0.659)

    /// Warm studio gold (`#F0AE42`) — hardware modifier badges & borders.
    public static let accentGold = Color(red: 0.941, green: 0.682, blue: 0.259)

    /// Studio LED Amber (`#E08C1C`) — DIM, volume safety ceiling lock, and live physical hardware glow.
    public static let rmeAmber = Color(red: 0.878, green: 0.549, blue: 0.110)

    /// Rich darker amber (`#B86814`) — active lock bevel & deep fill accent.
    public static let rmeAmberDeep = Color(red: 0.722, green: 0.408, blue: 0.078)

    /// TotalMix Mute / Clip Red (`#E03B24`).
    public static let rmeRed = Color(red: 0.878, green: 0.231, blue: 0.141)

    /// Deep Mute pill fill (`#B82B18`) — high-contrast backing for white `"M"` / `"MUTED"` labels.
    public static let rmeRedDeep = Color(red: 0.722, green: 0.169, blue: 0.094)

    /// Deep studio signal green (`#1F7A2E`) — low end of green volume meter gradient.
    public static let rmeGreenDeep = Color(red: 0.122, green: 0.478, blue: 0.180)

    /// TotalMix Bus Online Green (`#2EB840`).
    public static let rmeGreen = Color(red: 0.180, green: 0.722, blue: 0.251)

    /// Bright TotalMix studio signal green (`#6CE04A`) — active fader bar peak highlight.
    public static let rmeGreenBright = Color(red: 0.424, green: 0.878, blue: 0.290)

    // MARK: - Typography & Hardware Fader Cap

    /// Crisp off-white studio label text (`#F2F6F9`).
    public static let textPrimary = Color(red: 0.949, green: 0.965, blue: 0.976)

    /// Cool steel secondary label text (`#9AAAB6`).
    public static let textSecondary = Color(red: 0.604, green: 0.667, blue: 0.714)

    /// Subtle muted label text (`#6E7F8C`).
    public static let textMuted = Color(red: 0.431, green: 0.498, blue: 0.549)

    /// Sculpted TotalMix physical fader cap top (`#EEF3F7`).
    public static let faderCapTop = Color(red: 0.933, green: 0.953, blue: 0.969)

    /// Sculpted TotalMix physical fader cap bottom (`#BCC7D0`).
    public static let faderCapBottom = Color(red: 0.737, green: 0.780, blue: 0.816)

    /// Dark center notch groove on the TotalMix physical fader cap (`#1E2226`).
    public static let faderCapGroove = Color(red: 0.118, green: 0.133, blue: 0.149)

    // MARK: - Reusable Gradients

    public static var windowGradient: LinearGradient {
        LinearGradient(
            colors: [windowBackground, windowBackgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    public static var stripCardGradient: LinearGradient {
        LinearGradient(
            colors: [stripSurfaceTop, stripSurfaceBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
