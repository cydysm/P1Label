// Interactive label canvas: paper preview + element hit areas + drag/resize
// gestures. Kept separate from the main view so it can be exercised by the
// drag harness (Tests/DragHarness) with the exact same code that ships.

import SwiftUI

// MARK: - Interactive canvas (WYSIWYG)

struct LabelCanvas: View {
    @Binding var doc: LabelDocument
    @Binding var selectedID: UUID?
    @Binding var scale: CGFloat
    @State private var pinchBase: CGFloat?
    @State private var gestureMode: Mode?
    @State private var resizeStart: (fontSize: CGFloat, size: Int, dist: CGFloat)?
    /// Live drag preview — local state only. `doc` is written ONCE on gesture end,
    /// otherwise the ForEach rebuilds the gesture view every frame, cancelling and
    /// restarting the drag (element crawls behind the cursor = jank + ghosting).
    @State private var preview: Preview?
    struct Preview {
        var id: UUID
        var dx: Int = 0
        var dy: Int = 0
        var fontSize: CGFloat?
        var size: Int?
    }

    enum Mode { case move, resize }

    /// Element position/size with the live preview applied.
    private func effective(_ el: LabelElement) -> (x: Int, y: Int, fontSize: CGFloat, size: Int) {
        guard let p = preview, p.id == el.id else { return (el.x, el.y, el.fontSize, el.size) }
        return (el.x + p.dx, el.y + p.dy, p.fontSize ?? el.fontSize, p.size ?? el.size)
    }

