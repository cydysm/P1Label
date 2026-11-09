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
// Interactive label canvas: paper preview, selection, live drag/resize and
// the v2 editor interactions (marquee multi-select, inline text editing,
// zoom/pan). Kept in its own file so the exact same view can be exercised by
// a standalone drag harness as well as by the shipping app.
//
// How the drag works (UNCHANGED ARCHITECTURE — v2 red line)
// ---------------------------------------------------------
// All pointer handling lives on ONE gesture surface that covers the viewport
// and never moves while a drag is in flight. Element hit-testing is done
// manually in paper coordinates, and the live preview is rendered from local
// state; `doc` is written exactly once, when the gesture ends.
//
// This matters: when the view that owns the DragGesture is itself moved during
// the drag (the old per-element transparent hit areas were offset every frame),
// SwiftUI resolves the gesture's location against a coordinate space that is
// moving under the pointer. The element then trails the cursor, jumps and leaves
// a stale-looking double image. A static gesture surface removes that feedback
// loop completely. Marquee, space-pan and inline-edit gating are all folded
// into this same surface's update() — no second gesture surface exists.
//
// Alignment guides: while moving, update() snaps the proposed position onto
// other elements' and the paper's edge/center lines and records the hit for
// liveLayer to draw. Snapping adjusts dx/dy before the preview offset is
// computed — it changes numbers, never the gesture surface itself.
//
// Zoom/pan (§5.7) are pure view state: `scale` comes from ContentView as a
// binding; `offset` is local. Wheel scrolling pans, ⌘-wheel zooms anchored at
// the cursor (wired through PrintModel's scroll monitor), pinch zooms, and
// space-drag pans. None of it touches the document.

import SwiftUI
import AppKit

struct LabelCanvas: View {
    @ObservedObject var model: PrintModel
    @Binding var doc: LabelDocument
    @Binding var selection: Set<UUID>
    @Binding var primaryID: UUID?
    @Binding var scale: CGFloat
    @Binding var spacePanning: Bool
    @Binding var snapEnabled: Bool

    @State private var pinchBase: CGFloat?
    /// Viewport-space point of the current mouse press.
    @State private var pressStart: CGPoint?
    /// Live drag preview. Local state only — no document writes per frame.
    @State private var drag: Drag?
    /// Paper top-left in viewport coordinates (pan/zoom view state, §5.7).
    @State private var offset: CGPoint = CGPoint(x: 60, y: 40)
    @State private var viewportSize: CGSize = .zero
    /// Inline text editor draft (§5.5).
    @State private var inlineDraft = ""
    @FocusState private var inlineFocus: Bool
    /// Double-click detection for inline editing.
    @State private var lastClick: (time: Date, point: CGPoint)?
    /// 首次布局时适应窗口一次（§2.2），之后缩放/平移归用户。
    @State private var didInitialFit = false

    // MARK: Drag model

    enum Mode: Equatable {
        case none
        case move
        case resizeCorner(Corner)
        case resizeEdge(Edge)
        case marquee
        case pan
    }

    enum Corner: Equatable { case topLeft, topRight, bottomLeft, bottomRight }
    /// 文本元素左右边中点：拖拽调整换行宽（§6.6）。
    enum Edge: Equatable { case left, right }

    struct Drag {
        var mode: Mode
        /// Gesture start in viewport coordinates (the surface never moves).
        var start: CGPoint
        /// Pre-gesture state of every element being moved (multi-move).
        var bases: [UUID: LabelElement]
        /// The element a resize applies to (nil for marquee/pan).
        var primary: LabelElement?
        /// Live translation in dots (whole dots = the document's unit).
        var dx: Int = 0
        var dy: Int = 0
        var fontSize: CGFloat?
        var size: Int?
        var wrapWidth: Int?
        /// Live marquee rect in viewport coordinates.
        var marquee: CGRect?
        /// Pan base offset (viewport coords of the paper at gesture start).
        var panBase: CGPoint?
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

