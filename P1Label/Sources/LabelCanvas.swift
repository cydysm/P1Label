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
// Interactive label canvas: paper preview, live drag/resize preview and
// selection. Kept in its own file so the exact same view can be exercised by a
// standalone drag harness as well as by the shipping app.
//
// How the drag works
// ------------------
// All pointer handling lives on ONE gesture surface that covers the paper and
// never moves while a drag is in flight. Element hit-testing is done manually in
// paper coordinates, and the live preview is rendered from local state; `doc` is
// written exactly once, when the gesture ends.
//
// This matters: when the view that owns the DragGesture is itself moved during
// the drag (the old per-element transparent hit areas were offset every frame),
// SwiftUI resolves the gesture's location against a coordinate space that is
// moving under the pointer. The element then trails the cursor, jumps and leaves
// a stale-looking double image. A static gesture surface removes that feedback
// loop completely.
//
// Alignment guides: while moving, update() snaps the proposed position onto
// other elements' and the paper's edge/center lines and records the hit for
// liveLayer to draw. Snapping adjusts dx/dy before the preview offset is
// computed — it changes numbers, never the gesture surface itself.

import SwiftUI

struct LabelCanvas: View {
    @Binding var doc: LabelDocument
    @Binding var selectedID: UUID?
    @Binding var scale: CGFloat

    @State private var pinchBase: CGFloat?
    /// Paper-space point of the current mouse press (used for tap-to-deselect).
    @State private var pressStart: CGPoint?
    /// Live drag preview. Local state only — no document writes per frame.
    @State private var drag: Drag?
    /// Element queued for deletion; the confirmation alert runs before it is
    /// actually removed.
    @State private var pendingDelete: LabelElement?

    enum Mode { case move, resize }

    struct Drag {
        var id: UUID
        var mode: Mode
        /// Gesture start in paper points (the gesture surface never moves).
        var start: CGPoint
        /// Element as it was when the gesture began.
        var base: LabelElement
        /// Live translation in dots (whole dots = the document's unit).
        var dx: Int = 0
        var dy: Int = 0
        var fontSize: CGFloat?
        var size: Int?
        /// Alignment guides while moving: the snapped coordinate in dots
        /// (nil per axis = nothing snapped this frame).
        var guideX: CGFloat?
        var guideY: CGFloat?
    }

    var body: some View {
        GeometryReader { geo in
            let (wDots, hDots) = LabelRenderer.contentSize(doc)
            let s = max(min(scale, 6), 0.5)
            let paperW = CGFloat(wDots) * s
            let paperH = CGFloat(hDots) * s

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // Static layer: every element NOT being live-dragged. Its
                    // inputs (elements, scale) don't change during a drag and the
                    // Equatable conformance lets SwiftUI skip re-rendering it, so
                    // a drag frame only repaints the small live layer below.
                    ElementsCanvas(elements: staticElements, s: s, printableWidth: printableWidth)
                        .equatable()
                        .frame(width: paperW, height: paperH)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)

                    // Per-frame layer: dragged element at its live position plus
                    // the selection box for the selected element.
                    liveLayer(s: s)
                        .frame(width: paperW, height: paperH)
                        .allowsHitTesting(false)

                    // Single, static gesture surface (see file header).
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: paperW, height: paperH)
                        .gesture(paperGesture(s: s))

