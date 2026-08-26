// IconGen.swift — standalone CLI tool that renders PowerUp.app's icon and
// writes a finished .icns file. Compiled ad-hoc by scripts/build.sh with
// `swiftc scripts/IconGen.swift -o <tmp>/icongen`, then run as:
//   icongen <output-path-to-AppIcon.icns>
//
// No NSApplication / app lifecycle needed — everything here is offscreen
// drawing into NSBitmapImageRep-backed graphics contexts, which works fine
// from a bare command-line process.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Master artwork

/// Renders the full 1024x1024 master icon (with alpha) into an NSBitmapImageRep.
func renderMasterIcon() -> NSBitmapImageRep {
    let size = 1024
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalErrorSafe("Could not allocate master NSBitmapImageRep")
    }
    rep.size = NSSize(width: size, height: size)

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalErrorSafe("Could not create NSGraphicsContext for master rep")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.interpolationQuality = .high

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)

    // Transparent background — clear the canvas explicitly.
    cg.clear(canvas)

    // Centered 832x832 squircle, corner radius ~186.
    let squircleSide: CGFloat = 832
    let cornerRadius: CGFloat = 186
    let origin = CGPoint(x: (CGFloat(size) - squircleSide) / 2.0,
                          y: (CGFloat(size) - squircleSide) / 2.0)
    let squircleRect = CGRect(origin: origin, size: CGSize(width: squircleSide, height: squircleSide))
    let squirclePath = NSBezierPath(roundedRect: squircleRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Clip to the squircle for everything that follows (gradient + glow + symbol).
    cg.saveGState()
    squirclePath.addClip()

    // Diagonal gradient: deep navy (bottom-left) -> indigo -> electric blue (top-right).
    let navy = NSColor(calibratedRed: 0x0B / 255.0, green: 0x12 / 255.0, blue: 0x20 / 255.0, alpha: 1.0)
    let indigo = NSColor(calibratedRed: 0x1E / 255.0, green: 0x3A / 255.0, blue: 0x8A / 255.0, alpha: 1.0)
    let electricBlue = NSColor(calibratedRed: 0x3B / 255.0, green: 0x82 / 255.0, blue: 0xF6 / 255.0, alpha: 1.0)

    if let gradient = NSGradient(colorsAndLocations:
        (navy, 0.0), (indigo, 0.55), (electricBlue, 1.0)
    ) {
        gradient.draw(from: CGPoint(x: squircleRect.minX, y: squircleRect.minY),
                       to: CGPoint(x: squircleRect.maxX, y: squircleRect.maxY),
                       options: [])
    } else {
        // Fallback: flat fill so we never leave the squircle blank.
        indigo.setFill()
        squirclePath.fill()
    }

    // Subtle lighter radial glow, top-left.
    let glowCenter = CGPoint(x: squircleRect.minX + squircleRect.width * 0.28,
                              y: squircleRect.maxY - squircleRect.height * 0.28)
    let glowColorInner = NSColor(calibratedWhite: 1.0, alpha: 0.22)
    let glowColorOuter = NSColor(calibratedWhite: 1.0, alpha: 0.0)
    if let glow = NSGradient(starting: glowColorInner, ending: glowColorOuter) {
        glow.draw(fromCenter: glowCenter, radius: 0,
                   toCenter: glowCenter, radius: squircleRect.width * 0.55,
                   options: [])
    }

    cg.restoreGState() // undo squircle clip

    // Centered white gamecontroller.fill SF Symbol (~440pt), with fallback to "PU" monogram.
    drawSymbolOrMonogram(in: cg, canvasSize: size)

    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return rep
}

