#!/usr/bin/env swift

// Regenerates Sources/Kraken/StaticAssets.swift from the source assets in Assets/.
//
// App icons are rasterized from Assets/icon.svg (the full-bleed square icon; its
// content circle sits inside the maskable safe zone, so the maskable variants use
// the same render). The favicon is resized from Assets/favicon.png.
//
// macOS only (uses AppKit for rasterization). Run with:
//   swift Scripts/GenerateStaticAssets.swift

import AppKit
import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let assetsDir = repoRoot.appendingPathComponent("Assets")
let outputFile = repoRoot.appendingPathComponent("Sources/Kraken/StaticAssets.swift")

func loadImage(_ name: String) -> NSImage {
    let url = assetsDir.appendingPathComponent(name)
    guard let image = NSImage(contentsOf: url) else {
        FileHandle.standardError.write(Data("error: could not load \(url.path)\n".utf8))
        exit(1)
    }
    return image
}

func rasterize(_ image: NSImage, size: Int) -> Data {
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
        FileHandle.standardError.write(Data("error: could not allocate \(size)x\(size) bitmap\n".utf8))
        exit(1)
    }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("error: could not encode PNG at \(size)px\n".utf8))
        exit(1)
    }
    return data
}

let icon = loadImage("icon.svg")
let faviconSource = loadImage("favicon.png")

let icon192 = rasterize(icon, size: 192).base64EncodedString()
let icon512 = rasterize(icon, size: 512).base64EncodedString()
let icon180 = rasterize(icon, size: 180).base64EncodedString()
let iconMaskable192 = rasterize(icon, size: 192).base64EncodedString()
let iconMaskable512 = rasterize(icon, size: 512).base64EncodedString()
let favicon = rasterize(faviconSource, size: 64).base64EncodedString()

let manifestBody = """
{
  "name": "Kraken",
  "short_name": "Kraken",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "background_color": "#161616",
  "theme_color": "#161616",
  "icons": [
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any" },
    { "src": "/icon-maskable-192.png", "sizes": "192x192", "type": "image/png", "purpose": "maskable" },
    { "src": "/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable" }
  ]
}
"""

let serviceWorkerBody = """
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (event) { event.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', function () {});
"""

let output = """
import Foundation

enum StaticAssets {

    static let manifest = #\"\"\"
\(manifestBody)
\"\"\"#

    static let serviceWorker = \"\"\"
\(serviceWorkerBody)
\"\"\"

    static let icon192 = Data(base64Encoded: "\(icon192)")!
    static let icon512 = Data(base64Encoded: "\(icon512)")!
    static let icon180 = Data(base64Encoded: "\(icon180)")!
    static let iconMaskable192 = Data(base64Encoded: "\(iconMaskable192)")!
    static let iconMaskable512 = Data(base64Encoded: "\(iconMaskable512)")!
    static let favicon = Data(base64Encoded: "\(favicon)")!
}

"""

do {
    try output.write(to: outputFile, atomically: true, encoding: .utf8)
    print("Wrote \(outputFile.path)")
} catch {
    FileHandle.standardError.write(Data("error: could not write \(outputFile.path): \(error)\n".utf8))
    exit(1)
}