            ZStack(alignment: .topLeading) {
                // Background: neutral gray + optional 8pt dot grid (§3.2).
                GridLayer(size: geo.size, enabled: model.showGrid)
                    .equatable()

                // Paper + elements. Everything inside moves with `offset`;
                // the gesture surface below does not.
                ZStack(alignment: .topLeading) {
                    // Static layer: every element NOT being live-dragged. Its
                    // inputs (elements, scale) don't change during a drag and the
                    // Equatable conformance lets SwiftUI skip re-rendering it, so
                    // a drag frame only repaints the small live layer below.
                    ElementsCanvas(elements: staticElements, s: s, printableWidth: printableWidth)
                        .equatable()
                        .frame(width: paperW, height: paperH)
                        .clipShape(RoundedRectangle(cornerRadius: Design.radiusPaper))
                        .shadow(color: Design.shadowPaper, radius: 12, x: 0, y: 4)

                    // Per-frame layer: dragged element at its live position plus
                    // the snap guides.
                    liveLayer(s: s)
                        .frame(width: paperW, height: paperH)
                        .allowsHitTesting(false)
                }
                .frame(width: paperW, height: paperH, alignment: .topLeading)
                .offset(x: offset.x, y: offset.y)

                // Selection overlay (viewport coordinates: dashed multi boxes,
                // primary box, corner/edge handles, marquee).
                selectionOverlay(s: s)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)

                // Single, static gesture surface (see file header). Must sit
                // BELOW the interactive controls: a click on the delete button
                // or the snap toggle has to reach the button, not start a
                // paper drag (v1 ordering regression found in use).
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: geo.size.width, height: geo.size.height)
                    .gesture(paperGesture(s: s))
                    .disabled(model.inlineEditingID != nil)

