import AppKit
import Foundation

private let canvasSize = 1024

struct Layer {
    let sourceName: String
    let outputName: String
}

private func fail(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(1)
}

private func rasterizeSVG(at url: URL) throws -> NSBitmapImageRep {
    guard let image = NSImage(contentsOf: url) else {
        throw NSError(domain: "IconRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open SVG at \(url.path)"])
    }
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canvasSize,
        pixelsHigh: canvasSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not allocate the icon bitmap"])
    }

    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics?.imageInterpolation = .high
    graphics?.cgContext.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
    image.draw(
        in: CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    graphics?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

private func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG at \(url.path)"])
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func composite(_ layers: [NSBitmapImageRep]) throws -> NSBitmapImageRep {
    guard let result = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canvasSize,
        pixelsHigh: canvasSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconRenderer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not allocate the preview bitmap"])
    }
    let graphics = NSGraphicsContext(bitmapImageRep: result)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics?.imageInterpolation = .high
    graphics?.cgContext.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
    for layer in layers {
        NSImage(size: NSSize(width: canvasSize, height: canvasSize), flipped: false) { rect in
            layer.draw(in: rect)
            return true
        }.draw(in: CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
    }
    graphics?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return result
}

let brandDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryRoot = brandDirectory.deletingLastPathComponent().deletingLastPathComponent()
let appIconDirectory = repositoryRoot
    .appendingPathComponent("SimpleVisionGallery/Assets.xcassets/AppIcon.solidimagestack", isDirectory: true)

let layers = [
    Layer(sourceName: "simple-vision-gallery-back.svg", outputName: "Back.solidimagestacklayer/Content.imageset/back.png"),
    Layer(sourceName: "simple-vision-gallery-shadow.svg", outputName: "Middle.solidimagestacklayer/Content.imageset/middle.png"),
    Layer(sourceName: "simple-vision-gallery-foreground.svg", outputName: "Front.solidimagestacklayer/Content.imageset/front.png"),
]

let previewPath: String?
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--preview" {
    previewPath = CommandLine.arguments[2]
} else if CommandLine.arguments.count == 1 {
    previewPath = nil
} else {
    fail("usage: swift resources/brand/render-app-icon-layers.swift [--preview OUTPUT.png]")
}

do {
    var rendered: [NSBitmapImageRep] = []
    for layer in layers {
        let source = brandDirectory.appendingPathComponent(layer.sourceName)
        let output = appIconDirectory.appendingPathComponent(layer.outputName)
        let bitmap = try rasterizeSVG(at: source)
        try writePNG(bitmap, to: output)
        rendered.append(bitmap)
        print("Rendered \(source.lastPathComponent) -> \(output.path)")
    }
    if let previewPath {
        let preview = try composite(rendered)
        try writePNG(preview, to: URL(fileURLWithPath: previewPath))
        print("Wrote composite preview -> \(previewPath)")
    }
} catch {
    fail(error.localizedDescription)
}