                    // Delete badge for the selected element, above the gesture
                    // surface so a click lands on the badge; taps elsewhere
                    // fall through (no background content shape) to the paper
                    // gesture. Hidden while a drag previews — the badge would
                    // sit at the element's pre-drag corner and read as a ghost.
                    if drag == nil {
                        deleteButtons(s: s)
                            .frame(width: paperW, height: paperH)
                    }
                }
                .frame(width: paperW + 40, height: paperH + 40, alignment: .topLeading)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .background(Color(red: 0xDC / 255, green: 0xE0 / 255, blue: 0xE9 / 255))
            .gesture(
                MagnificationGesture()
                    .onChanged { v in
                        let base = pinchBase ?? scale
                        if pinchBase == nil { pinchBase = scale }
                        scale = max(0.5, min(base * v, 6))
                    }
                    .onEnded { _ in pinchBase = nil }
            )
            .alert("删除元素",
                   isPresented: Binding(
                       get: { pendingDelete != nil },
                       set: { if !$0 { pendingDelete = nil } }
                   )) {
                Button("删除", role: .destructive) {
                    if let el = pendingDelete { removeElement(el) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                if let el = pendingDelete {
                    Text(Self.deleteConfirmMessage(el))
                }
            }
        }
    }

    // MARK: - Live preview state

    /// Element position/size with the live preview applied.
    private func effective(_ el: LabelElement) -> (x: Int, y: Int, fontSize: CGFloat, size: Int) {
        guard let d = drag, d.id == el.id else { return (el.x, el.y, el.fontSize, el.size) }
        return (el.x + d.dx, el.y + d.dy, d.fontSize ?? el.fontSize, d.size ?? el.size)
    }

    /// All elements except the one being live-dragged (otherwise it would ghost
    /// underneath the live copy).
    private var staticElements: [LabelElement] {
        guard let d = drag else { return doc.elements }
        return doc.elements.filter { $0.id != d.id }
    }

    /// The doc's printable width in dots (raster minus calibration insets).
    /// Measurement and clamps use this so the canvas matches what actually
    /// prints — essential for narrower paper presets.
    private var printableWidth: Int {
        LabelRenderer.paperWidthDots(doc)
    }

    /// Element bounds in paper points.
    private func elementRect(_ el: LabelElement, s: CGFloat,
                             x: Int, y: Int, fontSize: CGFloat, size: Int) -> CGRect {
        let w = CGFloat(el.displayWidth(fontSize: fontSize, size: size, x: x,
                                        printableWidth: printableWidth)) * s
        let h = CGFloat(el.displayHeight(fontSize: fontSize, size: size, x: x,
                                         printableWidth: printableWidth)) * s
        return CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: w, height: h)
    }

    private func elementRect(_ el: LabelElement, s: CGFloat) -> CGRect {
        elementRect(el, s: s, x: el.x, y: el.y, fontSize: el.fontSize, size: el.size)
    }

    // MARK: - Gesture

    private func paperGesture(s: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if pressStart == nil {
                    pressStart = g.startLocation
                    beginDrag(at: g.startLocation, s: s)
                }
                guard var d = drag else { return }
                update(&d, with: g, s: s)
                drag = d
            }
            .onEnded { g in
                let start = pressStart ?? g.startLocation
                if drag == nil { beginDrag(at: start, s: s) }
                if var d = drag {
                    update(&d, with: g, s: s)
                    commit(d)
                } else if hypot(g.location.x - start.x, g.location.y - start.y) < 3 {
                    // Plain click on empty paper clears the selection.
                    selectedID = nil
                }
                drag = nil
                pressStart = nil
            }
    }

    /// Topmost element under a paper-space point (last drawn wins).
    private func hitTest(_ point: CGPoint, s: CGFloat) -> LabelElement? {
        for el in doc.elements.reversed() {
            var rect = elementRect(el, s: s).insetBy(dx: -4, dy: -4)
            // Keep tiny/empty elements grabbable.
            if rect.width < 12 { rect = rect.insetBy(dx: -(12 - rect.width) / 2, dy: 0) }
            if rect.height < 12 { rect = rect.insetBy(dx: 0, dy: -(12 - rect.height) / 2) }
            if rect.contains(point) { return el }
        }
        return nil
    }

    private func beginDrag(at point: CGPoint, s: CGFloat) {
        guard let el = hitTest(point, s: s) else { return }
        selectedID = el.id
        let rect = elementRect(el, s: s)
        // The resize handle is drawn at the element's bottom-right corner.
        let nearHandle = hypot(point.x - rect.maxX, point.y - rect.maxY) < 20
        drag = Drag(id: el.id, mode: nearHandle ? .resize : .move, start: point, base: el)
    }

    private func update(_ d: inout Drag, with g: DragGesture.Value, s: CGFloat) {
        switch d.mode {
        case .move:
            var tx = d.base.x + Int((g.translation.width / s).rounded())
            var ty = d.base.y + Int((g.translation.height / s).rounded())
            let guides = snapped(tx: &tx, ty: &ty, moving: d.base, s: s)
            d.guideX = guides.x
            d.guideY = guides.y
            d.dx = tx - d.base.x
            d.dy = ty - d.base.y
        case .resize:
            let rect = elementRect(d.base, s: s)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let startDist = max(hypot(d.start.x - center.x, d.start.y - center.y), 8)
            let dist = max(hypot(g.location.x - center.x, g.location.y - center.y), 4)
            let ratio = max(0.2, min(5.0, dist / startDist))
            switch d.base.kind {
            case .text:
                d.fontSize = min(72, max(12, (d.base.fontSize * ratio).rounded()))
            case .qr, .barcode:
                d.size = Int(min(200, max(24, (CGFloat(d.base.size) * ratio).rounded())))
            }
        }
    }

    // MARK: - Alignment guides

    /// Snap radius in screen points, converted to dots per frame — the same
    /// physical pointer distance triggers the snap at every zoom level.
    private static let snapRadiusPoints: CGFloat = 8

    /// Snap the proposed position (inout, dots) onto other elements' and the
    /// paper's left/center/right + top/center/bottom lines. Returns the guide
    /// coordinates (dots) to draw, nil per axis when nothing snapped.
    ///
    /// Runs before the preview offset is derived from dx/dy: snapping adjusts
    /// numbers only, the gesture surface never moves (see file header).
    private func snapped(tx: inout Int, ty: inout Int, moving el: LabelElement,
                         s: CGFloat) -> (x: CGFloat?, y: CGFloat?) {
        let th = Double(Self.snapRadiusPoints / s)
        let w = CGFloat(el.displayWidth(fontSize: el.fontSize, size: el.size, x: tx,
                                        printableWidth: printableWidth))
        let h = CGFloat(el.displayHeight(fontSize: el.fontSize, size: el.size, x: tx,
                                         printableWidth: printableWidth))
        let rect = CGRect(x: CGFloat(tx), y: CGFloat(ty), width: w, height: h)

        // Paper edges + center, then every other element's edges + center.
        let (wDots, hDots) = LabelRenderer.contentSize(doc)
        var xs: [CGFloat] = [0, CGFloat(wDots) / 2, CGFloat(wDots)]
        var ys: [CGFloat] = [0, CGFloat(hDots) / 2, CGFloat(hDots)]
        for other in doc.elements where other.id != el.id {
            let r = elementRect(other, s: 1)   // s = 1 → dots
            xs += [r.minX, r.midX, r.maxX]
            ys += [r.minY, r.midY, r.maxY]
        }

        // Nearest target within the radius for one axis. Edge kinds are
        // 0/1/2 = min/mid/max of the dragged rect.
        func snapAxis(_ edges: [CGFloat], targets: [CGFloat]) -> (target: CGFloat, edge: Int, delta: Double)? {
            var best: (target: CGFloat, edge: Int, delta: Double)?
            for (i, e) in edges.enumerated() {
                for t in targets {
                    let d = abs(Double(e - t))
                    if d <= th, best == nil || d < best!.delta {
                        best = (t, i, d)
                    }
                }
            }
            return best
        }

        var guideX: CGFloat?
        if let hit = snapAxis([rect.minX, rect.midX, rect.maxX], targets: xs) {
            let newTX: CGFloat
            switch hit.edge {
            case 0: newTX = hit.target
            case 1: newTX = hit.target - w / 2
            default: newTX = hit.target - w
            }
            tx = max(0, Int(newTX.rounded()))
            guideX = hit.target
        }
        var guideY: CGFloat?
        if let hit = snapAxis([rect.minY, rect.midY, rect.maxY], targets: ys) {
            let newTY: CGFloat
            switch hit.edge {
            case 0: newTY = hit.target
            case 1: newTY = hit.target - h / 2
            default: newTY = hit.target - h
            }
            ty = max(0, Int(newTY.rounded()))
            guideY = hit.target
        }
        return (guideX, guideY)
    }

    private func commit(_ d: Drag) {
        guard let idx = doc.elements.firstIndex(where: { $0.id == d.id }) else { return }
        switch d.mode {
        case .move:
            guard d.dx != 0 || d.dy != 0 else { return }
            doc.elements[idx].x = max(0, min(d.base.x + d.dx, printableWidth))
            doc.elements[idx].y = max(0, min(d.base.y + d.dy, 1200))
        case .resize:
            if let fs = d.fontSize, fs != doc.elements[idx].fontSize {
                doc.elements[idx].fontSize = fs
            }
            if let sz = d.size, sz != doc.elements[idx].size {
                doc.elements[idx].size = sz
            }
        }
    }

    // MARK: - Canvas paint layers

    private func liveLayer(s: CGFloat) -> some View {
        Canvas { ctx, size in
            // Alignment guides while moving — drawn under the dragged element.
            if let d = drag, d.mode == .move {
                let style = StrokeStyle(lineWidth: 1, dash: [4, 3])
                if let gx = d.guideX {
                    var p = Path()
                    p.move(to: CGPoint(x: CGFloat(gx) * s, y: 0))
                    p.addLine(to: CGPoint(x: CGFloat(gx) * s, y: size.height))
                    ctx.stroke(p, with: .color(.pink), style: style)
                }
                if let gy = d.guideY {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: CGFloat(gy) * s))
                    p.addLine(to: CGPoint(x: size.width, y: CGFloat(gy) * s))
                    ctx.stroke(p, with: .color(.pink), style: style)
                }
            }
            guard let sel = doc.elements.first(where: { $0.id == selectedID }) else { return }
            let eff = effective(sel)
            if drag?.id == sel.id {
                ElementsCanvas.drawOne(sel, x: eff.x, y: eff.y, fontSize: eff.fontSize,
                                       size: eff.size, s: s, printableWidth: printableWidth, into: &ctx)
            }
            let rect = elementRect(sel, s: s, x: eff.x, y: eff.y,
                                   fontSize: eff.fontSize, size: eff.size)
            drawSelectionBox(rect, into: &ctx)
        }
    }

    private func drawSelectionBox(_ rect: CGRect, into ctx: inout GraphicsContext) {
        ctx.stroke(Path(rect.insetBy(dx: -2, dy: -2)), with: .color(.blue), lineWidth: 1)
        let handle = CGRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 12, height: 12)
        ctx.fill(Path(ellipseIn: handle), with: .color(.blue))
        ctx.stroke(Path(ellipseIn: handle.insetBy(dx: -1.5, dy: -1.5)),
                   with: .color(.white), lineWidth: 1.5)
    }

    // MARK: - Per-element delete

    /// Trash-can badge for the SELECTED element only, centered on the
    /// selection box's top-right corner (the resize handle owns the
    /// bottom-right one). Solid red dot with a white ring and the trash
    /// glyph — red so deletion reads as destructive, in contrast to the
    /// blue selection handles. Deletion goes through the confirmation
    /// alert (pendingDelete) before the element is removed.
    @ViewBuilder
    private func deleteButtons(s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let el = doc.elements.first(where: { $0.id == selectedID }) {
                let rect = elementRect(el, s: s)
                Button {
                    pendingDelete = el
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.red))
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("删除该元素")
                // Centered on the selection box's corner (the box is stroked
                // 2pt outside the element rect). Nudged inside the paper at
                // the top/left edges, where the scroll content has no margin
                // to overflow into.
                .position(x: max(rect.maxX + 2, 10), y: max(rect.minY - 2, 10))
            }
        }
    }

    private func removeElement(_ el: LabelElement) {
        doc.elements.removeAll { $0.id == el.id }
        if selectedID == el.id { selectedID = nil }
    }

    private static func deleteConfirmMessage(_ el: LabelElement) -> String {
        let snippet = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = snippet.isEmpty
            ? "这个\(el.kind.label)元素"
            : "\(el.kind.label)“\(snippet.prefix(12))”"
        return "确定删除\(named)吗？删除后无法恢复。"
    }

    /// Static paper layer. Equatable so SwiftUI skips re-rendering it when only
    /// the drag preview changes. printableWidth is part of the identity: a
    /// paper-size change alters auto wrap widths, so the layer must repaint.
    private struct ElementsCanvas: View, Equatable {
        let elements: [LabelElement]
        let s: CGFloat
        let printableWidth: Int

        static func == (a: ElementsCanvas, b: ElementsCanvas) -> Bool {
            a.s == b.s && a.printableWidth == b.printableWidth && a.elements == b.elements
        }

        var body: some View {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                for el in elements {
                    Self.drawOne(el, x: el.x, y: el.y, fontSize: el.fontSize,
                                 size: el.size, s: s, printableWidth: printableWidth, into: &ctx)
                }
            }
        }

        static func drawOne(_ el: LabelElement, x: Int, y: Int, fontSize: CGFloat,
                            size: Int, s: CGFloat, printableWidth: Int,
                            into ctx: inout GraphicsContext) {
            let ew = CGFloat(el.displayWidth(fontSize: fontSize, size: size, x: x,
                                             printableWidth: printableWidth)) * s
            let eh = CGFloat(el.displayHeight(fontSize: fontSize, size: size, x: x,
                                              printableWidth: printableWidth)) * s
            let rect = CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s,
                              width: ew, height: eh)
            switch el.kind {
            case .text:
                let text = Text(el.text)
                    .font(.system(size: fontSize * s, weight: el.bold ? .bold : .regular))
                    .foregroundColor(.black)
                let tw = CGFloat(el.wrapWidth(at: x, printableWidth: printableWidth)) * s
                ctx.draw(text, in: CGRect(x: rect.minX, y: rect.minY, width: tw, height: rect.height))
            case .qr:
                if let cg = LabelRenderer.qrImage(text: el.text, size: size) {
                    ctx.draw(Image(cg, scale: 1, orientation: .up, label: Text("二维码")), in: rect)
                }
            case .barcode:
                if let cg = LabelRenderer.barcodeImage(text: el.text, height: size) {
                    ctx.draw(Image(cg, scale: 1, orientation: .up, label: Text("条码")), in: rect)
                }
            }
        }
    }
}