/// Draws the white gamecontroller.fill SF Symbol centered on the canvas with a slight
/// drop shadow. Falls back to a "PU" text monogram if the symbol can't be resolved
/// or rendered — this path must never leave the icon blank.
func drawSymbolOrMonogram(in cg: CGContext, canvasSize: Int) {
    let pointSize: CGFloat = 440
    let center = CGPoint(x: CGFloat(canvasSize) / 2.0, y: CGFloat(canvasSize) / 2.0)

    if let symbolImage = makeTintedSymbolImage(
        symbolName: "gamecontroller.fill",
        pointSize: pointSize,
        weight: .medium,
        tint: .white
    ) {
        let imgSize = symbolImage.size
        if imgSize.width > 0 && imgSize.height > 0 {
            let drawRect = CGRect(
                x: center.x - imgSize.width / 2.0,
                y: center.y - imgSize.height / 2.0,
                width: imgSize.width,
                height: imgSize.height
            )

            cg.saveGState()
            // Slight drop shadow behind the symbol.
            cg.setShadow(
                offset: CGSize(width: 0, height: -10),
                blur: 24,
                color: NSColor(calibratedWhite: 0.0, alpha: 0.35).cgColor
            )
            if let cgImage = symbolImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cg.draw(cgImage, in: drawRect)
            }
            cg.restoreGState()
            return
        }
    }

    // Fallback: white rounded "PU" monogram text.
    drawMonogramFallback(in: cg, center: center, canvasSize: canvasSize)
}

/// Builds a white-tinted NSImage from an SF Symbol name at the given point size/weight.
/// Renders through an NSBitmapImageRep-backed context (not lockFocus) so pixel dimensions
/// are explicit and predictable.
func makeTintedSymbolImage(symbolName: String, pointSize: CGFloat, weight: NSFont.Weight, tint: NSColor) -> NSImage? {
    guard let baseSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
        return nil
    }

    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let configured = baseSymbol.withSymbolConfiguration(config) else {
        return nil
    }

    // Rasterize the symbol at its reported size (points == pixels here since we
    // are building our own bitmap rep at an explicit pixel size).
    let width = max(Int(configured.size.width.rounded(.up)), 1)
    let height = max(Int(configured.size.height.rounded(.up)), 1)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }
    rep.size = NSSize(width: width, height: height)

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.interpolationQuality = .high

    let drawRect = CGRect(x: 0, y: 0, width: width, height: height)

    // Draw the symbol's own template artwork, then tint white via sourceAtop —
    // this guarantees a solid white glyph regardless of the symbol's rendering mode.
    configured.isTemplate = true
    configured.draw(in: drawRect)
    tint.setFill()
    drawRect.fill(using: .sourceAtop)

    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    let result = NSImage(size: NSSize(width: width, height: height))
    result.addRepresentation(rep)

    // Sanity check: make sure something non-transparent actually landed in the
    // bitmap (guards against a "successfully drew nothing" symbol lookup).
    guard bitmapHasVisibleContent(rep) else { return nil }

    return result
}

/// Quick check that a bitmap isn't fully transparent — samples a grid of pixels.
func bitmapHasVisibleContent(_ rep: NSBitmapImageRep) -> Bool {
    let w = rep.pixelsWide
    let h = rep.pixelsHigh
    guard w > 0, h > 0 else { return false }
    let stepX = max(w / 24, 1)
    let stepY = max(h / 24, 1)
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                return true
            }
            x += stepX
        }
        y += stepY
    }
    return false
}

/// Draws a simple white rounded "PU" monogram, used only if the SF Symbol lookup
/// or rendering fails for any reason.
func drawMonogramFallback(in cg: CGContext, center: CGPoint, canvasSize: Int) {
    let text = "PU"
    let fontSize: CGFloat = 420
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ]
    let attributed = NSAttributedString(string: text, attributes: attrs)
    let textSize = attributed.size()
    let drawRect = CGRect(
        x: center.x - textSize.width / 2.0,
        y: center.y - textSize.height / 2.0,
        width: textSize.width,
        height: textSize.height
    )

    NSGraphicsContext.saveGraphicsState()
    let nsContext = NSGraphicsContext(cgContext: cg, flipped: false)
    NSGraphicsContext.current = nsContext
    cg.saveGState()
    cg.setShadow(
        offset: CGSize(width: 0, height: -8),
        blur: 20,
        color: NSColor(calibratedWhite: 0.0, alpha: 0.35).cgColor
    )
    attributed.draw(in: drawRect)
    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    _ = canvasSize
}

