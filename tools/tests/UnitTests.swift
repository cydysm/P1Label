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
// Standalone unit tests for pure-Swift P1Label modules (LPAPI, HistoryStack,
// PaperPreset, LabelRenderer, CanvasResize). Run via `tools/run_tests.sh`.

import CoreGraphics
import Foundation

private var passed = 0
private var failed = 0

private func check(_ cond: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if cond {
        passed += 1
    } else {
        failed += 1
        fputs("FAIL \(file):\(line): \(msg)\n", stderr)
    }
}

private func checkEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if a == b {
        passed += 1
    } else {
        failed += 1
        fputs("FAIL \(file):\(line): \(msg) — got \(a), expected \(b)\n", stderr)
    }
}

// MARK: - LPAPI protocol tests

private func testLPAPI() {
    // EBV 1-byte (< 192) and 2-byte (>= 192)
    checkEqual(LPAPI.ebv(0), [0], "ebv(0)")
    checkEqual(LPAPI.ebv(191), [191], "ebv(191)")
    checkEqual(LPAPI.ebv(192), [192, 192], "ebv(192)")
    checkEqual(LPAPI.ebv(300), [UInt8((300 >> 8) | 192), UInt8(300 & 0xFF)], "ebv(300)")

    // Frame + parsePackages round-trip (short and long payloads)
    let shortFrame = LPAPI.frame(LPAPI.deviceNameCmd, [0x50, 0x31])
    checkEqual(shortFrame, [0x1F, 121, 2, 0x50, 0x31, 0x88], "short frame wire bytes")

    let longPayload = [UInt8](repeating: 0xAB, count: 200)
    let longFrame = LPAPI.frame(LPAPI.softwareVersionCmd, longPayload)
    let stream: [UInt8] = [0x00, 0xFF] + shortFrame + longFrame + [0x1F, 121] // trailing incomplete
    let (pkgs, leftover) = LPAPI.parsePackages(stream)
    checkEqual(pkgs.count, 2, "parsed package count")
    if pkgs.count == 2 {
        checkEqual(pkgs[0].cmd, LPAPI.deviceNameCmd, "pkg 0 cmd")
        checkEqual(pkgs[0].data, [0x50, 0x31], "pkg 0 data")
        checkEqual(pkgs[1].cmd, LPAPI.softwareVersionCmd, "pkg 1 cmd")
        checkEqual(pkgs[1].data, longPayload, "pkg 1 data")
    }
    checkEqual(leftover, [0x1F, 121], "leftover incomplete frame")

    // blankLines splitting at 255
    checkEqual(LPAPI.blankLines(0), [], "blankLines(0)")
    checkEqual(LPAPI.blankLines(10), [27, 74, 10], "blankLines(10)")
    checkEqual(LPAPI.blankLines(260), [27, 74, 255, 27, 74, 5], "blankLines(260)")

    // encodeRows: blank run + repeated non-zero row + trailing zero trimming
    let blank = [UInt8](repeating: 0, count: 4)
    let ink: [UInt8] = [0xFF, 0x80, 0x00, 0x00]
    let encoded = LPAPI.encodeRows([blank, blank, ink, ink, ink])
    let expected: [UInt8] = [27, 74, 2]
        + [LPAPI.start, LPAPI.bitmapPrint, 0, 2, 0xFF, 0x80]
        + [LPAPI.start, LPAPI.bitmapRepeat, 1]
    checkEqual(encoded, expected, "encodeRows blank + repeat + trim")
}

// MARK: - HistoryStack tests

private func testHistoryStack() {
    var stack = HistoryStack()
    var d0 = LabelDocument()
    d0.widthMM = 40
    var d1 = d0; d1.widthMM = 42
    var d2 = d0; d2.widthMM = 44

    let e0 = HistoryEntry(doc: d0, selection: [])
    let e1 = HistoryEntry(doc: d1, selection: [])
    let e2 = HistoryEntry(doc: d2, selection: [])

    check(stack.undo(current: e0) == nil, "empty undo returns nil")
    check(stack.redo(current: e0) == nil, "empty redo returns nil")

    stack.record(e0)
    stack.record(e1)
    let u1 = stack.undo(current: e2)
    checkEqual(u1, e1, "first undo restores e1")
    let u0 = stack.undo(current: e1)
    checkEqual(u0, e0, "second undo restores e0")
    check(stack.undo(current: e0) == nil, "third undo returns nil")

    let r1 = stack.redo(current: e0)
    checkEqual(r1, e1, "redo restores e1")
    // Recording a new mutation clears redo tail.
    stack.record(e1)
    check(stack.redo(current: e2) == nil, "record clears redo stack")

    // Cap at 100 entries
    var capped = HistoryStack()
    for i in 0..<120 {
        var d = LabelDocument()
        d.gapLenMM = Double(i)
        capped.record(HistoryEntry(doc: d, selection: []))
    }
    checkEqual(capped.entries.count, 100, "history stack capped at 100")
    checkEqual(capped.entries.first?.doc.gapLenMM, 20.0, "oldest entries evicted first")
}

