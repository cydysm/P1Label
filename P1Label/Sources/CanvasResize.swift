// SPDX-License-Identifier: GPL-3.0-or-later
//
// This file is part of P1Label, a macOS label printing app for the
// Detong P1 thermal label printer.
// Copyright (C) 2026 P1Label authors
//
// P1Label is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along with
// this program. If not, see <https://www.gnu.org/licenses/>.
//
// Pure geometry for the canvas' bottom-right resize handle. Lives outside the
// SwiftUI view so the exact production math can be compiled into a probe /
// harness without a window (same idea as tools/drag_harness).
//
// Contract: `preview` turns pointer movement since the press into a uniform
// scale of the element. The drag's leading axis — the axis the pointer pushed
// relatively further — is tracked 1:1 by the *rendered* box, so the drawn
// handle stays under the cursor on that axis; the other axis follows
// proportionally (uniform scale cannot be free-form).
//
// The solve runs in measurement space on purpose: CoreText text width is not
// exactly proportional to font size (SF Pro's optical sizing makes a 2.2%
// difference over 30→72 dots), and QR/barcode raster widths are integer
// quantized. Scaling the font by the pointer ratio alone leaves the handle
// lagging by up to ~2% of the box (visible at 200% zoom). Instead we measure
// the candidate box and correct the parameter so the rendered leading edge
// lands on the pointer.
//
// Clamps are real limits only — paper edge, the Inspector's font/size ranges
// (12–72 / 24–160) and the wrap-width floor. In particular the text wrap width
// is NOT used as a scale clamp: auto-width text has a wrap close to the paper
// width, so clamping on it froze the handle after ~3% growth (user-reported
// "手柄不紧贴").

import CoreGraphics
import Foundation

enum CanvasResize {
    /// Preview values for a live resize (document is not touched).
    struct Preview: Equatable {
        /// Uniform scale that was applied (rendered-box based, not the raw
        /// pointer ratio when measurement correction kicked in).
        var ratio: CGFloat
        var fontSize: CGFloat
        var size: Int
        /// Text wrap width for the preview. Scales with the font so the number
        /// of lines (and therefore the rendered box) stays proportional.
        var wrapWidth: Int
        /// True when the pointer ran past a real limit and the handle is
        /// pinned there instead of following the cursor.
        var limited: Bool
    }

    static let minFontSize: CGFloat = 12
    static let maxFontSize: CGFloat = 72
    static let minCodeSize: Int = 24
    static let maxCodeSize: Int = 160
    static let minWrapWidth: Int = 32

    /// - Parameters:
    ///   - base: element state when the gesture began.
    ///   - translation: pointer movement since the press, in viewport points.
    ///   - scale: canvas scale (viewport points per paper dot).
    ///   - printableWidth: paper width in dots.
    ///   - paperHeight: paper height in dots.
    static func preview(base: LabelElement, translation: CGSize, scale: CGFloat,
                        printableWidth: Int, paperHeight: Int) -> Preview? {
        guard scale > 0 else { return nil }

        // Rendered box of the base element in dots — exactly what the selection
        // frame and handle are drawn from.
        let w0 = base.displayWidth(fontSize: base.fontSize, size: base.size, x: base.x,
                                   width: base.width, printableWidth: printableWidth)
        let h0 = base.displayHeight(fontSize: base.fontSize, size: base.size, x: base.x,
                                    width: base.width, printableWidth: printableWidth)
        guard w0 > 0, h0 > 0 else { return nil }   // empty text: nothing to anchor on

        // Pointer movement in dots. Leading axis = the axis the pointer pushed
        // relatively further; its rendered edge is what we target.
        let dxDots = translation.width / scale
        let dyDots = translation.height / scale
        let rx = 1 + dxDots / CGFloat(w0)
        let ry = 1 + dyDots / CGFloat(h0)
        let xLeads = rx >= ry
        let targetLead = xLeads ? CGFloat(w0) + dxDots : CGFloat(h0) + dyDots

        // Paper budget: right/bottom edge, in dots.
        let fitW = max(1, CGFloat(printableWidth - base.x))
        let fitH = max(1, CGFloat(paperHeight - base.y))

        switch base.kind {
        case .text:
            return textPreview(base: base, xLeads: xLeads, targetLead: targetLead,
                               rawRatio: max(rx, ry), fitW: fitW, fitH: fitH,
                               printableWidth: printableWidth)
        case .qr, .barcode:
            return codePreview(base: base, xLeads: xLeads, targetLead: targetLead,
                               rawRatio: max(rx, ry), fitW: fitW, fitH: fitH)
        }
    }

    // MARK: - Text