                // Interactive controls pinned to the selection frame. ABOVE the
                // gesture surface (v1 comment kept): clicks reach the button,
                // everything else falls through to the paper drag.
                selectionControls(s: s)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)

                // 画布内联文本编辑（§5.5）— 编辑态临时禁用画布手势。
                if model.inlineEditingID != nil {
                    inlineEditor(s: s)
                }

                // 空画布引导（§6.6）。
                if !hasVisibleElements && drag == nil {
                    VStack {
                        Spacer()
                        Text("点击上方 ＋ 添加文字 / 二维码 / 条码")
                            .font(.designCaption)
                            .foregroundStyle(Design.textTertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }

                // 吸附对齐开关（§6.6 右下角浮动按钮），同样要在手势面之上。
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        snapToggleButton
                    }
                }
                .padding(12)
            }
            .clipped()
            .background(FrameProbe { model.canvasScreenFrame = $0 })
            .onAppear {
                viewportSize = geo.size
                registerScrollHandler()
            }
            .onChange(of: geo.size) { newSize in
                viewportSize = newSize
                // 纸张随窗口尺寸自动"适应"缩放（§2.2）：首次拿到视口尺寸时
                // fit 一次并居中，之后保持用户的缩放/平移。
                if !didInitialFit, newSize.width > 100, newSize.height > 100 {
                    didInitialFit = true
                    fitToWindow(wDots: wDots, hDots: hDots, viewport: newSize)
                }
            }
            .onDisappear { model.canvasScrollHandler = nil }
            .onChange(of: model.fitRequested) { requested in
                guard requested else { return }
                model.fitRequested = false
                fitToWindow(wDots: wDots, hDots: hDots, viewport: geo.size)
            }
            .onChange(of: model.zoomCommand) { command in
                guard let command else { return }
                model.zoomCommand = nil
                let factor: CGFloat = command == .zoomIn ? 1.25 : 0.8
                zoomAround(at: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2),
                           to: scale * factor)
            }
            .onChange(of: model.scrollToElementID) { id in
                guard let id else { return }
                model.scrollToElementID = nil
                guard let el = doc.elements.first(where: { $0.id == id }) else { return }
                let rect = elementRect(el, s: s)
                let target = CGPoint(
                    x: offset.x + rect.midX - geo.size.width / 2,
                    y: offset.y + rect.midY - geo.size.height / 2)
                withAnimation(.easeOut(duration: 0.2)) {
                    offset = clampedOffset(target, paperW: paperW, paperH: paperH, viewport: geo.size)
                }
            }
            .onChange(of: model.inlineEditingID) { id in
                guard let id else { return }
                inlineDraft = doc.elements.first(where: { $0.id == id })?.text ?? ""
                DispatchQueue.main.async { inlineFocus = true }
            }
        }
        .gesture(
            MagnificationGesture()
                .onChanged { v in
                    let base = pinchBase ?? scale
                    if pinchBase == nil { pinchBase = scale }
                    let newScale = max(0.5, min(base * v, 6))
                    // Pinch zoom keeps the viewport center anchored.
                    zoomAround(at: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2),
                               to: newScale, currentScale: max(min(scale, 6), 0.5))
                }
                .onEnded { _ in pinchBase = nil }
        )
    }

    // MARK: - Zoom / pan (view state, §5.7)

    private func registerScrollHandler() {
        model.canvasScrollHandler = { x, y, dx, dy, zoom in
            if zoom {
                // ⌘滚轮：以光标为锚点缩放（§5.7）。
                let factor = min(max(exp(-Double(dy) * 0.002), 0.85), 1.2)
                zoomAround(at: CGPoint(x: x, y: y), to: scale * CGFloat(factor))
            } else {
                offset = clampedOffset(CGPoint(x: offset.x + dx, y: offset.y + dy),
                                       paperW: CGFloat(LabelRenderer.contentSize(doc).0) * max(min(scale, 6), 0.5),
                                       paperH: CGFloat(LabelRenderer.contentSize(doc).1) * max(min(scale, 6), 0.5),
                                       viewport: viewportSize)
            }
        }
    }

    /// Keep `at` (viewport coords) pinned to the same paper point across the
    /// scale change.
    private func zoomAround(at point: CGPoint, to target: CGFloat,
                            currentScale: CGFloat? = nil) {
        let from = currentScale ?? max(min(scale, 6), 0.5)
        let to = max(0.5, min(target, 6))
        guard to != from, from > 0 else { return }
        let paperPoint = CGPoint(x: (point.x - offset.x) / from,
                                 y: (point.y - offset.y) / from)
        offset = CGPoint(x: point.x - paperPoint.x * to,
                         y: point.y - paperPoint.y * to)
        scale = to
    }

    private func fitToWindow(wDots: Int, hDots: Int, viewport: CGSize) {
        let s = max(0.5, min(6, min((viewport.width - 80) / CGFloat(max(wDots, 1)),
                                    (viewport.height - 80) / CGFloat(max(hDots, 1)))))
        let paperW = CGFloat(wDots) * s
        let paperH = CGFloat(hDots) * s
        scale = s
        offset = CGPoint(x: (viewport.width - paperW) / 2, y: (viewport.height - paperH) / 2)
    }

    /// Keep at least 40pt of the paper visible on every side; center it when
    /// the range degenerates.
    private func clampedOffset(_ o: CGPoint, paperW: CGFloat, paperH: CGFloat,
                               viewport: CGSize) -> CGPoint {
        func clamp1(_ v: CGFloat, size: CGFloat, viewportLen: CGFloat) -> CGFloat {
            let lo = 40 - size, hi = viewportLen - 40
            if lo > hi { return (viewportLen - size) / 2 }
            return min(max(v, lo), hi)
        }
        return CGPoint(x: clamp1(o.x, size: paperW, viewportLen: viewport.width),
                       y: clamp1(o.y, size: paperH, viewportLen: viewport.height))
    }

    // MARK: - Content helpers

    private var printableWidth: Int {
        LabelRenderer.paperWidthDots(doc)
    }

    private var hasVisibleElements: Bool {
        doc.elements.contains { !$0.hidden }
    }

    /// Element position/size with the live preview applied.
    private func effective(_ el: LabelElement) -> (x: Int, y: Int, fontSize: CGFloat, size: Int, width: Int) {
        let unchanged = (el.x, el.y, el.fontSize, el.size, el.width)
        guard let d = drag else { return unchanged }
        switch d.mode {
        case .move:
            guard let base = d.bases[el.id] else { return unchanged }
            return (base.x + d.dx, base.y + d.dy, base.fontSize, base.size, base.width)
        case .resizeCorner, .resizeEdge:
            guard let base = d.primary, base.id == el.id else { return unchanged }
            return (base.x, base.y, d.fontSize ?? base.fontSize,
                    d.size ?? base.size, d.wrapWidth ?? base.width)
        default:
            return unchanged
        }
    }

    /// All elements except the ones being live-dragged (otherwise they would
    /// ghost underneath the live copies). Hidden elements are never drawn.
    private var staticElements: [LabelElement] {
        guard let d = drag else { return doc.elements.filter { !$0.hidden } }
        switch d.mode {
        case .move:
            return doc.elements.filter { !$0.hidden && d.bases[$0.id] == nil }
        case .resizeCorner, .resizeEdge:
            return doc.elements.filter { !$0.hidden && $0.id != d.primary?.id }
        default:
            return doc.elements.filter { !$0.hidden }
        }
    }

    /// Element bounds in paper points (viewport scale applied).
    private func elementRect(_ el: LabelElement, s: CGFloat,
                             x: Int, y: Int, fontSize: CGFloat, size: Int, width: Int) -> CGRect {
        let w = CGFloat(el.displayWidth(fontSize: fontSize, size: size, x: x, width: width,
                                        printableWidth: printableWidth)) * s
        let h = CGFloat(el.displayHeight(fontSize: fontSize, size: size, x: x, width: width,
                                         printableWidth: printableWidth)) * s
        return CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: w, height: h)
    }

    private func elementRect(_ el: LabelElement, s: CGFloat) -> CGRect {
        elementRect(el, s: s, x: el.x, y: el.y, fontSize: el.fontSize, size: el.size, width: el.width)
    }

    /// Viewport-space rect of an element (paper offset applied).
    private func viewportRect(_ el: LabelElement, s: CGFloat,
                              x: Int, y: Int, fontSize: CGFloat, size: Int, width: Int) -> CGRect {
        elementRect(el, s: s, x: x, y: y, fontSize: fontSize, size: size, width: width)
            .offsetBy(dx: offset.x, dy: offset.y)
    }

    // MARK: - Gesture

    private func paperGesture(s: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if pressStart == nil {
                    pressStart = g.startLocation
                    beginGesture(at: g.startLocation, s: s)
                }
                guard var d = drag, d.mode != .none else { return }
                update(&d, with: g, s: s)
                drag = d
            }
            .onEnded { g in
                let start = pressStart ?? g.startLocation
                if drag == nil { beginGesture(at: start, s: s) }
                if var d = drag, d.mode != .none {
                    update(&d, with: g, s: s)
                    commit(d, with: g, s: s, clickStart: start)
                }
                drag = nil
                pressStart = nil
            }
    }

    private var isShiftDown: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }

    private func beginGesture(at point: CGPoint, s: CGFloat) {
        // 空格按下 → 平移（§5.7），不命中元素。
        if spacePanning {
            drag = Drag(mode: .pan, start: point, bases: [:], primary: nil, panBase: offset)
            return
        }

        // ① 主选中元素的缩放/换行宽手柄优先（§6.6）：手柄画在主选中框上，
        //    只有已选中时才可见，命中即进入缩放拖拽（否则落到下面的移动逻辑）。
        if let pid = primaryID,
           let primary = doc.elements.first(where: { $0.id == pid }),
           !primary.hidden,
           let mode = handleMode(at: point, for: primary, s: s) {
            drag = Drag(mode: mode, start: point, bases: [:], primary: primary)
            return
        }

        let paperPoint = CGPoint(x: point.x - offset.x, y: point.y - offset.y)

        // ② Double-click on text → inline editing (§5.5).
        let now = Date()
        if let last = lastClick,
           now.timeIntervalSince(last.time) < 0.4,
           hypot(point.x - last.point.x, point.y - last.point.y) < 6,
           let el = hitTest(paperPoint, s: s), el.kind == .text, !el.hidden {
            lastClick = nil
            model.commitPendingTextEdit()
            setSelection([el.id], primary: el.id)
            model.beginInlineEdit()
            drag = Drag(mode: .none, start: point, bases: [:], primary: nil)
            return
        }
        lastClick = (now, point)

        // ③ 元素命中 → 选择 / 移动；空白 → 框选（§5.1）。
        if let el = hitTest(paperPoint, s: s), !el.hidden {
            if selection.contains(el.id) {
                if isShiftDown {
                    // ⇧单击：加入/移出多选（§5.1）；本次手势作废。
                    model.toggleSelection(el.id)
                    drag = Drag(mode: .none, start: point, bases: [:], primary: nil)
                    return
                }
                primaryID = el.id
                startMoveDrag(point: point, s: s)
            } else {
                if isShiftDown {
                    setSelection(selection.union([el.id]), primary: el.id)
                } else {
                    setSelection([el.id], primary: el.id)
                }
                startMoveDrag(point: point, s: s)
            }
        } else {
            // 空白处拖拽 → 框选（§5.1）。命中失败也要先清一次 primary 判断。
            drag = Drag(mode: .marquee, start: point, bases: [:], primary: nil,
                        marquee: CGRect(origin: point, size: .zero))
        }
    }

    /// 手柄命中检测：主选中框 4 个角点（缩放）+ 文本左右边中点（换行宽）。
    /// 手柄 8×8 视觉，命中半径放宽到 12pt 保持好抓。
    private func handleMode(at point: CGPoint, for el: LabelElement, s: CGFloat) -> Mode? {
        let rect = viewportRect(el, s: s, x: el.x, y: el.y,
                                fontSize: el.fontSize, size: el.size, width: el.width)
            .insetBy(dx: -2, dy: -2)   // 与 drawPrimaryHandles 的描边内缩一致
        let hitRadius: CGFloat = 12
        let corners: [(Corner, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        for (corner, pos) in corners
        where hypot(point.x - pos.x, point.y - pos.y) <= hitRadius {
            return .resizeCorner(corner)
        }
        if el.kind == .text {
            let mids: [(Edge, CGPoint)] = [
                (.left, CGPoint(x: rect.minX, y: rect.midY)),
                (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            ]
            for (edge, pos) in mids
            where hypot(point.x - pos.x, point.y - pos.y) <= hitRadius {
                return .resizeEdge(edge)
            }
        }
        return nil
    }

    private func setSelection(_ ids: Set<UUID>, primary: UUID?) {
        if ids.isEmpty {
            selection = []
            primaryID = nil
        } else {
            selection = ids
            primaryID = primary ?? ids.first
        }
    }

    private func startMoveDrag(point: CGPoint, s: CGFloat) {
        // 多选拖拽：整体移动（Figma/Keynote 惯例）。
        var bases: [UUID: LabelElement] = [:]
        for id in selection {
            if let el = doc.elements.first(where: { $0.id == id }) {
                bases[id] = el
            }
        }
        drag = Drag(mode: .move, start: point, bases: bases, primary: nil)
    }

    private func update(_ d: inout Drag, with g: DragGesture.Value, s: CGFloat) {
        switch d.mode {
        case .none:
            break
        case .pan:
            d.panBase = d.panBase ?? offset
            offset = clampedOffset(
                CGPoint(x: (d.panBase ?? offset).x + g.translation.width,
                        y: (d.panBase ?? offset).y + g.translation.height),
                paperW: CGFloat(LabelRenderer.contentSize(doc).0) * s,
                paperH: CGFloat(LabelRenderer.contentSize(doc).1) * s,
                viewport: viewportSize)
        case .move:
            // All selected elements share one translation; snapping anchors on
            // the primary element's base position.
            let translationDx = Int((g.translation.width / s).rounded())
            let translationDy = Int((g.translation.height / s).rounded())
            d.guideX = nil
            d.guideY = nil
            var dx = translationDx
            var dy = translationDy
            if snapEnabled, let anchorID = primaryID ?? d.bases.keys.first,
               let base = d.bases[anchorID] {
                var bx = base.x + translationDx
                var by = base.y + translationDy
                let (gx, gy) = snapped(tx: &bx, ty: &by, moving: base, s: s)
                dx = bx - base.x
                dy = by - base.y
                d.guideX = gx
                d.guideY = gy
            }
            d.dx = dx
            d.dy = dy
        case .resizeCorner(let corner):
            guard let base = d.primary else { break }
            let local = CGPoint(x: g.location.x - offset.x, y: g.location.y - offset.y)
            let rect = elementRect(base, s: s)
            let anchor: CGPoint
            switch corner {
            case .topLeft: anchor = CGPoint(x: rect.maxX, y: rect.maxY)
            case .topRight: anchor = CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomLeft: anchor = CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomRight: anchor = CGPoint(x: rect.minX, y: rect.minY)
            }
            let startLocal = CGPoint(x: d.start.x - offset.x, y: d.start.y - offset.y)
            let startDist = max(hypot(startLocal.x - anchor.x, startLocal.y - anchor.y), 8)
            let dist = max(hypot(local.x - anchor.x, local.y - anchor.y), 4)
            let ratio = max(0.2, min(5.0, dist / startDist))
            switch base.kind {
            case .text:
                d.fontSize = min(72, max(12, (base.fontSize * ratio).rounded()))
            case .qr, .barcode:
                d.size = Int(min(200, max(24, (CGFloat(base.size) * ratio).rounded())))
            }
        case .resizeEdge(let edge):
            guard let base = d.primary, base.kind == .text else { break }
            let local = CGPoint(x: g.location.x - offset.x, y: g.location.y - offset.y)
            let rect = elementRect(base, s: s)
            let anchorX = edge == .left ? rect.maxX : rect.minX
            let widthPoints = abs(local.x - anchorX)
            let widthDots = Int((widthPoints / s).rounded())
            let maxW = max(32, printableWidth - base.x)
            d.wrapWidth = min(max(widthDots, 32), maxW)
        case .marquee:
            d.marquee = CGRect(x: min(d.start.x, g.location.x),
                               y: min(d.start.y, g.location.y),
                               width: abs(g.location.x - d.start.x),
                               height: abs(g.location.y - d.start.y))
        }
    }

    // MARK: - Commit

    private func commit(_ d: Drag, with g: DragGesture.Value, s: CGFloat, clickStart: CGPoint) {
        switch d.mode {
        case .none:
            break
        case .pan:
            break   // offset already live-updated; view state only
        case .move:
            guard d.dx != 0 || d.dy != 0 else { return }
            // Clamp fully inside the paper. The old y clamp (1200) predated
            // paper presets and let elements be dragged off-paper where they
            // turned invisible but still counted in the document.
            let (_, hDots) = LabelRenderer.contentSize(doc)
            var newDoc = doc
            for (id, base) in d.bases {
                guard let idx = newDoc.elements.firstIndex(where: { $0.id == id }) else { continue }
                let maxX = max(0, printableWidth - base.dotsWidth(printableWidth: printableWidth))
                let maxY = max(0, hDots - base.dotsHeight(printableWidth: printableWidth))
                newDoc.elements[idx].x = max(0, min(base.x + d.dx, maxX))
                newDoc.elements[idx].y = max(0, min(base.y + d.dy, maxY))
            }
            if newDoc != doc { doc = newDoc }
        case .resizeCorner, .resizeEdge:
            guard let base = d.primary,
                  let idx = doc.elements.firstIndex(where: { $0.id == base.id }) else { return }
            var newDoc = doc
            if let fs = d.fontSize, fs != base.fontSize { newDoc.elements[idx].fontSize = fs }
            if let sz = d.size, sz != base.size { newDoc.elements[idx].size = sz }
            if let w = d.wrapWidth, w != base.width { newDoc.elements[idx].width = w }
            if newDoc != doc { doc = newDoc }
        case .marquee:
            let moved = d.marquee.map { hypot($0.width, $0.height) } ?? 0
            if moved < 3 {
                // Plain click on empty paper clears the selection (§5.1).
                if hitTest(CGPoint(x: clickStart.x - offset.x, y: clickStart.y - offset.y),
                           s: s) == nil {
                    setSelection([], primary: nil)
                }
                return
            }
            // 框选：相交元素入选；⇧ 追加（§5.1）。
            guard let viewportMarquee = d.marquee else { return }
            let paperMarquee = CGRect(
                x: (viewportMarquee.minX - offset.x) / s,
                y: (viewportMarquee.minY - offset.y) / s,
                width: viewportMarquee.width / s,
                height: viewportMarquee.height / s)
            var hits = Set<UUID>()
            for el in doc.elements where !el.hidden {
                if elementRect(el, s: s).intersects(paperMarquee) {
                    hits.insert(el.id)
                }
            }
            let final = isShiftDown ? selection.union(hits) : hits
            setSelection(final, primary: final.max { a, b in
                zIndex(a) < zIndex(b)
            })
        }
    }

    private func zIndex(_ id: UUID) -> Int {
        doc.elements.firstIndex(where: { $0.id == id }) ?? -1
    }

    /// Topmost element under a paper-space point (last drawn wins). Hidden
    /// elements never hit (§5.6).
    private func hitTest(_ point: CGPoint, s: CGFloat) -> LabelElement? {
        for el in doc.elements.reversed() where !el.hidden {
            var rect = elementRect(el, s: s).insetBy(dx: -4, dy: -4)
            // Keep tiny/empty elements grabbable.
            if rect.width < 12 { rect = rect.insetBy(dx: -(12 - rect.width) / 2, dy: 0) }
            if rect.height < 12 { rect = rect.insetBy(dx: 0, dy: -(12 - rect.height) / 2) }
            if rect.contains(point) { return el }
        }
        return nil
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
                         s: CGFloat) -> (CGFloat?, CGFloat?) {
        let th = Double(Self.snapRadiusPoints / s)
        let w = CGFloat(el.displayWidth(fontSize: el.fontSize, size: el.size, x: tx,
                                        width: el.width, printableWidth: printableWidth))
        let h = CGFloat(el.displayHeight(fontSize: el.fontSize, size: el.size, x: tx,
                                         width: el.width, printableWidth: printableWidth))
        let rect = CGRect(x: CGFloat(tx), y: CGFloat(ty), width: w, height: h)

        // Paper edges + center, then every other element's edges + center.
        let (wDots, hDots) = LabelRenderer.contentSize(doc)
        var xs: [CGFloat] = [0, CGFloat(wDots) / 2, CGFloat(wDots)]
        var ys: [CGFloat] = [0, CGFloat(hDots) / 2, CGFloat(hDots)]
        for other in doc.elements where other.id != el.id && !other.hidden {
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
                    ctx.stroke(p, with: .color(Design.guideSnap), style: style)
                }
                if let gy = d.guideY {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: CGFloat(gy) * s))
                    p.addLine(to: CGPoint(x: size.width, y: CGFloat(gy) * s))
                    ctx.stroke(p, with: .color(Design.guideSnap), style: style)
                }
            }
            // Dragged elements at their live positions (also before the first
            // movement — the static layer already excludes them).
            guard let d = drag else { return }
            switch d.mode {
            case .move:
                for base in d.bases.values {
                    let eff = effective(base)
                    ElementsCanvas.drawOne(base, x: eff.x, y: eff.y, fontSize: eff.fontSize,
                                           size: eff.size, width: eff.width, s: s,
                                           printableWidth: printableWidth, into: &ctx)
                }
            case .resizeCorner, .resizeEdge:
                if let base = d.primary {
                    let eff = effective(base)
                    ElementsCanvas.drawOne(base, x: eff.x, y: eff.y, fontSize: eff.fontSize,
                                           size: eff.size, width: eff.width, s: s,
                                           printableWidth: printableWidth, into: &ctx)
                }
            default:
                break
            }
        }
    }

    /// Selection overlay in viewport coordinates: marquee, per-element boxes
    /// (多选虚线 §6.6), primary handles, all unscaled by zoom.
    private func selectionOverlay(s: CGFloat) -> some View {
        Canvas { ctx, size in
            _ = size
            // Marquee (虚线矩形 + 半透明填充, §5.1).
            if let d = drag, d.mode == .marquee, let rect = d.marquee {
                ctx.fill(Path(rect), with: .color(Design.accent.opacity(0.10)))
                ctx.stroke(Path(rect), with: .color(Design.accent),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            guard !selection.isEmpty, drag?.mode != .marquee else { return }
            for id in selection {
                guard let el = doc.elements.first(where: { $0.id == id }) else { continue }
                let eff = effective(el)
                let rect = viewportRect(el, s: s, x: eff.x, y: eff.y,
                                        fontSize: eff.fontSize, size: eff.size, width: eff.width)
                    .insetBy(dx: -2, dy: -2)
                if id == primaryID {
                    drawPrimaryHandles(rect, kind: el.kind, into: &ctx)
                } else {
                    ctx.stroke(Path(rect), with: .color(Design.accent),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
        }
    }

    /// Primary selection: accent frame + white corner handles (缩放 ×4) and
    /// left/right edge midpoints for text (换行宽, §6.6).
    private func drawPrimaryHandles(_ rect: CGRect, kind: LabelElement.Kind,
                                    into ctx: inout GraphicsContext) {
        ctx.stroke(Path(rect), with: .color(Design.accent), lineWidth: 1.2)
        let corners = [rect.origin,
                       CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY),
                       CGPoint(x: rect.maxX, y: rect.maxY)]
        for c in corners {
            let handle = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            let path = Path(roundedRect: handle, cornerRadius: 2)
            ctx.fill(path, with: .color(.white))
            ctx.stroke(path, with: .color(Design.accent), lineWidth: 1.2)
        }
        if kind == .text {
            let mids = [CGPoint(x: rect.minX, y: rect.midY),
                        CGPoint(x: rect.maxX, y: rect.midY)]
            for m in mids {
                let handle = CGRect(x: m.x - 3, y: m.y - 4, width: 6, height: 8)
                let path = Path(roundedRect: handle, cornerRadius: 2)
                ctx.fill(path, with: .color(.white))
                ctx.stroke(path, with: .color(Design.accent), lineWidth: 1.2)
            }
        }
    }

    // MARK: - Selection controls (delete button + inline editor)

    /// 删除 × 按钮：白底圆钮 + hairline 描边 + 轻投影 + 红色 ×（§6.6），中心压在
    /// 选中框右上角点上（行为基线 #5/#8：点击即删，无确认）。点击后走撤销栈。
    private func selectionControls(s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if model.inlineEditingID == nil,
               let id = primaryID,
               let el = doc.elements.first(where: { $0.id == id }) {
                let eff = effective(el)
                let rect = viewportRect(el, s: s, x: eff.x, y: eff.y,
                                        fontSize: eff.fontSize, size: eff.size, width: eff.width)
                Button {
                    var newDoc = doc
                    newDoc.elements.removeAll { $0.id == id }
                    doc = newDoc
                    var rest = selection
                    rest.remove(id)
                    setSelection(rest, primary: nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Design.stateError)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white))
                        .overlay(Circle().stroke(Design.hairline, lineWidth: 1))
                        .shadow(color: Design.shadowCard, radius: 4, y: 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("删除选中元素")
                .position(x: rect.maxX, y: rect.minY)
            }
        }
    }

    /// 画布内联文本编辑框（§5.5）：CoreText 同款字号的 SwiftUI 覆盖层，仅编辑期。
    /// 失焦或 Enter 提交、Esc 取消（Esc 由 PrintModel 的键盘监听处理）。
    @ViewBuilder
    private func inlineEditor(s: CGFloat) -> some View {
        if let id = model.inlineEditingID,
           let el = doc.elements.first(where: { $0.id == id }) {
            let rect = elementRect(el, s: s)
            TextField("", text: $inlineDraft, onCommit: {
                model.endInlineEdit(commit: inlineDraft)
            })
            .textFieldStyle(.plain)
            .font(.system(size: min(el.fontSize * s, 96), weight: el.bold ? .bold : .regular))
            .foregroundStyle(.black)
            .focused($inlineFocus)
            .frame(width: max(rect.width, 60), height: max(rect.height, 24))
            .background(RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Design.accent, lineWidth: 1.2))
            .offset(x: offset.x + rect.minX, y: offset.y + rect.minY)
            .onChange(of: inlineFocus) { focused in
                if !focused, model.inlineEditingID != nil {
                    model.endInlineEdit(commit: inlineDraft)
                }
            }
        }
    }

    // MARK: - Snap toggle (§6.6)

    private var snapToggleButton: some View {
        Button {
            snapEnabled.toggle()
        } label: {
            Image(systemName: "ruler")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(snapEnabled ? Design.accent : Design.textTertiary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Design.bgSidebar))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Design.hairline, lineWidth: 1))
                .shadow(color: Design.shadowCard, radius: 4, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(snapEnabled ? "关闭吸附对齐" : "开启吸附对齐")
    }
}

