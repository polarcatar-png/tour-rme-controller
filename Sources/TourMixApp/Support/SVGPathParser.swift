import CoreGraphics
import Foundation
import SwiftUI
#if canImport(TourMixCore)
import TourMixCore
#endif

/// Deterministic SVG `<path d="...">` parser supporting absolute and relative
/// `M/m`, `L/l`, `H/h`, `V/v`, `C/c`, `S/s`, `Q/q`, `T/t`, and `Z/z` commands.
///
/// Correctly handles:
/// - Implicit repeated coordinate tuples (`m x y dx1 dy1...` -> move + relative lines, `c ...` -> chained relative cubics)
/// - Sign-separated numbers without whitespace (`10-5.2` -> `10`, `-5.2`)
/// - Consecutive decimal tokens without whitespace (`.5.25` -> `0.5`, `0.25`)
/// - Scientific notation (`1.5e-3`)
public enum SVGPathParser {
    public static func parse(_ d: String, transform: CGAffineTransform = .identity) -> CGPath {
        let bytes = Array(d.utf8)
        let count = bytes.count
        var index = 0

        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var hasCurrentPoint = false
        var command: UInt8 = 0

        func skipSeparators() {
            while index < count {
                let b = bytes[index]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x2C {
                    index += 1
                } else {
                    break
                }
            }
        }

        func isCommandByte(_ b: UInt8) -> Bool {
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }

        func readNumber() -> CGFloat? {
            skipSeparators()
            guard index < count else { return nil }

            let start = index
            let first = bytes[index]
            guard first == 0x2B || first == 0x2D || first == 0x2E || (first >= 0x30 && first <= 0x39) else {
                return nil
            }

            if first == 0x2B || first == 0x2D {
                index += 1
            }

            var hasDigits = false
            while index < count && bytes[index] >= 0x30 && bytes[index] <= 0x39 {
                index += 1
                hasDigits = true
            }

            if index < count && bytes[index] == 0x2E {
                index += 1
                while index < count && bytes[index] >= 0x30 && bytes[index] <= 0x39 {
                    index += 1
                    hasDigits = true
                }
            }

            guard hasDigits else {
                index = start
                return nil
            }

            if index < count && (bytes[index] == 0x65 || bytes[index] == 0x45) {
                let expAnchor = index
                var probe = index + 1
                if probe < count && (bytes[probe] == 0x2B || bytes[probe] == 0x2D) {
                    probe += 1
                }
                var hasExpDigits = false
                while probe < count && bytes[probe] >= 0x30 && bytes[probe] <= 0x39 {
                    probe += 1
                    hasExpDigits = true
                }
                if hasExpDigits {
                    index = probe
                } else {
                    index = expAnchor
                }
            }

            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let value = Double(token) else {
                return nil
            }
            return CGFloat(value)
        }

        while index < count {
            skipSeparators()
            guard index < count else { break }

            let peek = bytes[index]
            if isCommandByte(peek) {
                command = peek
                index += 1

                if command == 0x5A || command == 0x7A { // Z / z
                    path.closeSubpath()
                    current = subpathStart
                    lastCubicControl = nil
                    lastQuadControl = nil
                    command = 0
                    continue
                }
            }

            guard command != 0 else {
                index += 1
                continue
            }

            switch command {
            case 0x4D: // M
                guard let x = readNumber(), let y = readNumber() else { break }
                let pt = CGPoint(x: x, y: y)
                path.move(to: pt, transform: transform)
                current = pt
                subpathStart = pt
                hasCurrentPoint = true
                lastCubicControl = nil
                lastQuadControl = nil
                command = 0x4C // Subsequent pairs become implicit 'L'

            case 0x6D: // m
                guard let dx = readNumber(), let dy = readNumber() else { break }
                let pt = hasCurrentPoint
                    ? CGPoint(x: current.x + dx, y: current.y + dy)
                    : CGPoint(x: dx, y: dy)
                path.move(to: pt, transform: transform)
                current = pt
                subpathStart = pt
                hasCurrentPoint = true
                lastCubicControl = nil
                lastQuadControl = nil
                command = 0x6C // Subsequent pairs become implicit 'l'

            case 0x4C: // L
                guard let x = readNumber(), let y = readNumber() else { break }
                let pt = CGPoint(x: x, y: y)
                path.addLine(to: pt, transform: transform)
                current = pt
                hasCurrentPoint = true
                lastCubicControl = nil
                lastQuadControl = nil

            case 0x6C: // l
                guard let dx = readNumber(), let dy = readNumber() else { break }
                let pt = CGPoint(x: current.x + dx, y: current.y + dy)
                path.addLine(to: pt, transform: transform)
                current = pt
                hasCurrentPoint = true
                lastCubicControl = nil
                lastQuadControl = nil

            case 0x48: // H
                guard let x = readNumber() else { break }
                let pt = CGPoint(x: x, y: current.y)
                path.addLine(to: pt, transform: transform)
                current = pt
                hasCurrentPoint = true
                lastCubicControl = nil
                lastQuadControl = nil

            case 0x68: // h
                guard let dx = readNumber() else { break }
                let pt = CGPoint(x: current.x + dx, y: current.y)
                path.addLine(to: pt, transform: transform)
                current = pt
                hasCurrentPoint = true
                lastCubicControl = nil
                lastQuadControl = nil

            case 0x56: // V
                guard let y = readNumber() else { break }
                let pt = CGPoint(x: current.x, y: y)
                path.addLine(to: pt, transform: transform)
                current = pt
                hasCurrentPoint = true
                lastCubicControl = nil
                lastQuadControl = nil

            case 0x76: // v
                guard let dy = readNumber() else { break }
                let pt = CGPoint(x: current.x, y: current.y + dy)
                path.addLine(to: pt, transform: transform)
                current = pt
                hasCurrentPoint = true
                lastCubicControl = nil
                lastQuadControl = nil

            case 0x43: // C
                guard let x1 = readNumber(), let y1 = readNumber(),
                      let x2 = readNumber(), let y2 = readNumber(),
                      let x = readNumber(), let y = readNumber() else { break }
                let c1 = CGPoint(x: x1, y: y1)
                let c2 = CGPoint(x: x2, y: y2)
                let end = CGPoint(x: x, y: y)
                path.addCurve(to: end, control1: c1, control2: c2, transform: transform)
                current = end
                hasCurrentPoint = true
                lastCubicControl = c2
                lastQuadControl = nil

            case 0x63: // c
                guard let dx1 = readNumber(), let dy1 = readNumber(),
                      let dx2 = readNumber(), let dy2 = readNumber(),
                      let dx = readNumber(), let dy = readNumber() else { break }
                let c1 = CGPoint(x: current.x + dx1, y: current.y + dy1)
                let c2 = CGPoint(x: current.x + dx2, y: current.y + dy2)
                let end = CGPoint(x: current.x + dx, y: current.y + dy)
                path.addCurve(to: end, control1: c1, control2: c2, transform: transform)
                current = end
                hasCurrentPoint = true
                lastCubicControl = c2
                lastQuadControl = nil

            case 0x53: // S
                guard let x2 = readNumber(), let y2 = readNumber(),
                      let x = readNumber(), let y = readNumber() else { break }
                let c1 = lastCubicControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let c2 = CGPoint(x: x2, y: y2)
                let end = CGPoint(x: x, y: y)
                path.addCurve(to: end, control1: c1, control2: c2, transform: transform)
                current = end
                hasCurrentPoint = true
                lastCubicControl = c2
                lastQuadControl = nil

            case 0x73: // s
                guard let dx2 = readNumber(), let dy2 = readNumber(),
                      let dx = readNumber(), let dy = readNumber() else { break }
                let c1 = lastCubicControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let c2 = CGPoint(x: current.x + dx2, y: current.y + dy2)
                let end = CGPoint(x: current.x + dx, y: current.y + dy)
                path.addCurve(to: end, control1: c1, control2: c2, transform: transform)
                current = end
                hasCurrentPoint = true
                lastCubicControl = c2
                lastQuadControl = nil

            case 0x51: // Q
                guard let x1 = readNumber(), let y1 = readNumber(),
                      let x = readNumber(), let y = readNumber() else { break }
                let c1 = CGPoint(x: x1, y: y1)
                let end = CGPoint(x: x, y: y)
                path.addQuadCurve(to: end, control: c1, transform: transform)
                current = end
                hasCurrentPoint = true
                lastQuadControl = c1
                lastCubicControl = nil

            case 0x71: // q
                guard let dx1 = readNumber(), let dy1 = readNumber(),
                      let dx = readNumber(), let dy = readNumber() else { break }
                let c1 = CGPoint(x: current.x + dx1, y: current.y + dy1)
                let end = CGPoint(x: current.x + dx, y: current.y + dy)
                path.addQuadCurve(to: end, control: c1, transform: transform)
                current = end
                hasCurrentPoint = true
                lastQuadControl = c1
                lastCubicControl = nil

            case 0x54: // T
                guard let x = readNumber(), let y = readNumber() else { break }
                let c1 = lastQuadControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let end = CGPoint(x: x, y: y)
                path.addQuadCurve(to: end, control: c1, transform: transform)
                current = end
                hasCurrentPoint = true
                lastQuadControl = c1
                lastCubicControl = nil

            case 0x74: // t
                guard let dx = readNumber(), let dy = readNumber() else { break }
                let c1 = lastQuadControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let end = CGPoint(x: current.x + dx, y: current.y + dy)
                path.addQuadCurve(to: end, control: c1, transform: transform)
                current = end
                hasCurrentPoint = true
                lastQuadControl = c1
                lastCubicControl = nil

            default:
                command = 0
            }
        }

        return path.copy() ?? CGPath(rect: .zero, transform: nil)
    }

