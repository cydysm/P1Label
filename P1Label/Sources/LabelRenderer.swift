// SPDX-License-Identifier: GPL-3.0-or-later
//
// This file is part of P1Label, a macOS label printing app for the
// Detong P1 thermal label printer.
// Copyright (C) 2026 P1Label authors
//
// P1Label is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
// or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Label model + renderer: free-layout elements rendered into a 1-bit raster
// using CoreGraphics / CoreText / CoreImage.

import AppKit
import CoreImage
import CoreText

// MARK: - Element model

struct LabelElement: Identifiable, Equatable, Codable {
    enum Kind: String, Codable, CaseIterable {
        case text, qr, barcode
        var label: String {
            switch self {
            case .text: return "文字"
            case .qr: return "二维码"
            case .barcode: return "条码"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var x: Int = 4            // dots from paper-left
    var y: Int = 4            // dots from paper-top
    var text: String = ""
    var fontSize: CGFloat = 24   // dots (203dpi ≈ 8 dots/mm)
    var bold: Bool = false
    var size: Int = 96           // QR side / barcode height in dots
    var width: Int = 0           // text wrap width in dots; 0 = to paper edge

    enum CodingKeys: String, CodingKey { case id, kind, x, y, text, fontSize, bold, size, width }

    init(kind: Kind, x: Int = 4, y: Int = 4, text: String = "", fontSize: CGFloat = 24,
         bold: Bool = false, size: Int = 96, width: Int = 0) {
        self.kind = kind; self.x = x; self.y = y; self.text = text
        self.fontSize = fontSize; self.bold = bold; self.size = size; self.width = width
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        x = try c.decodeIfPresent(Int.self, forKey: .x) ?? 4
        y = try c.decodeIfPresent(Int.self, forKey: .y) ?? 4
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 24
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 96
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
    }

    // printableWidth defaults to the full head width (legacy behavior); callers
    // that know the document pass the doc's actual printable width so auto wrap
    // and clamps match what the raster will keep.
    func dotsHeight(printableWidth: Int = LabelDocument.paperWidthDots) -> Int {
        switch kind {
        case .qr: return size
        case .barcode: return size
        case .text:
            return LabelRenderer.measureText(text: text, fontSize: fontSize, bold: bold,
                                             width: wrapWidth(printableWidth: printableWidth)).0
        }
    }

    func dotsWidth(printableWidth: Int = LabelDocument.paperWidthDots) -> Int {
        switch kind {
        case .qr: return size
        case .barcode: return LabelRenderer.barcodeWidth(text: text, height: size)
        case .text:
            let w = wrapWidth(printableWidth: printableWidth)
            return min(w, LabelRenderer.measureText(text: text, fontSize: fontSize, bold: bold, width: w).1)
        }
    }

    func wrapWidth(printableWidth: Int = LabelDocument.paperWidthDots) -> Int {
        wrapWidth(at: x, printableWidth: printableWidth)
    }

    func wrapWidth(at xPos: Int, printableWidth: Int = LabelDocument.paperWidthDots) -> Int {
        if width > 0 { return width }
        // bucket auto width to 16-dot steps: x changes every frame while dragging,
        // and an exact width would defeat the CoreText measurement cache
        let raw = max(32, printableWidth - xPos - 8)
        return max(32, (raw / 16) * 16)
    }

    // Preview-aware display helpers (used by the canvas during live drags)
    func displayWidth(fontSize: CGFloat, size: Int, x xPos: Int,
                      printableWidth: Int = LabelDocument.paperWidthDots) -> Int {
        switch kind {
        case .qr: return size
        case .barcode: return LabelRenderer.barcodeWidth(text: text, height: size)
        case .text:
            let w = wrapWidth(at: xPos, printableWidth: printableWidth)
            return min(w, LabelRenderer.measureText(text: text, fontSize: fontSize, bold: bold, width: w).1)
        }
    }

    func displayHeight(fontSize: CGFloat, size: Int, x xPos: Int,
                       printableWidth: Int = LabelDocument.paperWidthDots) -> Int {
        switch kind {
        case .qr, .barcode: return size
        case .text:
            return LabelRenderer.measureText(text: text, fontSize: fontSize, bold: bold,
                                             width: wrapWidth(at: xPos, printableWidth: printableWidth)).0
        }
    }
}

// MARK: - Label document (paper + elements)

struct LabelDocument: Codable, Equatable {
    /// PaperPreset the paper values came from; nil = hand-edited ("自定义").
    /// Optional + default keeps archives saved before presets decodable.
    var presetID: String? = nil
    var widthMM: Double = 40
    var heightMM: Double = 30
    var marginTopMM: Double = 0
    var marginBottomMM: Double = 0
    var darkThreshold: UInt8 = 128
    var rasterWidth: Int = 384
    var leftPadDots: Int = 68
    var elements: [LabelElement] = LabelDocument.defaultElements()

    static let paperWidthDots = 384

    static func defaultElements() -> [LabelElement] {
        [
            LabelElement(kind: .text, x: 6, y: 8, text: "HELLO P1", fontSize: 30, bold: true),
            LabelElement(kind: .qr, x: 210, y: 40, text: "https://example.com", size: 80),
        ]
    }
}

// MARK: - Renderer

enum LabelRenderer {
    static let dotsPerMM = 8.0 // 203 dpi ≈ 8 dots/mm

    // MARK: Measurement / image caches (dragging re-renders every frame)
    private static let cacheLock = NSLock()
    private static var textCache: [String: (h: Int, w: Int)] = [:]
    private static var barWCache: [String: Int] = [:]
    private static var qrImageCache: [String: CGImage?] = [:]
    private static var barcodeImageCache: [String: CGImage?] = [:]

    private static func trimCaches() {
        guard textCache.count > 256 || barWCache.count > 256
                || qrImageCache.count > 128 || barcodeImageCache.count > 128 else { return }
        textCache.removeAll(); barWCache.removeAll()
        qrImageCache.removeAll(); barcodeImageCache.removeAll()
    }

    static let rightInsetDots = 12  // raster 372..383 is off-paper (head margin), calibrated

    static func paperWidthDots(_ doc: LabelDocument) -> Int {
        doc.rasterWidth - doc.leftPadDots - rightInsetDots
    }

    /// Bitmap canvas size in dots.
    static func contentSize(_ doc: LabelDocument) -> (width: Int, height: Int) {
        let w = min(Int((doc.widthMM * dotsPerMM).rounded()), paperWidthDots(doc))
        let h = Int(((doc.heightMM - doc.marginTopMM - doc.marginBottomMM) * dotsPerMM).rounded())
        return (w, max(h, 8))
    }

    /// Render the label to grayscale pixels (0 = black, 255 = white), row-major,
    /// memory row 0 = top of the label (matches raster order).
    static func renderGray(_ doc: LabelDocument) -> (pixels: [UInt8], width: Int, height: Int) {
        let (w, h) = contentSize(doc)
        let printable = paperWidthDots(doc)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return ([UInt8](repeating: 255, count: w * h), w, h) }

        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        for el in doc.elements {
            let ew = el.dotsWidth(printableWidth: printable)
            let eh = el.dotsHeight(printableWidth: printable)
            // element top-left (el.x, el.y) in top-down dots → CG bottom-left rect
            let rect = CGRect(x: CGFloat(el.x), y: CGFloat(h - el.y - eh),
                              width: CGFloat(ew), height: CGFloat(eh))
            switch el.kind {
            case .text:
                drawText(el, in: rect, ctx: ctx)
            case .qr:
                if let qr = qrImage(text: el.text, size: el.size) {
                    ctx.draw(qr, in: rect)
                }
            case .barcode:
                if let bar = barcodeImage(text: el.text, height: el.size) {
                    ctx.draw(bar, in: rect)
                }
            }
        }

        guard let data = ctx.data else { return ([UInt8](repeating: 255, count: w * h), w, h) }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h)
        var pixels = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { pixels[i] = ptr[i] }
        return (pixels, w, h)
    }