// MARK: - Background grid

/// 8pt 网格点阵（§3.2 bg.canvasGrid）。Equatable：拖拽帧不重绘。
private struct GridLayer: View, Equatable {
    let size: CGSize
    let enabled: Bool

    static func == (a: GridLayer, b: GridLayer) -> Bool {
        a.size == b.size && a.enabled == b.enabled
    }

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Design.bgCanvas))
            guard enabled else { return }
            let step: CGFloat = 8
            var y: CGFloat = step
            while y < size.height {
                var x: CGFloat = step
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)),
                             with: .color(Design.canvasGrid))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Static element layer

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
                             size: el.size, width: el.width, s: s,
                             printableWidth: printableWidth, into: &ctx)
            }
        }
    }

    static func drawOne(_ el: LabelElement, x: Int, y: Int, fontSize: CGFloat,
                        size: Int, width: Int, s: CGFloat, printableWidth: Int,
                        into ctx: inout GraphicsContext) {
        let ew = CGFloat(el.displayWidth(fontSize: fontSize, size: size, x: x, width: width,
                                         printableWidth: printableWidth)) * s
        let eh = CGFloat(el.displayHeight(fontSize: fontSize, size: size, x: x, width: width,
                                          printableWidth: printableWidth)) * s
        let rect = CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s,
                          width: ew, height: eh)
        switch el.kind {
        case .text:
            // G4（预览=打印）：文本用 CoreText 同款 framesetter 预渲染位图，
            // 断行与打印光栅一致（§6.5）。像素密度按 0.25 档取整避免缩放缓存抖动。
            let bucket = max(0.25, (s * 4).rounded() / 4)
            let wrapW = el.wrapWidth(at: x, width: width, printableWidth: printableWidth)
            if let img = LabelRenderer.textPreviewImage(text: el.text, fontSize: fontSize,
                                                        bold: el.bold, width: wrapW,
                                                        pixelScale: bucket) {
                let image = Image(img, scale: bucket, orientation: .up,
                                  label: Text("文本"))
                ctx.draw(image, in: rect)
            }
        case .qr:
            if let cg = LabelRenderer.qrImage(text: el.text, size: size, pixelScale: 4,
                                              correction: el.errorCorrection) {
                ctx.draw(Image(cg, scale: 1, orientation: .up, label: Text("二维码")), in: rect)
            }
        case .barcode:
            if let cg = LabelRenderer.barcodeImage(text: el.text, height: size, pixelScale: 4) {
                ctx.draw(Image(cg, scale: 1, orientation: .up, label: Text("条码")), in: rect)
            }
        }
    }
}

// MARK: - Screen-frame probe (for ⌘-wheel hit testing)

/// Reports this view's frame in screen coordinates so PrintModel's scroll
/// monitor can tell when the cursor is over the canvas (⌘滚轮缩放/滚轮平移 §5.7).
private struct FrameProbe: NSViewRepresentable {
    let onUpdate: (CGRect) -> Void

    final class Probe: NSView {
        var onUpdate: ((CGRect) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification, object: window, queue: .main
                ) { [weak self] _ in self?.report() }
            }
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        fileprivate func report() {
            guard let window, bounds.width > 0 else { return }
            onUpdate?(window.convertToScreen(convert(bounds, to: nil)))
        }
    }

    func makeNSView(context: Context) -> NSView {
        let probe = Probe()
        probe.onUpdate = onUpdate
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Probe)?.onUpdate = onUpdate
    }
}
