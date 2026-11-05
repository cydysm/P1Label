// Renders icon.svg to a 1024x1024 PNG with a transparent background, using
// AppKit's built-in CoreSVG support (qlmanage thumbnails would flatten the
// rounded plate onto an opaque white square).
//
// Usage: swift render_icon.swift <icon.svg> <out.png>

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: render_icon.swift <icon.svg> <out.png>\n".data(using: .utf8)!)
    exit(2)
}

guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("error: cannot load SVG (CoreSVG parse failed)\n".data(using: .utf8)!)
    exit(1)
}

let size = 1024
guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("bitmap allocation failed")
}
out.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()

guard let png = out.representation(using: .png, properties: [:]) else {
    fatalError("PNG encoding failed")
}
try! png.write(to: URL(fileURLWithPath: args[2]))