    public static func swiftUIPath(_ d: String, transform: CGAffineTransform = .identity) -> Path {
        Path(parse(d, transform: transform))
    }
}

/// Exact vector geometry extracted from `tourbox_lite.svg` (`viewBox="0 0 480 455"`),
/// with hidden highlight layers stripped and `shape_short`'s `translate(-12 -5)` baked in.
public struct TourBoxLiteArtwork: Sendable {
    private struct ImmutablePathBox: @unchecked Sendable {
        let path: CGPath
        init(_ path: CGPath) {
            self.path = path.copy() ?? path
        }
    }

    private struct ImmutablePathArrayBox: @unchecked Sendable {
        let paths: [CGPath]
        init(_ paths: [CGPath]) {
            self.paths = paths.map { $0.copy() ?? $0 }
        }
    }

    public struct CircleGeometry: Equatable, Sendable {
        public let center: CGPoint
        public let radius: CGFloat

        public init(cx: CGFloat, cy: CGFloat, r: CGFloat) {
            self.center = CGPoint(x: cx, y: cy)
            self.radius = r
        }

        public var rect: CGRect {
            CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        }

        public func cgPath(transform: CGAffineTransform = .identity) -> CGPath {
            withUnsafePointer(to: transform) { ptr in
                CGPath(ellipseIn: rect, transform: ptr)
            }
        }