// MARK: - PaperSizes & LabelRenderer tests

private func testPaperAndRenderer() {
    let def = LabelDocument()
    let matched = PaperPreset.matching(widthMM: def.widthMM, heightMM: def.heightMM,
                                       isDieCut: def.isDieCut, gapLenMM: def.gapLenMM)
    check(matched != nil, "default 40x30 document matches a paper preset")
    checkEqual(matched?.hardwareVerified, true, "default 40x30 preset is hardwareVerified")

    let sz = LabelRenderer.contentSize(def)
    check(sz.width > 0 && sz.height > 0, "contentSize positive")
    checkEqual(sz.width % 8, 0, "contentSize width byte-aligned")

    let payload = LabelRenderer.pagePayload(def, pageKey: 1, copies: 1,
                                            gapType: 2, gapLenHundredthsMM: 200)
    check(payload.last == 0x0C, "pagePayload terminates with form feed 0x0C")
    check(payload.count > 20, "pagePayload non-trivial")
}

// MARK: - CanvasResize tests

private func testCanvasResize() {
    let doc = LabelDocument()
    let pw = LabelRenderer.paperWidthDots(doc)
    let ph = LabelRenderer.contentSize(doc).height
    let s: CGFloat = 2.0

    guard let textEl = doc.elements.first(where: { $0.kind == .text }) else {
        check(false, "default document has a text element")
        return
    }
    let w0 = textEl.displayWidth(fontSize: textEl.fontSize, size: textEl.size,
                                 x: textEl.x, width: textEl.width, printableWidth: pw)

    // Zero translation -> ratio ~ 1, unchanged fontSize
    if let p0 = CanvasResize.preview(base: textEl, translation: .zero, scale: s,
                                     printableWidth: pw, paperHeight: ph) {
        check(abs(p0.fontSize - textEl.fontSize) < 0.01, "zero drag keeps fontSize")
        checkEqual(p0.limited, false, "zero drag not limited")
    } else {
        check(false, "zero drag preview non-nil")
    }

    // Horizontal grow by +40pt (= +20 dots at s=2): rendered width should track target within 2 dots
    let dxPt: CGFloat = 40
    if let p = CanvasResize.preview(base: textEl, translation: CGSize(width: dxPt, height: 0),
                                    scale: s, printableWidth: pw, paperHeight: ph) {
        let wNew = textEl.displayWidth(fontSize: p.fontSize, size: p.size,
                                       x: textEl.x, width: p.wrapWidth, printableWidth: pw)
        let targetW = CGFloat(w0) + dxPt / s
        check(abs(CGFloat(wNew) - targetW) <= 2.0, "text resize tracks leading axis (got \(wNew), target \(targetW))")
        check(p.fontSize > textEl.fontSize, "grow increases fontSize")
    } else {
        check(false, "grow preview non-nil")
    }

    // Huge drag hits limit and stays inside paper & font bounds
    if let pMax = CanvasResize.preview(base: textEl, translation: CGSize(width: 2000, height: 2000),
                                       scale: s, printableWidth: pw, paperHeight: ph) {
        checkEqual(pMax.limited, true, "huge drag sets limited = true")
        check(pMax.fontSize <= CanvasResize.maxFontSize + 1e-6, "fontSize clamped to max")
        let wNew = textEl.displayWidth(fontSize: pMax.fontSize, size: pMax.size,
                                       x: textEl.x, width: pMax.wrapWidth, printableWidth: pw)
        check(textEl.x + wNew <= pw, "resized box stays inside paper width")
    } else {
        check(false, "huge drag preview non-nil")
    }
}

@main
struct P1LabelUnitTests {
    static func main() {
        testLPAPI()
        testHistoryStack()
        testPaperAndRenderer()
        testCanvasResize()

        print("P1Label unit tests: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