func fatalErrorSafe(_ message: String) -> Never {
    FileHandle.standardError.write(("icongen: " + message + "\n").data(using: .utf8) ?? Data())
    exit(1)
}

// MARK: - Scaling + PNG emission

/// Scales the master 1024x1024 CGImage down to the requested pixel size using
/// high-quality interpolation, returning PNG data.
func pngData(fromMaster masterCG: CGImage, pixelSize: Int) -> Data? {
    guard pixelSize > 0 else { return nil }

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.interpolationQuality = .high
    cg.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    cg.draw(masterCG, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

struct IconSizeSpec {
    let filename: String
    let pixelSize: Int
}

// Required iconset contents, including @2x pairs.
let iconSizeSpecs: [IconSizeSpec] = [
    IconSizeSpec(filename: "icon_16x16.png", pixelSize: 16),
    IconSizeSpec(filename: "icon_16x16@2x.png", pixelSize: 32),
    IconSizeSpec(filename: "icon_32x32.png", pixelSize: 32),
    IconSizeSpec(filename: "icon_32x32@2x.png", pixelSize: 64),
    IconSizeSpec(filename: "icon_128x128.png", pixelSize: 128),
    IconSizeSpec(filename: "icon_128x128@2x.png", pixelSize: 256),
    IconSizeSpec(filename: "icon_256x256.png", pixelSize: 256),
    IconSizeSpec(filename: "icon_256x256@2x.png", pixelSize: 512),
    IconSizeSpec(filename: "icon_512x512.png", pixelSize: 512),
    IconSizeSpec(filename: "icon_512x512@2x.png", pixelSize: 1024),
]

// MARK: - Main

func run() {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        fatalErrorSafe("usage: icongen <output-path-to-AppIcon.icns>")
    }
    let outputPath = args[1]

    let masterRep = renderMasterIcon()
    guard let masterCG = masterRep.cgImage else {
        fatalErrorSafe("Could not obtain CGImage from master rep")
    }

    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("IconGen-\(ProcessInfo.processInfo.globallyUniqueString)")
    let iconsetDir = tempDir.appendingPathComponent("AppIcon.iconset")

    let fm = FileManager.default
    do {
        try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
    } catch {
        fatalErrorSafe("Could not create iconset directory: \(error)")
    }

    for spec in iconSizeSpecs {
        guard let data = pngData(fromMaster: masterCG, pixelSize: spec.pixelSize) else {
            fatalErrorSafe("Could not render PNG for \(spec.filename)")
        }
        // Guard against a genuinely blank/near-empty PNG (sanity check requested by spec).
        guard data.count > 200 else {
            fatalErrorSafe("PNG for \(spec.filename) is suspiciously small (\(data.count) bytes) — icon artwork may be missing")
        }
        let fileURL = iconsetDir.appendingPathComponent(spec.filename)
        do {
            try data.write(to: fileURL)
        } catch {
            fatalErrorSafe("Could not write \(spec.filename): \(error)")
        }
    }

    // Ensure the parent directory of the requested output path exists.
    let outputURL = URL(fileURLWithPath: outputPath)
    do {
        try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
        fatalErrorSafe("Could not create output directory: \(error)")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetDir.path, "-o", outputURL.path]

    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        fatalErrorSafe("Could not launch iconutil: \(error)")
    }
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        fatalErrorSafe("iconutil failed (exit \(process.terminationStatus)): \(errText)")
    }

    // Clean up the temp iconset directory.
    try? fm.removeItem(at: tempDir)

    guard fm.fileExists(atPath: outputURL.path) else {
        fatalErrorSafe("iconutil reported success but \(outputURL.path) does not exist")
    }

    print("icongen: wrote \(outputURL.path)")
}

run()
