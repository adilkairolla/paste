#!/usr/bin/env swift
// Renders AppIcon.icns — a deck of cards on a gradient tile.
// Usage: swift scripts/make_icon.swift <output-directory>

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let outputDirectory = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : ".")

func drawIcon(size: CGFloat) -> CGImage? {
    let scale = size / 1024
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.scaleBy(x: scale, y: scale)

    // Rounded tile with a vertical gradient.
    let inset: CGFloat = 60
    let tile = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 200, cornerHeight: 200, transform: nil)
    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    let colors = [
        CGColor(red: 0.42, green: 0.32, blue: 0.94, alpha: 1),
        CGColor(red: 0.24, green: 0.51, blue: 0.96, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 1024),
            end: CGPoint(x: 1024, y: 0),
            options: []
        )
    }
    context.restoreGState()

    // Three stacked cards, back to front.
    let cards: [(CGRect, CGFloat, CGFloat)] = [
        (CGRect(x: 300, y: 300, width: 430, height: 300), 0.35, 8),
        (CGRect(x: 270, y: 360, width: 470, height: 320), 0.62, 8),
        (CGRect(x: 250, y: 420, width: 510, height: 340), 1.0, 8),
    ]
    for (rect, alpha, _) in cards {
        let path = CGPath(roundedRect: rect, cornerWidth: 44, cornerHeight: 44, transform: nil)
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: CGColor(gray: 0, alpha: 0.22))
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: alpha))
        context.fillPath()
    }
    context.setShadow(offset: .zero, blur: 0, color: nil)

    // Text lines on the front card.
    context.setFillColor(CGColor(red: 0.32, green: 0.36, blue: 0.52, alpha: 0.85))
    for (index, width) in [330.0, 260.0, 300.0].enumerated() {
        let y = 640 - CGFloat(index) * 70
        let line = CGRect(x: 300, y: y, width: width, height: 34)
        context.addPath(CGPath(roundedRect: line, cornerWidth: 17, cornerHeight: 17, transform: nil))
        context.fillPath()
    }

    return context.makeImage()
}

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = drawIcon(size: variant.size) else { continue }
    let url = iconset.appendingPathComponent("\(variant.name).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        continue
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = [
    "-c", "icns",
    iconset.path,
    "-o", outputDirectory.appendingPathComponent("AppIcon.icns").path,
]
try convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote \(outputDirectory.appendingPathComponent("AppIcon.icns").path)")
