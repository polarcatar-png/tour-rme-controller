#!/usr/bin/env swift
import AppKit
import CoreGraphics
import SwiftUI

// Usage: swift scripts/generate_icon.swift <source_square_image> [output_icns_path]
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift scripts/generate_icon.swift <source_square_image> [output_icns_path]\n", stderr)
    exit(1)
}

let sourcePath = CommandLine.arguments[1]
let outputIcnsPath = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "Resources/AppIcon.icns"

guard let nsImage = NSImage(contentsOfFile: sourcePath),
      let cgSource = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    fputs("Failed to load source image at \(sourcePath)\n", stderr)
    exit(1)
}

@MainActor
func renderSquircleIcon(size: CGFloat) -> NSBitmapImageRep {
    let scale = size / 1024.0
    let bodySize = 824.0 * scale
    let cornerRadius = 185.4 * scale

    let iconView = ZStack {
        Image(decorative: cgSource, scale: 1.0)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: bodySize, height: bodySize)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                Color.white.opacity(0.08),
                                Color.black.opacity(0.45)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: max(1.0, 2.2 * scale)
                    )
            )
            .shadow(color: Color.black.opacity(0.36), radius: 14 * scale, x: 0, y: 10 * scale)
    }
    .frame(width: size, height: size)

    let renderer = ImageRenderer(content: iconView)
    renderer.scale = 1.0
    renderer.isOpaque = false

    guard let cgRendered = renderer.cgImage else {
        fatalError("Failed to render icon at size \(size)")
    }
    let rep = NSBitmapImageRep(cgImage: cgRendered)
    rep.size = NSSize(width: size, height: size)
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 1)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

MainActor.assumeIsolated {
    do {
        let fm = FileManager.default
        let tempIconset = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TourMix_\(UUID().uuidString).iconset")
        try fm.createDirectory(at: tempIconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempIconset) }

        let specs: [(name: String, pixels: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024)
        ]

        for spec in specs {
            let rep = renderSquircleIcon(size: CGFloat(spec.pixels))
            try writePNG(rep, to: tempIconset.appendingPathComponent(spec.name).path)
        }

        let outDir = URL(fileURLWithPath: outputIcnsPath).deletingLastPathComponent()
        if !outDir.path.isEmpty {
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        proc.arguments = ["-c", "icns", tempIconset.path, "-o", outputIcnsPath]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            exit(proc.terminationStatus)
        }
        print("Generated \(outputIcnsPath)")
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}
