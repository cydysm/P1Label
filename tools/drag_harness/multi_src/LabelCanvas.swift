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
                    ElementsCanvas(elements: staticElements, s: s)
                        .equatable()
                        .frame(width: paperW, height: paperH)
                        .border(Color.gray.opacity(0.4), width: 1)

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
                }
                .frame(width: paperW + 40, height: paperH + 40, alignment: .topLeading)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .gesture(
                MagnificationGesture()
                    .onChanged { v in
                        let base = pinchBase ?? scale
                        if pinchBase == nil { pinchBase = scale }
                        scale = max(0.5, min(base * v, 6))
                    }
                    .onEnded { _ in pinchBase = nil }
            )
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

    /// Element bounds in paper points.
    private func elementRect(_ el: LabelElement, s: CGFloat,
                             x: Int, y: Int, fontSize: CGFloat, size: Int) -> CGRect {
        let w = CGFloat(el.displayWidth(fontSize: fontSize, size: size, x: x)) * s
        let h = CGFloat(el.displayHeight(fontSize: fontSize, size: size, x: x)) * s
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
            if elementRect(el, s: s).insetBy(dx: -4, dy: -4).contains(point) { return el }
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
            d.dx = Int((g.translation.width / s).rounded())
            d.dy = Int((g.translation.height / s).rounded())
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

    private func commit(_ d: Drag) {
        guard let idx = doc.elements.firstIndex(where: { $0.id == d.id }) else { return }
        switch d.mode {
        case .move:
            guard d.dx != 0 || d.dy != 0 else { return }
            doc.elements[idx].x = max(0, min(d.base.x + d.dx, LabelDocument.paperWidthDots))
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
        Canvas { ctx, _ in
            guard let sel = doc.elements.first(where: { $0.id == selectedID }) else { return }
            let eff = effective(sel)
            if drag?.id == sel.id {
                ElementsCanvas.drawOne(sel, x: eff.x, y: eff.y, fontSize: eff.fontSize,
                                       size: eff.size, s: s, into: &ctx)
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

    /// Static paper layer. Equatable so SwiftUI skips re-rendering it when only
    /// the drag preview changes.
    private struct ElementsCanvas: View, Equatable {
        let elements: [LabelElement]
        let s: CGFloat

        static func == (a: ElementsCanvas, b: ElementsCanvas) -> Bool {
            a.s == b.s && a.elements == b.elements
        }

        var body: some View {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                for el in elements {
                    Self.drawOne(el, x: el.x, y: el.y, fontSize: el.fontSize,
                                 size: el.size, s: s, into: &ctx)
                }
            }
        }

        static func drawOne(_ el: LabelElement, x: Int, y: Int, fontSize: CGFloat,
                            size: Int, s: CGFloat, into ctx: inout GraphicsContext) {
            let ew = CGFloat(el.displayWidth(fontSize: fontSize, size: size, x: x)) * s
            let eh = CGFloat(el.displayHeight(fontSize: fontSize, size: size, x: x)) * s
            let rect = CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s,
                              width: ew, height: eh)
            switch el.kind {
            case .text:
                let text = Text(el.text)
                    .font(.system(size: fontSize * s, weight: el.bold ? .bold : .regular))
                    .foregroundColor(.black)
                let tw = CGFloat(el.wrapWidth(at: x)) * s
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
