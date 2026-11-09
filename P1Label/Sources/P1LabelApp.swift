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
// P1 Label — Mac app for the DeTong P1 label printer (USB/BLE).
// v2 editor: snapshot undo/redo, multi-select, clipboard, keyboard editing
// (design spec v2 §5). All document writes funnel through `mutate` (§5.3).
// Printing/transport logic is unchanged from v1 — the byte stream must stay
// byte-identical (AGENTS.md discipline).

import SwiftUI
import AppKit

// MARK: - App entry

@main
struct P1LabelApp: App {
    @StateObject private var model = PrintModel()

    var body: some Scene {
        WindowGroup("P1Label") {
            ContentView(model: model)
                .frame(minWidth: 1080, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // ⌘Z / ⇧⌘Z / ⌘C / ⌘V / ⌘D / ⌘A route through the field editor when
            // a text field has focus, so copying out of inspector fields keeps
            // working (AppKit menus fire before the responder chain).
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { model.editCommand(.undo) }
                    .keyboardShortcut("z", modifiers: .command)
                Button("重做") { model.editCommand(.redo) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("复制") { model.editCommand(.copy) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("粘贴") { model.editCommand(.paste) }
                    .keyboardShortcut("v", modifiers: .command)
                Button("复制一份") { model.editCommand(.duplicate) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("全选") { model.editCommand(.selectAll) }
                    .keyboardShortcut("a", modifiers: .command)
            }
            CommandMenu("视图") {
                Button("放大") { model.zoomCommand = .zoomIn }
                    .keyboardShortcut("=", modifiers: .command)
                Button("缩小") { model.zoomCommand = .zoomOut }
                    .keyboardShortcut("-", modifiers: .command)
                Button("适应窗口") { model.requestFit() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

// MARK: - Print model

enum TransportMode: String {
    case usb = "USB"
    case ble = "蓝牙"
}

/// Bottom-bar print result summary; the view fades it out after 5 s.
struct PrintResult: Equatable {
    let text: String
    let ok: Bool
}

@MainActor
final class PrintModel: ObservableObject {
    @Published var doc = LabelDocument() {
        didSet { schedulePersist() }
    }
    @Published var selectedElementID: UUID?
    @Published var selectedIDs: Set<UUID> = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var copies = 1
    @Published var darkLevel = 8             // 1..16
    @Published var status = "未连接"
    @Published var connected = false
    @Published var connecting = false
    @Published var deviceSummary = ""
    @Published var printing = false
    @Published var progress: Double = 0
    @Published var pageText = ""             // "第 n/N 页" while printing
    @Published var printResult: PrintResult?
    @Published var mode: TransportMode
    @Published var bleDevices: [P1BLE.DeviceInfo] = []
    /// 画布内联文本编辑（§5.5）；nil = 非编辑态。挂在 model 上以便键盘监听
    /// （Esc 取消）与画布、Inspector 共享。
    @Published var inlineEditingID: UUID?
    /// 空格按下 → 画布手势临时变为平移（§5.7）。
    @Published var spacePanning = false
    /// 吸附对齐开关（画布右下角浮动按钮）。
    @Published var snapEnabled: Bool {
        didSet { UserDefaults.standard.set(snapEnabled, forKey: "P1Label.snap") }
    }
    /// 画布 8pt 网格点阵开关（无选择 Inspector）。
    @Published var showGrid: Bool {
        didSet { UserDefaults.standard.set(showGrid, forKey: "P1Label.grid") }
    }
    /// "滚动画布到该元素" 请求（图层列表单击触发，画布消费）。
    @Published var scrollToElementID: UUID?
    /// "适应窗口" 请求（缩放控件 / 无选择 Inspector，画布消费）。
    @Published var fitRequested = false
    /// ⌘= / ⌘- 快捷键触发的缩放命令（画布消费后置回 nil）。
    @Published var zoomCommand: ZoomCommand?

    enum ZoomCommand { case zoomIn, zoomOut }

    func requestFit() {
        fitRequested = true
    }

    let usb = P1USB()
    let ble = P1BLE()
    private let defaultsKey = "P1Label.document"
    private let modeKey = "P1Label.transport"
    private let bleDeviceKey = "P1Label.blePeripheral"
    private var history = HistoryStack()

    var hasSavedBLEDevice: Bool {
        UserDefaults.standard.string(forKey: bleDeviceKey) != nil
    }

    init() {
        let snap = UserDefaults.standard.object(forKey: "P1Label.snap")
        snapEnabled = snap == nil ? true : UserDefaults.standard.bool(forKey: "P1Label.snap")
        let grid = UserDefaults.standard.object(forKey: "P1Label.grid")
        showGrid = grid == nil ? true : UserDefaults.standard.bool(forKey: "P1Label.grid")
        mode = UserDefaults.standard.string(forKey: modeKey) == TransportMode.ble.rawValue ? .ble : .usb
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(LabelDocument.self, from: data) {
            doc = saved
        }
        // Archives saved before presets carry no presetID; adopt one only when
        // every calibrated value matches (the default 40×30 document is an
        // exact hit), so the picker never mislabels hand-tuned settings.
        if doc.presetID == nil,
           let p = PaperPreset.matching(widthMM: doc.widthMM, heightMM: doc.heightMM,
                                        isDieCut: doc.isDieCut, gapLenMM: doc.gapLenMM) {
            doc.presetID = p.id
        }
        // One-time migration: pull saved elements back inside the paper.
        // Archives saved with the old drag clamp may hold off-paper elements
        // that rendered invisible yet still counted ("空画布却有 N 个元素").
        Self.clampedIntoPaper(&doc)
        ble.onDisconnect = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connected else { return }
                self.connected = false
                self.status = "蓝牙连接已断开"
                self.deviceSummary = ""
            }
        }
    }

    // MARK: History / mutate (§5.3)

    /// The single write path for document edits. Records a snapshot of the
    /// pre-mutation document + selection, skips no-op writes, and keeps
    /// `schedulePersist` (debounced, doc didSet) out of the history stack.
    /// Drag/resize commits and every discrete Inspector/keyboard/paper edit
    /// go through here. Per-keystroke text edits use `editText` coalescing.
    func mutate(_ body: (inout LabelDocument) -> Void) {
        commitPendingTextEdit()
        let baseline = HistoryEntry(doc: doc, selection: selectedIDs)
        var updated = doc
        body(&updated)
        guard updated != doc else { return }
        doc = updated
        history.record(baseline)
        publishHistoryFlags()
    }

    /// Live (per-frame) write used by slider drags and text typing — no
    /// history entry per frame; bracketed by begin/endLiveEdit or coalesced
    /// by `editText` instead.
    private func writeRaw(_ body: (inout LabelDocument) -> Void) {
        var updated = doc
        body(&updated)
        doc = updated
    }

    private func publishHistoryFlags() {
        canUndo = !history.entries.isEmpty
        canRedo = !history.redo.isEmpty
    }

    func undo() {
        commitPendingTextEdit()
        guard let prev = history.undo(current: HistoryEntry(doc: doc, selection: selectedIDs)) else { return }
        doc = prev.doc
        applyRestoredSelection(prev.selection)
        publishHistoryFlags()
    }

    func redo() {
        commitPendingTextEdit()
        guard let next = history.redo(current: HistoryEntry(doc: doc, selection: selectedIDs)) else { return }
        doc = next.doc
        applyRestoredSelection(next.selection)
        publishHistoryFlags()
    }

    private func applyRestoredSelection(_ ids: Set<UUID>) {
        selectedIDs = ids.filter { id in doc.elements.contains { $0.id == id } }
        selectedElementID = topmostID(in: selectedIDs)
    }

    // MARK: Live-edit coalescing (slider drags, text typing)

    private var pendingTextEdit: (id: UUID, baseline: HistoryEntry)?
    private var textEditTask: Task<Void, Never>?

    /// Inspector text/position edits: write live, coalesce an idle burst into
    /// ONE history entry (typing "120" = 1 undo step, not 3).
    func editText(_ id: UUID, _ body: (inout LabelElement) -> Void) {
        if pendingTextEdit?.id != id {
            commitPendingTextEdit()
            pendingTextEdit = (id, HistoryEntry(doc: doc, selection: selectedIDs))
        }
        writeRaw { d in
            if let i = d.elements.firstIndex(where: { $0.id == id }) { body(&d.elements[i]) }
        }
        textEditTask?.cancel()
        textEditTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.commitPendingTextEdit() }
        }
    }

    /// Flush the coalesced text edit into the history stack. Called before
    /// undo/redo/mutate, on submit, and on selection changes.
    func commitPendingTextEdit() {
        textEditTask?.cancel()
        textEditTask = nil
        guard let pending = pendingTextEdit else { return }
        pendingTextEdit = nil
        guard pending.baseline.doc != doc else { return }
        history.record(pending.baseline)
        publishHistoryFlags()
    }

    // MARK: Element writes

    func element(_ id: UUID) -> LabelElement? {
        doc.elements.first { $0.id == id }
    }

    var selectedElement: Binding<LabelElement>? {
        guard let id = selectedElementID,
              doc.elements.contains(where: { $0.id == id }) else { return nil }
        // Bind by element ID, not by array index: inspector controls can flush
        // writes in the same SwiftUI transaction that removes the element, and a
        // captured index would then read/write out of range (crash, 坑 2).
        return Binding(
            get: { self.doc.elements.first(where: { $0.id == id }) ?? LabelElement(kind: .text) },
            set: { updated in self.editText(id) { $0 = updated } }
        )
    }

    private func topmostID(in ids: Set<UUID>) -> UUID? {
        doc.elements.last(where: { ids.contains($0.id) })?.id
    }

    /// Canvas primary-selection updates (click on an element). The id must
    /// exist; selecting nil only clears the primary focus, not the set.
    func setPrimary(_ id: UUID?) {
        guard let id, doc.elements.contains(where: { $0.id == id }) else {
            if id == nil { selectedElementID = nil }
            return
        }
        selectedElementID = id
        selectedIDs.insert(id)
    }

    /// Whole-document write from the canvas gesture surface (drag/resize
    /// commit, delete button, inline editor, layer eye). One write per gesture
    /// = one undo entry (§5.3).
    func applyCanvasWrite(_ newDoc: LabelDocument) {
        guard newDoc != doc else { return }
        commitPendingTextEdit()
        history.record(HistoryEntry(doc: doc, selection: selectedIDs))
        doc = newDoc
        // Dropped/removed elements must not linger in the selection.
        selectedIDs = selectedIDs.filter { id in newDoc.elements.contains { $0.id == id } }
        if let id = selectedElementID, !newDoc.elements.contains(where: { $0.id == id }) {
            selectedElementID = topmostID(in: selectedIDs)
        }
        publishHistoryFlags()
    }

    func setSelection(_ ids: Set<UUID>, primary: UUID? = nil) {
        let valid = ids.filter { id in doc.elements.contains { $0.id == id } }
        selectedIDs = valid
        if let primary, valid.contains(primary) {
            selectedElementID = primary
        } else {
            selectedElementID = topmostID(in: valid)
        }
    }

    /// Multi-select toggle for ⇧-click.
    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            let rest = selectedIDs.subtracting([id])
            setSelection(rest)
        } else {
            setSelection(selectedIDs.union([id]), primary: id)
        }
    }

    func addElement(_ kind: LabelElement.Kind) {
        let el: LabelElement
        switch kind {
        case .text:
            el = LabelElement(kind: .text, text: "新文字", fontSize: 24)
        case .qr:
            el = LabelElement(kind: .qr, text: "内容", size: 80)
        case .barcode:
            el = LabelElement(kind: .barcode, text: "12345678", size: 48)
        }
        let printable = LabelRenderer.paperWidthDots(doc)
        let (_, hDots) = LabelRenderer.contentSize(doc)
        // 添加后元素出现在画布中心（§2.1）。
        let centered = LabelElement(kind: el.kind, x: el.x, y: el.y, text: el.text,
                                    fontSize: el.fontSize, bold: el.bold, size: el.size,
                                    errorCorrection: el.errorCorrection)
        var placed = centered
        placed.x = max(0, (printable - centered.dotsWidth(printableWidth: printable)) / 2)
        placed.y = max(0, (hDots - centered.dotsHeight(printableWidth: printable)) / 2)
        mutate { d in d.elements.append(placed) }
        setSelection([placed.id], primary: placed.id)
    }

    func deleteSelection() {
        guard !selectedIDs.isEmpty else { return }
        mutate { d in d.elements.removeAll { selectedIDs.contains($0.id) } }
        setSelection([])
    }

    /// Toggle 图层显隐 (§5.6). Hidden elements print nothing and skip hit tests.
    func setHidden(_ id: UUID, _ hidden: Bool) {
        mutate { d in
            if let i = d.elements.firstIndex(where: { $0.id == id }) { d.elements[i].hidden = hidden }
        }
    }

    /// Layer list drag = reorder z (§5.6). `to` is the target element's id;
    /// the dragged row lands at its index.
    func moveElement(_ id: UUID, to target: UUID) {
        mutate { d in
            guard let from = d.elements.firstIndex(where: { $0.id == id }),
                  let toIdx = d.elements.firstIndex(where: { $0.id == target }), from != toIdx
            else { return }
            let el = d.elements.remove(at: from)
            let insertAt = d.elements.firstIndex(where: { $0.id == target }) ?? toIdx
            d.elements.insert(el, at: insertAt)
        }
    }

    // MARK: Paper (§6.3) — paper edits are undoable like element edits (§5.3)

    /// Apply a paper preset's calibrated defaults and record its id so the
    /// picker reflects it. Hand edits to width/height afterwards demote the
    /// document to "自定义" (presetID = nil).
    func applyPreset(_ p: PaperPreset) {
        mutate { d in
            d.presetID = p.id
            d.widthMM = p.widthMM
            d.heightMM = p.heightMM
            d.leftPadDots = p.leftPadDots
            d.isDieCut = p.isDieCut
            d.gapLenMM = p.gapLenMM
            Self.clampedIntoPaper(&d)
        }
    }

    /// Hand edits to paper geometry demote to 自定义 and re-clamp elements.
    func editPaper(_ body: (inout LabelDocument) -> Void) {
        mutate { d in
            body(&d)
            Self.clampedIntoPaper(&d)
        }
    }

    /// Clamp every element fully inside the current paper (pure; see
    /// LabelCanvas.commit). 幂等纯函数 — 跨纸张尺寸变更撤销安全（§5.3）。
    static func clampedIntoPaper(_ d: inout LabelDocument) {
        let printable = LabelRenderer.paperWidthDots(d)
        let (_, hDots) = LabelRenderer.contentSize(d)
        for i in d.elements.indices {
            let el = d.elements[i]
            let maxX = max(0, printable - el.dotsWidth(printableWidth: printable))
            let maxY = max(0, hDots - el.dotsHeight(printableWidth: printable))
            d.elements[i].x = max(0, min(el.x, maxX))
            d.elements[i].y = max(0, min(el.y, maxY))
        }
    }

    // MARK: Clipboard (§5.2: ⌘C / ⌘V / ⌘D)

    private static let pasteboardType = NSPasteboard.PasteboardType("local.p1label.elements")

    func copySelection() {
        let els = doc.elements.filter { selectedIDs.contains($0.id) }
        guard !els.isEmpty, let data = try? JSONEncoder().encode(els) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
    }

    func paste() {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType),
              var els = try? JSONDecoder().decode([LabelElement].self, from: data),
              !els.isEmpty else { return }
        // 原位 +8,+8 偏移（§5.2），新 id，贴回后钳制进纸内。
        for i in els.indices {
            els[i].id = UUID()
            els[i].x += 8
            els[i].y += 8
        }
        mutate { d in
            d.elements += els
            Self.clampedIntoPaper(&d)
        }
        setSelection(Set(els.map(\.id)), primary: els.last?.id)
    }

    func duplicateSelection() {
        let els = doc.elements.filter { selectedIDs.contains($0.id) }
        guard !els.isEmpty else { return }
        var copies = els
        for i in copies.indices {
            copies[i].id = UUID()
            copies[i].x += 8
            copies[i].y += 8
        }
        mutate { d in
            d.elements += copies
            Self.clampedIntoPaper(&d)
        }
        setSelection(Set(copies.map(\.id)), primary: copies.last?.id)
    }

    // MARK: Selection helpers (§5.1)

    func selectAll() {
        let ids = Set(doc.elements.filter { !$0.hidden }.map(\.id))
        setSelection(ids)
    }

    /// Esc：多选 → 单选（最后一个）→ 清空（§5.1）。
    func escSelection() {
        if selectedIDs.count > 1 {
            setSelection(Set([selectedElementID].compactMap { $0 }))
        } else {
            setSelection([])
        }
    }

    /// Tab / ⇧Tab：按 z 序循环选中可见元素（§5.1）。
    func tabCycle(backwards: Bool) {
        let visible = doc.elements.filter { !$0.hidden }
        guard !visible.isEmpty else { return }
        let idx = visible.firstIndex(where: { $0.id == selectedElementID })
        let next: LabelElement
        switch idx {
        case nil:
            next = backwards ? visible[visible.count - 1] : visible[0]
        case .some(let i):
            let j = (i + (backwards ? -1 : 1) + visible.count) % visible.count
            next = visible[j]
        }
        setSelection([next.id], primary: next.id)
    }

    /// 方向键微调：1 dot / ⇧ 8 dots，钳制在纸内（§5.2）。
    func nudgeSelection(dx: Int, dy: Int) {
        guard !selectedIDs.isEmpty else { return }
        mutate { d in
            Self.clampedIntoPaper(&d)
            for i in d.elements.indices where selectedIDs.contains(d.elements[i].id) {
                d.elements[i].x += dx
                d.elements[i].y += dy
            }
            Self.clampedIntoPaper(&d)
        }
    }

    // MARK: Inline text editing (§5.5)

    func beginInlineEdit() {
        guard let id = selectedElementID,
              let el = doc.elements.first(where: { $0.id == id }),
              el.kind == .text, !el.hidden else { return }
        commitPendingTextEdit()
        inlineEditingID = id
    }

    /// Enter/失焦提交，Esc 取消（§5.5）。
    func endInlineEdit(commit new: String?) {
        guard let id = inlineEditingID else { return }
        inlineEditingID = nil
        guard let new else { return }
        mutate { d in
            if let i = d.elements.firstIndex(where: { $0.id == id }) { d.elements[i].text = new }
        }
    }

    // MARK: Align & distribute (§5.4)

    enum AlignMode { case left, hCenter, right, top, vCenter, bottom }

    /// 单选：与纸张对齐；多选：选区联合边界内对齐。全部走 mutate 入撤销栈。
    func alignSelection(_ m: AlignMode) {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        mutate { d in
            let printable = LabelRenderer.paperWidthDots(d)
            let (_, hDots) = LabelRenderer.contentSize(d)
            let single = ids.count == 1
            var bounds = CGRect.null
            let rects: [UUID: CGRect] = {
                var out: [UUID: CGRect] = [:]
                for el in d.elements where ids.contains(el.id) {
                    let r = CGRect(x: CGFloat(el.x), y: CGFloat(el.y),
                                   width: CGFloat(el.dotsWidth(printableWidth: printable)),
                                   height: CGFloat(el.dotsHeight(printableWidth: printable)))
                    out[el.id] = r
                    bounds = bounds.union(r)
                }
                return out
            }()
            for i in d.elements.indices where ids.contains(d.elements[i].id) {
                let r = rects[d.elements[i].id]!
                let paper = single
                switch m {
                case .left:
                    d.elements[i].x = Int(paper ? 0 : bounds.minX)
                case .hCenter:
                    let target = paper ? CGFloat(printable) / 2 : bounds.midX
                    d.elements[i].x = max(0, Int((target - r.width / 2).rounded()))
                case .right:
                    let target = paper ? CGFloat(printable) : bounds.maxX
                    d.elements[i].x = max(0, Int((target - r.width).rounded()))
                case .top:
                    d.elements[i].y = Int(paper ? 0 : bounds.minY)
                case .vCenter:
                    let target = paper ? CGFloat(hDots) / 2 : bounds.midY
                    d.elements[i].y = max(0, Int((target - r.height / 2).rounded()))
                case .bottom:
                    let target = paper ? CGFloat(hDots) : bounds.maxY
                    d.elements[i].y = max(0, Int((target - r.height).rounded()))
                }
            }
            Self.clampedIntoPaper(&d)
        }
    }

    /// 分布（≥3 个元素）：按选中元素在联合区间内等距（§5.4）。
    func distributeSelection(horizontal: Bool) {
        let ids = selectedIDs
        guard ids.count >= 3 else { return }
        mutate { d in
            let printable = LabelRenderer.paperWidthDots(d)
            let ordered = d.elements.filter { ids.contains($0.id) }
            func pos(_ el: LabelElement) -> CGFloat {
                horizontal ? CGFloat(el.x) : CGFloat(el.y)
            }
            func span(_ el: LabelElement) -> CGFloat {
                horizontal
                    ? CGFloat(el.dotsWidth(printableWidth: printable))
                    : CGFloat(el.dotsHeight(printableWidth: printable))
            }
            let sorted = ordered.sorted { pos($0) < pos($1) }
            guard let first = sorted.first, let last = sorted.last else { return }
            let start = pos(first)
            let end = pos(last) + span(last)
            let totalSpan = max(end - start, 1)
            let gaps = sorted.map { span($0) }.reduce(0, +)
            let free = max(totalSpan - gaps, 0)
            let step = free / CGFloat(max(sorted.count - 1, 1))
            var cursor = start
            for el in sorted {
                if let i = d.elements.firstIndex(where: { $0.id == el.id }) {
                    let v = Int(cursor.rounded())
                    if horizontal { d.elements[i].x = max(0, v) } else { d.elements[i].y = max(0, v) }
                }
                cursor += span(el) + step
            }
            Self.clampedIntoPaper(&d)
        }
    }

    // MARK: Menu commands with field-editor routing

    enum EditCommand { case undo, redo, copy, paste, duplicate, selectAll }

    /// ⌘编辑命令：文本框聚焦时让位给系统 responder 链（复制出输入框内容）。
    func editCommand(_ cmd: EditCommand) {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isFieldEditor {
            switch cmd {
            case .undo: tv.undoManager?.undo()
            case .redo: tv.undoManager?.redo()
            case .copy: tv.copy(nil)
            case .paste: tv.paste(nil)
            case .selectAll: tv.selectAll(nil)
            case .duplicate: break
            }
            return
        }
        switch cmd {
        case .undo: undo()
        case .redo: redo()
        case .copy: copySelection()
        case .paste: paste()
        case .duplicate: duplicateSelection()
        case .selectAll: selectAll()
        }
    }

    // MARK: Global key / scroll monitoring (§5.2, §5.7)

    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    /// Canvas viewport frame in screen coords (updated by LabelCanvas 的
    /// FrameProbe)；⌘滚轮/滚轮平移命中判定用。
    var canvasScreenFrame: CGRect?
    /// (local x, y in viewport top-left coords, dX, dY, isZoom)
    var canvasScrollHandler: ((CGFloat, CGFloat, CGFloat, CGFloat, Bool) -> Void)?

    func startGlobalMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKeyEvent(event) }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleScrollEvent(event) }
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, window == NSApp.keyWindow else { return event }
        // Text fields (inspector, inline canvas editor) keep their own keys.
        if let tv = window.firstResponder as? NSTextView, tv.isFieldEditor {
            // 画布内联编辑中 Esc 取消（§5.5）。
            if inlineEditingID != nil, event.type == .keyDown, event.keyCode == 53 {
                endInlineEdit(commit: nil)
                return nil
            }
            return event
        }
        guard event.type == .keyDown else {
            if event.keyCode == 49 { return nil }   // space keyUp swallowed
            return event
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command) || flags.contains(.control)
        if hasCommand { return event }   // menus handle ⌘ combos
        switch event.keyCode {
        case 123: nudgeSelection(dx: flags.contains(.shift) ? -8 : -1, dy: 0); return nil
        case 124: nudgeSelection(dx: flags.contains(.shift) ? 8 : 1, dy: 0); return nil
        case 125: nudgeSelection(dx: 0, dy: flags.contains(.shift) ? 8 : 1); return nil
        case 126: nudgeSelection(dx: 0, dy: flags.contains(.shift) ? -8 : -1); return nil
        case 51, 117: deleteSelection(); return nil            // ⌫
        case 53: escSelection(); return nil                    // Esc
        case 48: tabCycle(backwards: flags.contains(.shift)); return nil  // Tab
        case 36, 76: beginInlineEdit(); return nil             // Enter / keypad Enter
        case 49:                                               // Space → pan
            spacePanning = true
            return nil
        default:
            return event
        }
    }

    private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
        guard let frame = canvasScreenFrame,
              frame.contains(NSEvent.mouseLocation) else { return event }
        // Screen → viewport top-left coordinates.
        let x = NSEvent.mouseLocation.x - frame.minX
        let y = frame.maxY - NSEvent.mouseLocation.y
        let zoom = event.modifierFlags.contains(.command)
        canvasScrollHandler?(CGFloat(x), CGFloat(y),
                             event.scrollingDeltaX, event.scrollingDeltaY, zoom)
        return nil
    }

    // MARK: Persistence

    private var persistTask: Task<Void, Never>?

    /// Debounced save — dragging mutates the doc every frame.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            if let data = try? JSONEncoder().encode(self.doc) {
                UserDefaults.standard.set(data, forKey: self.defaultsKey)
            }
        }
    }

    // MARK: Device / transport (unchanged from v1)

    func connect() {
        // Guard against concurrent open() calls: a second attempt would race the
        // same transport instance (leaked handle / double claim on USB, torn
        // GATT state on BLE).
        guard !connecting, !connected else { return }
        connecting = true
        let isBLE = mode == .ble
        status = isBLE ? "蓝牙连接中…" : "连接中…"
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let transport = await MainActor.run { () -> P1Transport in
                    self.mode == .usb ? self.usb : self.ble
                }
                if let ble = transport as? P1BLE {
                    let savedID = UserDefaults.standard.string(forKey: self.bleDeviceKey)
                        .flatMap { UUID(uuidString: $0) }
                    try ble.open(target: savedID)
                } else {
                    try transport.open()
                }
                let summary = "P1 · DPI \(transport.dpi) · 宽 \(transport.printerWidth)点"
                    + (transport.softwareVersion.isEmpty ? "" : " · 固件 \(transport.softwareVersion)")
                await MainActor.run {
                    self.connected = true
                    self.connecting = false
                    self.status = "已连接"
                    self.deviceSummary = summary
                }
            } catch {
                await MainActor.run {
                    self.handleConnectError(error)
                }
            }
        }
    }

    private func handleConnectError(_ error: Error) {
        connected = false
        connecting = false
        switch error {
        case BLEError.ambiguous(let devs):
            bleDevices = devs
            status = "发现多台打印机，请选择"
        case BLEError.notFound:
            status = "未发现蓝牙打印机"
            if mode == .ble { scanForPrinters() }
        default:
            status = "连接失败：\(String(describing: error))"
        }
    }

    /// Blocking scan for the picker; runs off-main so the UI stays responsive.
    func scanForPrinters() {
        guard !connecting, !connected, mode == .ble else { return }
        connecting = true
        status = "扫描蓝牙设备…"
        Task.detached { [weak self] in
            guard let self else { return }
            let ble = await MainActor.run { self.ble }
            let devices = ble.scanDevices()
            await MainActor.run {
                self.connecting = false
                self.bleDevices = devices
                self.status = devices.isEmpty ? "未发现蓝牙设备" : "请选择打印机"
            }
        }
    }

    func selectBLEDevice(_ d: P1BLE.DeviceInfo) {
        guard !connecting, !connected else { return }
        UserDefaults.standard.set(d.identifier.uuidString, forKey: bleDeviceKey)
        connect()
    }

    /// 连接已保存的蓝牙设备（popover「连接」按钮）。
    func connectSavedBLE() {
        guard !connecting, !connected else { return }
        connect()
    }

    func switchMode(_ m: TransportMode) {
        guard m != mode, !printing, !connecting else {
            objectWillChange.send()   // snap the picker back to the active mode
            return
        }
        bleDevices = []
        Task.detached { [weak self] in
            guard let self else { return }
            let (old, usb, ble) = await MainActor.run { (self.mode, self.usb, self.ble) }
            if old == .usb { usb.close() } else { ble.close() }
            await MainActor.run {
                self.mode = m
                self.connected = false
                self.deviceSummary = ""
                self.status = "未连接"
                self.connect()
            }
        }
    }

    // MARK: Print (byte stream unchanged)

    /// Top-bar / bottom-bar connection state line.
    var stateText: String {
        if connected { return "已连接 · \(mode.rawValue)" }
        if connecting { return status }
        return status.hasPrefix("连接失败") || status.hasPrefix("未发现") || status.hasPrefix("发现多台")
            ? "连接失败" : "未连接"
    }

    var isStateError: Bool {
        !connected && !connecting
            && (status.hasPrefix("连接失败") || status.hasPrefix("未发现") || status.hasPrefix("发现多台"))
    }

    /// 连接失败详情（popover 折叠框；nil = 无）。
    var connectionError: String? {
        guard !connected, !connecting, !status.isEmpty, status != "未连接" else { return nil }
        return status
    }

    /// 纸张一句话摘要（顶栏按钮 / 底栏）。
    var paperSummary: String {
        let size = "\(Int(doc.widthMM))×\(Int(doc.heightMM))"
        return doc.isDieCut ? "\(size) 模切" : "\(size) 连续纸"
    }

    func print_() {
        guard connected, !printing else { return }
        printing = true
        progress = 0
        pageText = ""
        status = "发送中…"
        let doc = self.doc
        let copies = max(self.copies, 1)
        let darkness = UInt8(min(max(darkLevel, 1), 16))
        let gapType: UInt8 = doc.isDieCut ? 2 : 0
        let gapLen = Int(doc.gapLenMM * 100)
        let pageKey = Int.random(in: 0..<60000)

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let transport = await MainActor.run { () -> P1Transport in
                    self.mode == .usb ? self.usb : self.ble
                }
                // Render off the main thread — all inputs are value copies and
                // LabelRenderer's caches are lock-guarded, so this is safe to
                // run concurrently and keeps the UI responsive while rendering.
                let payload = LabelRenderer.pagePayload(doc, pageKey: pageKey, copies: copies,
                                                        gapType: gapType, gapLenHundredthsMM: gapLen)
                try transport.write(LPAPI.frame(LPAPI.darknessCmd, [UInt8(darkness - 1)]), timeoutMS: 2000)
                try transport.sendPage(payload) { p in
                    Task { @MainActor in
                        self.progress = p
                        let page = min(copies, Int(p * Double(copies)) + 1)
                        self.pageText = "第 \(page)/\(copies) 页"
                    }
                }
                await MainActor.run {
                    self.printing = false
                    self.progress = 1
                    self.status = "已发送 \(copies) 张"
                    self.showPrintResult(PrintResult(text: "已发送 \(copies) 张", ok: true))
                }
            } catch {
                await MainActor.run {
                    self.printing = false
                    self.status = "打印失败：\(String(describing: error))"
                    self.showPrintResult(PrintResult(text: "打印失败", ok: false))
                }
            }
        }
    }

    private var resultClearTask: Task<Void, Never>?

    private func showPrintResult(_ result: PrintResult) {
        printResult = result
        resultClearTask?.cancel()
        resultClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.printResult = nil }
        }
    }
}