        public func path(transform: CGAffineTransform = .identity) -> Path {
            Path(cgPath(transform: transform))
        }
    }

    public struct ControlGeometry: Identifiable, @unchecked Sendable {
        public let id: String
        #if canImport(TourMixCore)
        public let controlId: TourBoxControlId
        #endif
        public let title: String
        public let cgPath: CGPath
        public let boundingBox: CGRect
        public let center: CGPoint
        public let labelAnchor: CGPoint

        #if canImport(TourMixCore)
        public init(
            controlId: TourBoxControlId,
            title: String,
            cgPath: CGPath,
            center: CGPoint? = nil,
            labelAnchor: CGPoint
        ) {
            let immutable = cgPath.copy() ?? cgPath
            self.id = controlId.rawValue
            self.controlId = controlId
            self.title = title
            self.cgPath = immutable
            let box = immutable.boundingBoxOfPath
            self.boundingBox = box
            self.center = center ?? CGPoint(x: box.midX, y: box.midY)
            self.labelAnchor = labelAnchor
        }
        #else
        public init(
            id: String,
            title: String,
            cgPath: CGPath,
            center: CGPoint? = nil,
            labelAnchor: CGPoint
        ) {
            let immutable = cgPath.copy() ?? cgPath
            self.id = id
            self.title = title
            self.cgPath = immutable
            let box = immutable.boundingBoxOfPath
            self.boundingBox = box
            self.center = center ?? CGPoint(x: box.midX, y: box.midY)
            self.labelAnchor = labelAnchor
        }
        #endif

        public var path: Path {
            Path(cgPath)
        }

        public func transformedPath(_ transform: CGAffineTransform) -> Path {
            Path(cgPath).applying(transform)
        }
    }

    // MARK: - ViewBox & Coordinate Transform

