#!/usr/bin/env swift
//
// Draws the application icon and assembles Icon.icns.
//
// The icon is code rather than a checked-in binary: it stays diffable, it
// regenerates at every size macOS asks for, and changing the accent colour is
// a one-line edit instead of a round trip through a drawing program.
//
//   swift scripts/make-icon.swift [output-directory]
//
import AppKit
import Foundation

// The mark: a forward slash, the character every path is made of, with a
// terminal cursor sitting next to it. A path, and a place to type one.
// Nothing alpine, no cross, no edelweiss.
enum Palette {
    static let backgroundTop = NSColor(srgbRed: 0.196, green: 0.216, blue: 0.278, alpha: 1)
    static let backgroundBottom = NSColor(srgbRed: 0.075, green: 0.086, blue: 0.125, alpha: 1)
    static let slash = NSColor(srgbRed: 0.949, green: 0.961, blue: 0.976, alpha: 1)
    static let cursor = NSColor(srgbRed: 0.996, green: 0.706, blue: 0.329, alpha: 1)
    static let rim = NSColor(white: 1, alpha: 0.10)
}

func drawIcon(into context: CGContext, size: CGFloat) {
    let scale = size / 1024

    func s(_ value: CGFloat) -> CGFloat { value * scale }
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: s(x), y: s(y)) }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // The squircle. 22.4% of the edge is the radius Apple's own grid uses, and
    // an icon that misses it looks subtly wrong next to everything else.
    let plate = CGRect(x: s(64), y: s(64), width: s(896), height: s(896))
    let squircle = CGPath(
        roundedRect: plate, cornerWidth: s(200), cornerHeight: s(200), transform: nil)

    context.saveGState()
    context.addPath(squircle)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [Palette.backgroundTop.cgColor, Palette.backgroundBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: plate.maxY),
        end: CGPoint(x: 0, y: plate.minY),
        options: []
    )
    context.restoreGState()

    // A hairline rim, so the plate keeps an edge against a dark wallpaper.
    context.addPath(squircle)
    context.setStrokeColor(Palette.rim.cgColor)
    context.setLineWidth(s(6))
    context.strokePath()

    // The slash: a leaning bar, drawn as a polygon so the ends stay square and
    // parallel to the plate rather than to the stroke.
    //
    // The two shapes are positioned as one group, centred on the plate rather
    // than each on its own. Centring them separately leaves the cursor
    // stranded in a corner.
    context.beginPath()
    context.move(to: point(248, 258))
    context.addLine(to: point(413, 258))
    context.addLine(to: point(641, 766))
    context.addLine(to: point(476, 766))
    context.closePath()
    context.setFillColor(Palette.slash.cgColor)
    context.fillPath()

    // The cursor: a block on the same baseline, the one warm thing in the
    // picture. Tall enough to read as a caret rather than as a stray dot.
    let cursor = CGRect(x: s(656), y: s(258), width: s(120), height: s(300))
    context.addPath(
        CGPath(roundedRect: cursor, cornerWidth: s(16), cornerHeight: s(16), transform: nil))
    context.setFillColor(Palette.cursor.cgColor)
    context.fillPath()
}

func render(size: Int) -> Data {
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    drawIcon(into: context, size: CGFloat(size))

    let image = context.makeImage()!
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: size, height: size)
    return representation.representation(using: .png, properties: [:])!
}

let output = CommandLine.arguments.dropFirst().first ?? "build"
let iconset = URL(fileURLWithPath: output).appendingPathComponent("Pfadi.iconset")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The exact set iconutil expects. Anything missing and it refuses the folder.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let file = iconset.appendingPathComponent("\(variant.name).png")
    try render(size: variant.size).write(to: file)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "--convert", "icns",
    "--output", URL(fileURLWithPath: output).appendingPathComponent("Icon.icns").path,
    iconset.path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

print("wrote \(output)/Icon.icns")