    var body: some View {
        GeometryReader { geo in
            let (wDots, hDots) = LabelRenderer.contentSize(doc)
            let fitScale = min((geo.size.width - 24) / CGFloat(wDots),
                               (geo.size.height - 24) / CGFloat(hDots))
            let s = max(min(scale, fitScale > 0 ? min(scale, 6) : 2), 0.5)
            let paperW = CGFloat(wDots) * s
            let paperH = CGFloat(hDots) * s

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // Static layer: every element NOT being live-dragged. Its inputs
                    // (elements, scale) don't change during a drag, and the Equatable
                    // conformance lets SwiftUI skip it entirely on drag frames —
                    // per-frame work shrinks to the small overlay below.
                    ElementsCanvas(elements: staticElements, s: s)
                        .equatable()
                        .frame(width: paperW, height: paperH)
                        .border(Color.gray.opacity(0.4), width: 1)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = nil }

                    overlayCanvas(s: s)
                        .frame(width: paperW, height: paperH)
                        .allowsHitTesting(false)

                    hitAreas(s: s)
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

    // MARK: Canvas paint layers

    /// All elements except the one being live-dragged (otherwise it would ghost
    /// underneath the overlay copy).
    private var staticElements: [LabelElement] {
        guard let p = preview else { return doc.elements }
        return doc.elements.filter { $0.id != p.id }
    }

    /// Per-frame layer: the dragged element at its live position + selection box.
    private func overlayCanvas(s: CGFloat) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.clear))
            guard let sel = doc.elements.first(where: { $0.id == selectedID }) else { return }
            let eff = effective(sel)
            if preview?.id == sel.id {
                ElementsCanvas.drawOne(sel, x: eff.x, y: eff.y, fontSize: eff.fontSize,
                                       size: eff.size, s: s, into: &ctx)
            }
            drawSelectionBox(sel, eff: eff, s: s, into: &ctx)
        }
    }

    private func drawSelectionBox(_ el: LabelElement,
                                  eff: (x: Int, y: Int, fontSize: CGFloat, size: Int),
                                  s: CGFloat, into ctx: inout GraphicsContext) {
        let ew = CGFloat(el.displayWidth(fontSize: eff.fontSize, size: eff.size, x: eff.x)) * s
        let eh = CGFloat(el.displayHeight(fontSize: eff.fontSize, size: eff.size, x: eff.x)) * s
        let rect = CGRect(x: CGFloat(eff.x) * s - 2, y: CGFloat(eff.y) * s - 2,
                          width: ew + 4, height: eh + 4)
        ctx.stroke(Path(rect), with: .color(.blue), lineWidth: 1)
        let c = CGRect(x: CGFloat(eff.x) * s + ew - 6, y: CGFloat(eff.y) * s + eh - 6,
                       width: 12, height: 12)
        ctx.fill(Path(ellipseIn: c), with: .color(.blue))
        ctx.stroke(Path(ellipseIn: c.insetBy(dx: -1.5, dy: -1.5)), with: .color(.white), lineWidth: 1.5)
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

    // MARK: Hit areas

    private func hitAreas(s: CGFloat) -> some View {
        ForEach($doc.elements) { $el in
            let eff = effective(el)
            let w = CGFloat(el.displayWidth(fontSize: eff.fontSize, size: eff.size, x: eff.x)) * s
            let h = CGFloat(el.displayHeight(fontSize: eff.fontSize, size: eff.size, x: eff.x)) * s
            Color.clear
                .frame(width: max(w + 8, 12), height: max(h + 8, 12))
                .contentShape(Rectangle())
                .onTapGesture { selectedID = el.id }
                .highPriorityGesture(unifiedGesture(el, s: s, w: w, h: h))
                .offset(x: CGFloat(eff.x) * s - 4, y: CGFloat(eff.y) * s - 4)
        }
    }

    enum ElementMode { case move, resize }

    private func unifiedGesture(_ el: LabelElement, s: CGFloat, w: CGFloat, h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                // onChanged fires every drag frame; @Published fires objectWillChange
                // even for equal writes, so only assign on actual change — otherwise
                // the whole editor pane re-renders per frame and drags lag behind.
                if selectedID != el.id { selectedID = el.id }
                let hx = w - 4, hy = h - 4  // handle center in hit-area coords (offset -4)
                let startIsResize = hypot(g.startLocation.x - hx, g.startLocation.y - hy) < 22
                if gestureMode == nil {
                    gestureMode = startIsResize ? .resize : .move
                    resizeStart = (el.fontSize, el.size, max(hypot(g.startLocation.x - (w/2), g.startLocation.y - (h/2)), 8))
                }
                if gestureMode == .move {
                    let dx = Int((g.translation.width / s).rounded())
                    let dy = Int((g.translation.height / s).rounded())
                    preview = Preview(id: el.id, dx: dx, dy: dy)
                } else {
                    guard let start = resizeStart else { return }
                    let cx = w / 2, cy = h / 2
                    let dist = max(hypot(g.location.x - cx, g.location.y - cy), 4)
                    let startDist = max(hypot(g.startLocation.x - cx, g.startLocation.y - cy), 8)
                    let ratio = max(0.2, min(5.0, dist / startDist))
                    var p = preview ?? Preview(id: el.id)
                    switch el.kind {
                    case .text:
                        p.fontSize = min(72, max(12, (start.fontSize * ratio).rounded()))
                    case .qr, .barcode:
                        p.size = Int(min(200, max(24, (CGFloat(start.size) * ratio).rounded())))
                    }
                    preview = p
                }
            }
            .onEnded { _ in
                // commit preview to the document once
                if let p = preview, let idx = doc.elements.firstIndex(where: { $0.id == p.id }) {
                    if gestureMode == .move {
                        doc.elements[idx].x = max(0, min(doc.elements[idx].x + p.dx, LabelDocument.paperWidthDots))
                        doc.elements[idx].y = max(0, min(doc.elements[idx].y + p.dy, 1200))
                    } else {
                        if let fs = p.fontSize { doc.elements[idx].fontSize = fs }
                        if let sz = p.size { doc.elements[idx].size = sz }
                    }
                }
                preview = nil
                gestureMode = nil
                resizeStart = nil
            }
    }
}