    public static let viewBox = CGSize(width: 480, height: 455)
    public static let viewBoxRect = CGRect(x: 0, y: 0, width: 480, height: 455)

    /// Computes an aspect-fit affine transform mapping `480 x 455` artwork space centered into `canvasSize`.
    public static func aspectFitTransform(in canvasSize: CGSize, padding: CGFloat = 0) -> CGAffineTransform {
        let availableW = max(1, canvasSize.width - padding * 2)
        let availableH = max(1, canvasSize.height - padding * 2)
        let scale = min(availableW / viewBox.width, availableH / viewBox.height)
        let scaledW = viewBox.width * scale
        let scaledH = viewBox.height * scale
        let offsetX = (canvasSize.width - scaledW) * 0.5
        let offsetY = (canvasSize.height - scaledH) * 0.5
        return CGAffineTransform(translationX: offsetX, y: offsetY).scaledBy(x: scale, y: scale)
    }

    // MARK: - Raw SVG Strings (<g id="outline"> & <defs>)

    public static let outerBodySVG =
        "M147 7 C98 7 63 23 40 52 C12 87 10 119 10 180 L10 309 C10 359 13 390 39 416 C62 439 94 449 130 447 C168 444 190 432 237 433 C281 433 308 445 342 443 C384 442 417 425 439 398 C461 371 467 342 467 294 L467 162 C467 109 460 78 441 49 C420 18 385 7 345 7 Z"

    public static let innerBodySVG =
        "M147 23 C99 23 72 35 51 64 C29 94 27 123 27 177 L27 310 C27 351 31 381 51 402 C72 424 99 432 131 430 C170 427 191 416 237 417 C282 417 309 431 341 428 C377 426 407 411 426 387 C445 363 449 335 449 292 L449 163 C449 115 443 86 425 61 C406 34 379 23 345 23 Z"

    public static let topBarSVG = "M176 83 H252"

    public static let scrollGrooveSVGs: [String] = [
        "M84 114 Q95 111 107 114",
        "M84 126 Q95 123 107 126",
        "M84 138 Q95 135 107 138",
        "M84 150 Q95 147 107 150",
        "M84 162 Q95 159 107 162",
        "M84 174 Q95 171 107 174"
    ]

    public static let shapeTourSVG =
        "m 126.3942,330.3324 c 7.0041,7.3627 16.6115,11.226 29.0427,3.8876 3.1643,-1.672 6.1231,-4.577 9.1473,-7.0892 2.6542,-2.8342 1.0918,-4.7781 -0.7432,-6.7461 -4.3177,-2.5945 -8.3549,-6.6296 -12.063,-11.2055 -3.7892,-4.1074 -6.6856,-9.7773 -9.2617,-16.0078 -1.3443,-3.2325 -3.6487,-4.028 -6.9748,-2.2297 -3.1755,2.5312 -6.5118,4.848 -9.2617,7.9467 -9.9173,12.9701 -6.7049,23.2868 0.1143,31.4439 z"

    public static let shapeTallSVG =
        "M319 286 Q312 292 312 312 L311 365 Q310 379 305 385 Q301 396 323 398 L348 398 Q365 397 366 377 L366 321 Q365 288 355 284 Q337 278 319 286 Z"

    public static let shapeShortSVG =
        "M397 315 C418 310 434 330 435 355 L435 381 Q434 396 415 397 L393 397 Q382 397 382 380 L382 341 Q382 321 397 315 Z"

    public static let shapeShortTransform = CGAffineTransform(translationX: -12, y: -5)

    // MARK: - Body & Decorative Geometry

    private static let _outerBodyPath = ImmutablePathBox(SVGPathParser.parse(outerBodySVG))
    /// Outer chassis contour (`path25`, SVG stroke-width `1.4`).
    public static var outerBodyPath: CGPath { _outerBodyPath.path }

    private static let _innerBodyPath = ImmutablePathBox(SVGPathParser.parse(innerBodySVG))
    /// Inner recessed contour (`path26`, SVG stroke-width `0.7`).
    public static var innerBodyPath: CGPath { _innerBodyPath.path }

    /// Knob outer recess circle (`circle26`: cx=237, cy=227, r=70).
    public static let knobRecessCircle = CircleGeometry(cx: 237, cy: 227, r: 70)