    // MARK: Text

    static func attributedText(_ el: LabelElement) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let font = NSFont.systemFont(ofSize: el.fontSize, weight: el.bold ? .bold : .regular)
        return NSAttributedString(string: el.text, attributes: [
            .font: font, .foregroundColor: NSColor.black, .paragraphStyle: para,
        ])
    }

    /// Measure wrapped text height (and used width) in dots.
    static func measureText(text: String, fontSize: CGFloat, bold: Bool, width: Int) -> (Int, Int) {
        guard !text.isEmpty else { return (0, 0) }
        let key = "\(text)|\(fontSize)|\(bold)|\(width)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = textCache[key] { return hit }
        let el = LabelElement(kind: .text, text: text, fontSize: fontSize, bold: bold, width: width)
        let attr = attributedText(el)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: attr.length), nil,
            CGSize(width: CGFloat(width), height: .greatestFiniteMagnitude), nil)
        let result = (max(Int(size.height.rounded(.up)), Int(fontSize)), Int(size.width.rounded(.up)))
        textCache[key] = result
        trimCaches()
        return result
    }

    static func drawText(_ el: LabelElement, in rect: CGRect, ctx: CGContext) {
        guard !el.text.isEmpty else { return }
        let attr = attributedText(el)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        // grow the frame downward without limit so nothing clips
        let path = CGPath(rect: CGRect(x: rect.minX, y: rect.minY - 2000,
                                       width: rect.width, height: rect.height + 2000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attr.length), path, nil)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 2000))
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    // MARK: Raster + page encoding

    /// Threshold grayscale into 1-bit raster rows (MSB first, 1 = black),
    /// applying the calibrated left padding so content lands on the paper.
    static func rasterRows(_ gray: (pixels: [UInt8], width: Int, height: Int), _ doc: LabelDocument) -> [[UInt8]] {
        let (px, w, h) = gray
        let byteWidth = (doc.rasterWidth + 7) / 8
        var rows: [[UInt8]] = []
        for y in 0..<h {
            var row = [UInt8](repeating: 0, count: byteWidth)
            for x in 0..<w {
                if px[y * w + x] < doc.darkThreshold {
                    let sx = x + doc.leftPadDots
                    if sx < doc.rasterWidth {
                        row[sx / 8] |= UInt8(0x80) >> UInt8(sx % 8)
                    }
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Full LPAPI page payload, repeated `copies` times with distinct page keys.
    static func pagePayload(_ doc: LabelDocument, pageKey: Int, copies: Int,
                            gapType: UInt8, gapLenHundredthsMM: Int) -> [UInt8] {
        let gray = renderGray(doc)
        let rows = rasterRows(gray, doc)
        let byteWidth = (doc.rasterWidth + 7) / 8
        // Row body is byte-identical for every copy (only the page key differs),
        // so encode it once.
        let body = LPAPI.encodeRows(rows)
        var out: [UInt8] = []
        for i in 0..<max(copies, 1) {
            out += LPAPI.frame(LPAPI.pageStart, [UInt8(((pageKey + i) >> 8) & 0xFF), UInt8((pageKey + i) & 0xFF)])
            if gapType > 0 {
                out += LPAPI.frame(LPAPI.gapTypeCmd, [gapType])
                out += LPAPI.frame(LPAPI.gapLenCmd, LPAPI.ebv(gapLenHundredthsMM))
            }
            out += LPAPI.frame(LPAPI.pageWidth, LPAPI.ebv(byteWidth))
            out += body
            out += [0x0C]
        }
        return out
    }

    // MARK: CoreImage generators

    /// `pixelScale` > 1 renders a hi-res source for the canvas preview (the
    /// 1× default keeps the print raster byte-identical), and converts the
    /// output to black-on-clear so elements stack without an opaque white box.
    static func qrImage(text: String, size: Int, pixelScale: CGFloat = 1) -> CGImage? {
        guard !text.isEmpty else { return nil }
        cacheLock.lock()
        if let hit = qrImageCache["\(text)|\(size)|\(pixelScale)"] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage,
              var img = ciToCG(out, size: CGSize(width: size, height: size), pixelScale: pixelScale) else {
            return nil
        }
        if pixelScale > 1 { img = Self.blackOnClear(img) ?? img }
        cacheLock.lock(); qrImageCache["\(text)|\(size)|\(pixelScale)"] = img; trimCaches(); cacheLock.unlock()
        return img
    }

    /// See qrImage for the pixelScale contract.
    static func barcodeImage(text: String, height: Int, pixelScale: CGFloat = 1) -> CGImage? {
        guard !text.isEmpty else { return nil }
        cacheLock.lock()
        if let hit = barcodeImageCache["\(text)|\(height)|\(pixelScale)"] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        guard let filter = CIFilter(name: "CICode128BarcodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue(2.0, forKey: "inputQuietSpace")
        guard let out = filter.outputImage,
              var img = ciToCG(out, size: CGSize(width: 800, height: height), pixelScale: pixelScale) else {
            return nil
        }
        if pixelScale > 1 { img = Self.blackOnClear(img) ?? img }
        cacheLock.lock(); barcodeImageCache["\(text)|\(height)|\(pixelScale)"] = img; trimCaches(); cacheLock.unlock()
        return img
    }

    static func barcodeWidth(text: String, height: Int) -> Int {
        guard let cg = barcodeImage(text: text, height: height) else { return height }
        return max(cg.width * height / max(cg.height, 1), height / 2)
    }

    /// CIContext creation is expensive — share one (it is thread-safe for rendering).
    private static let ciContext = CIContext()

    /// Convert a hi-res black-on-white code image to black-on-clear: alpha =
    /// 255 − gray, RGB = 0. Done in CoreGraphics — CIColorMatrix poisons the
    /// render (its extent goes infinite and createCGImage returns nil).
    private static func blackOnClear(_ gray: CGImage) -> CGImage? {
        let w = gray.width, h = gray.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(gray, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let g = base.assumingMemoryBound(to: UInt8.self)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                rgba[o + 3] = 255 - g[y * w + x]   // dark → opaque black
            }
        }
        return rgba.withUnsafeBytes { raw in
            guard let prov = CGDataProvider(data: Data(bytes: raw.baseAddress!, count: w * h * 4) as CFData)
            else { return nil }
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    private static func ciToCG(_ ci: CIImage, size: CGSize, pixelScale: CGFloat = 1) -> CGImage? {
        let target = CGSize(width: size.width * pixelScale, height: size.height * pixelScale)
        let scale = min(target.width / ci.extent.width, target.height / ci.extent.height)
        if !scale.isFinite || scale <= 0 { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let snap = CGRect(x: 0, y: 0, width: scaled.extent.width.rounded(), height: scaled.extent.height.rounded())
        return ciContext.createCGImage(scaled, from: snap)
    }
}