    private static func textPreview(base: LabelElement, xLeads: Bool, targetLead: CGFloat,
                                    rawRatio: CGFloat, fitW: CGFloat, fitH: CGFloat,
                                    printableWidth: Int) -> Preview? {
        let fs0 = base.fontSize
        let baseWrap = base.width > 0
            ? CGFloat(base.width)
            : CGFloat(base.wrapWidth(at: base.x, printableWidth: printableWidth))
        guard baseWrap > 0 else { return nil }

        // Does the text actually wrap at its base wrap width? Only then is the
        // wrap width load-bearing for the rendered box / line count.
        let fullInk = base.text.isEmpty ? 0
            : LabelRenderer.measureText(text: base.text, fontSize: fs0,
                                        bold: base.bold, width: 100_000).1
        let wraps = fullInk > Int(baseWrap)

        // Wrap width is scaled with the font. The upper clamp version is used
        // for the final value; measurements use the unclamped one so an
        // over-limit candidate cannot wrap early while we are still solving.
        let solveWrap = { (fs: CGFloat) -> Int in
            max(minWrapWidth, Int((baseWrap * (fs / fs0)).rounded()))
        }
        let finalWrap = { (fs: CGFloat) -> Int in
            min(solveWrap(fs), Int(fitW.rounded()))
        }
        let box = { (fs: CGFloat) -> (w: Int, h: Int) in
            let wp = solveWrap(fs)
            var e = base
            e.fontSize = fs
            e.width = wp
            return (e.displayWidth(fontSize: fs, size: e.size, x: base.x,
                                   width: wp, printableWidth: printableWidth),
                    e.displayHeight(fontSize: fs, size: e.size, x: base.x,
                                    width: wp, printableWidth: printableWidth))
        }

        // Parameter range. Wrapped text needs a floor on the wrap width so the
        // line count cannot change while shrinking.
        var fsMin = minFontSize
        if wraps { fsMin = max(fsMin, fs0 * CGFloat(minWrapWidth) / baseWrap) }
        var fsMax = maxFontSize
        if wraps { fsMax = min(fsMax, fs0 * fitW / baseWrap) }
        guard fsMin <= fsMax else { return nil }

        var fs = min(max(fs0 * rawRatio, fsMin), fsMax)

        // Coordinate-descent on the leading rendered dimension. Nearly linear,
        // so a few steps get sub-dot accuracy. Rendered sizes are integer
        // dots, so keep the candidate that lands closest to the target — the
        // last iterate can be one quantization step off.
        var bestFS = fs
        var bestErr = CGFloat.greatestFiniteMagnitude
        for _ in 0..<4 {
            let b = box(fs)
            let m = xLeads ? b.w : b.h
            guard m > 0 else { break }
            let err = abs(CGFloat(m) - targetLead)
            if err < bestErr { bestErr = err; bestFS = fs }
            let next = min(max(fs * targetLead / CGFloat(m), fsMin), fsMax)
            if abs(next - fs) < 0.05 { break }
            fs = next
        }
        fs = bestFS

        // Paper limits, measured on the rendered box (not on the linear ratio).
        // Ink-limited text keeps 2 dots of slack so the wrap width can be
        // clamped to the paper on commit without crossing the ink width.
        var limited = false
        for _ in 0..<3 {
            let b = box(fs)
            let inkBudget = max(1, fitW - 2)
            var k: CGFloat = 1
            if CGFloat(b.w) > fitW { k = min(k, fitW / CGFloat(b.w)) }
            if CGFloat(b.h) > fitH { k = min(k, fitH / CGFloat(b.h)) }
            if !wraps && CGFloat(b.w) > inkBudget {
                k = min(k, inkBudget / CGFloat(b.w))
            }
            if k >= 1 { break }
            limited = true
            fs = max(fsMin, fs * k)
        }
        // Model (Inspector) range is a hard stop.
        if fs < fsMin - 1e-6 || fs > fsMax + 1e-6 { limited = true }
        fs = min(max(fs, fsMin), fsMax)

        let finalBox = box(fs)
        let achieved = xLeads ? finalBox.w : finalBox.h
        if abs(CGFloat(achieved) - targetLead) > 1.0 { limited = true }

        return Preview(ratio: fs / fs0,
                       fontSize: fs,
                       size: base.size,
                       wrapWidth: finalWrap(fs),
                       limited: limited)
    }

    // MARK: - QR / barcode

    private static func codePreview(base: LabelElement, xLeads: Bool, targetLead: CGFloat,
                                    rawRatio: CGFloat, fitW: CGFloat,
                                    fitH: CGFloat) -> Preview {
        let p0 = CGFloat(max(base.size, 1))
        let minSide = CGFloat(minCodeSize)
        let maxSide = CGFloat(maxCodeSize)

        let box = { (side: CGFloat) -> (w: Int, h: Int) in
            let sz = Int(side.rounded())
            let w = base.kind == .qr
                ? sz
                : LabelRenderer.barcodeWidth(text: base.text, height: sz)
            return (w, sz)
        }

        var side = min(max(p0 * rawRatio, minSide), maxSide)
        for _ in 0..<3 {
            let b = box(side)
            let m = xLeads ? b.w : b.h
            guard m > 0 else { break }
            side = min(max(side * targetLead / CGFloat(m), minSide), maxSide)
        }

        var limited = false
        for _ in 0..<3 {
            let b = box(side)
            var k: CGFloat = 1
            if CGFloat(b.w) > fitW { k = min(k, fitW / CGFloat(b.w)) }
            if CGFloat(b.h) > fitH { k = min(k, fitH / CGFloat(b.h)) }
            if k >= 1 { break }
            limited = true
            side = max(minSide, side * k)
        }
        if side <= minSide + 1e-6 || side >= maxSide - 1e-6 { limited = true }

        let finalSide = min(max(Int(side.rounded()), minCodeSize), maxCodeSize)
        let finalBox = box(CGFloat(finalSide))
        let achieved = xLeads ? finalBox.w : finalBox.h
        if abs(CGFloat(achieved) - targetLead) > 1.0 { limited = true }

        return Preview(ratio: CGFloat(finalSide) / p0,
                       fontSize: base.fontSize,
                       size: finalSide,
                       wrapWidth: base.width,
                       limited: limited)
    }
}