    /// Knob inner top cap circle (`circle27`: cx=237, cy=227, r=32).
    public static let knobInnerCircle = CircleGeometry(cx: 237, cy: 227, r: 32)

    /// 12 rotary dial tick dots surrounding the central knob (`circle45`..`circle56`, r=2.2).
    public static let knobTickDots: [CircleGeometry] = [
        CircleGeometry(cx: 237.00, cy: 187.00, r: 2.2),
        CircleGeometry(cx: 257.00, cy: 192.36, r: 2.2),
        CircleGeometry(cx: 271.64, cy: 207.00, r: 2.2),
        CircleGeometry(cx: 277.00, cy: 227.00, r: 2.2),
        CircleGeometry(cx: 271.64, cy: 247.00, r: 2.2),
        CircleGeometry(cx: 257.00, cy: 261.64, r: 2.2),
        CircleGeometry(cx: 237.00, cy: 267.00, r: 2.2),
        CircleGeometry(cx: 217.00, cy: 261.64, r: 2.2),
        CircleGeometry(cx: 202.36, cy: 247.00, r: 2.2),
        CircleGeometry(cx: 197.00, cy: 227.00, r: 2.2),
        CircleGeometry(cx: 202.36, cy: 207.00, r: 2.2),
        CircleGeometry(cx: 217.00, cy: 192.36, r: 2.2)
    ]

    private static let _topBarPath = ImmutablePathBox(SVGPathParser.parse(topBarSVG))
    /// Horizontal tactile ridge on Top button (`path34`: `M176 83 H252`, SVG stroke-width `3`).
    public static var topBarPath: CGPath { _topBarPath.path }

    private static let _scrollGroovePaths = ImmutablePathArrayBox(scrollGrooveSVGs.map { SVGPathParser.parse($0) })
    /// 6 anti-slip tread grooves on Scroll wheel (`path35`..`path40`).
    public static var scrollGroovePaths: [CGPath] { _scrollGroovePaths.paths }

    private static let _scrollGroovesCombinedPath: ImmutablePathBox = {
        let combined = CGMutablePath()
        for groove in _scrollGroovePaths.paths {
            combined.addPath(groove)
        }
        return ImmutablePathBox(combined.copy() ?? CGPath(rect: .zero, transform: nil))
    }()
    /// Combined path of all 6 Scroll wheel anti-slip grooves for single-pass rendering.
    public static var scrollGroovesCombinedPath: CGPath { _scrollGroovesCombinedPath.path }

    /// 3 tactile blind dots on Tall button (`circle40`..`circle42`, r=2.0).
    public static let tallBlindDots: [CircleGeometry] = [
        CircleGeometry(cx: 339, cy: 322, r: 2.0),
        CircleGeometry(cx: 339, cy: 342, r: 2.0),
        CircleGeometry(cx: 339, cy: 362, r: 2.0)
    ]

    /// Tactile center dot on C1 button (`circle43`: cx=341, cy=151, r=2.0).
    public static let c1CenterDot = CircleGeometry(cx: 341, cy: 151, r: 2.0)

    /// Tactile center dot on C2 button (`circle44`: cx=395, cy=188, r=2.0).
    public static let c2CenterDot = CircleGeometry(cx: 395, cy: 188, r: 2.0)

    // MARK: - 8 Interactive Control Regions

    public static let top: ControlGeometry = {
        let path = CGPath(
            roundedRect: CGRect(x: 150, y: 57, width: 128, height: 53),
            cornerWidth: 26,
            cornerHeight: 26,
            transform: nil
        )
        #if canImport(TourMixCore)
        return ControlGeometry(controlId: .top, title: "Top", cgPath: path, labelAnchor: CGPoint(x: 214, y: 42))
        #else
        return ControlGeometry(id: "top", title: "Top", cgPath: path, labelAnchor: CGPoint(x: 214, y: 42))
        #endif
    }()

    public static let scroll: ControlGeometry = {
        let path = CGPath(
            roundedRect: CGRect(x: 80, y: 104, width: 31, height: 76),
            cornerWidth: 14,
            cornerHeight: 14,
            transform: nil
        )
        #if canImport(TourMixCore)
        return ControlGeometry(controlId: .scroll, title: "Scroll", cgPath: path, labelAnchor: CGPoint(x: 95.5, y: 88))
        #else
        return ControlGeometry(id: "scroll", title: "Scroll", cgPath: path, labelAnchor: CGPoint(x: 95.5, y: 88))
        #endif
    }()

    public static let knob: ControlGeometry = {
        let path = CircleGeometry(cx: 237, cy: 227, r: 45).cgPath()
        #if canImport(TourMixCore)
        return ControlGeometry(
            controlId: .knob,
            title: "Knob",
            cgPath: path,
            center: CGPoint(x: 237, y: 227),
            labelAnchor: CGPoint(x: 237, y: 147.2)
        )
        #else
        return ControlGeometry(
            id: "knob",
            title: "Knob",
            cgPath: path,
            center: CGPoint(x: 237, y: 227),
            labelAnchor: CGPoint(x: 237, y: 147.2)
        )
        #endif
    }()

    public static let c1: ControlGeometry = {
        let path = CircleGeometry(cx: 341, cy: 151, r: 21).cgPath()
        #if canImport(TourMixCore)
        return ControlGeometry(
            controlId: .c1,
            title: "C1",
            cgPath: path,
            center: CGPoint(x: 341, y: 151),
            labelAnchor: CGPoint(x: 341, y: 117)
        )
        #else
        return ControlGeometry(
            id: "c1",
            title: "C1",
            cgPath: path,
            center: CGPoint(x: 341, y: 151),
            labelAnchor: CGPoint(x: 341, y: 117)
        )
        #endif
    }()

    public static let c2: ControlGeometry = {
        let path = CircleGeometry(cx: 395, cy: 188, r: 21).cgPath()
        #if canImport(TourMixCore)
        return ControlGeometry(
            controlId: .c2,
            title: "C2",
            cgPath: path,
            center: CGPoint(x: 395, y: 188),
            labelAnchor: CGPoint(x: 411, y: 157)
        )
        #else
        return ControlGeometry(
            id: "c2",
            title: "C2",
            cgPath: path,
            center: CGPoint(x: 395, y: 188),
            labelAnchor: CGPoint(x: 411, y: 157)
        )
        #endif
    }()

    public static let tour: ControlGeometry = {
        let path = SVGPathParser.parse(shapeTourSVG)
        #if canImport(TourMixCore)
        return ControlGeometry(controlId: .tour, title: "Tour", cgPath: path, labelAnchor: CGPoint(x: 135, y: 280))
        #else
        return ControlGeometry(id: "tour", title: "Tour", cgPath: path, labelAnchor: CGPoint(x: 135, y: 280))
        #endif
    }()

    public static let tall: ControlGeometry = {
        let path = SVGPathParser.parse(shapeTallSVG)
        #if canImport(TourMixCore)
        return ControlGeometry(controlId: .tall, title: "Tall", cgPath: path, labelAnchor: CGPoint(x: 340, y: 271))
        #else
        return ControlGeometry(id: "tall", title: "Tall", cgPath: path, labelAnchor: CGPoint(x: 340, y: 271))
        #endif
    }()

    /// Right-most short button with SVG `<g id="shape_short" transform="translate(-12 -5)">` applied automatically.
    public static let short: ControlGeometry = {
        let path = SVGPathParser.parse(shapeShortSVG, transform: shapeShortTransform)
        #if canImport(TourMixCore)
        return ControlGeometry(controlId: .short, title: "Short", cgPath: path, labelAnchor: CGPoint(x: 402, y: 301))
        #else
        return ControlGeometry(id: "short", title: "Short", cgPath: path, labelAnchor: CGPoint(x: 402, y: 301))
        #endif
    }()

    /// All 8 interactive controls in deterministic layout order.
    public static let controls: [ControlGeometry] = [
        top, scroll, knob, c1, c2, tour, tall, short
    ]

    public static func control(forID id: String) -> ControlGeometry? {
        switch id {
        case "top": return top
        case "scroll": return scroll
        case "knob": return knob
        case "c1": return c1
        case "c2": return c2
        case "tour": return tour
        case "tall": return tall
        case "short": return short
        default: return nil
        }
    }

    #if canImport(TourMixCore)
    public static func control(for controlId: TourBoxControlId) -> ControlGeometry {
        switch controlId {
        case .top: return top
        case .scroll: return scroll
        case .knob: return knob
        case .c1: return c1
        case .c2: return c2
        case .tour: return tour
        case .tall: return tall
        case .short: return short
        }
    }
    #endif
}
