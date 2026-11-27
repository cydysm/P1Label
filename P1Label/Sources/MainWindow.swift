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
// Main window UI, restyled after the v2 design spec (docs/design-spec-v2.md)
// and the ardot mockups (docs/mockups). Layout: 48pt title row + 44pt toolbar
// row on top, canvas area on the left, 280pt (240–340) property inspector on
// the right, 32pt status bar at the bottom. Device/paper configuration moved
// into popovers; system traffic lights are restored (v1's custom lights and
// full-window drag view are gone). Printing/transport logic stays in
// PrintModel (P1LabelApp.swift) — this file is presentation only.

import SwiftUI
import AppKit

// MARK: - Window chrome

/// 顶栏拖拽条：hiddenTitleBar 窗口没有可拖拽的标题栏，把顶栏上的鼠标按下
/// 转发给 NSWindow.performDrag（真正的系统拖拽循环）。只覆盖顶部 chrome 两行，
/// 画布手势面不受影响 —— isMovableByWindowBackground 会劫持画布拖拽（v1
/// 已在真机验证过该坑，见 git 历史）。
/// 当 `titleBarHeight` 非空时，同时将系统红绿灯垂直居中对齐到该高度的顶栏中。
private struct WindowDragStrip: NSViewRepresentable {
    var titleBarHeight: CGFloat? = nil

    final class StripView: NSView {
        var titleBarHeight: CGFloat?
        private var observers: [NSObjectProtocol] = []

        deinit { removeObservers() }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window, titleBarHeight != nil else { return }
            let nc = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification
            ]
            for name in names {
                observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.alignTrafficLights()
                })
            }
            alignTrafficLights()
            DispatchQueue.main.async { [weak self] in self?.alignTrafficLights() }
        }

        override func layout() {
            super.layout()
            alignTrafficLights()
        }

        private func removeObservers() {
            for obs in observers { NotificationCenter.default.removeObserver(obs) }
            observers.removeAll()
        }

        private func alignTrafficLights() {
            guard let height = titleBarHeight,
                  let window,
                  !window.styleMask.contains(.fullScreen) else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            guard buttons.count == 3,
                  let titlebarView = buttons[0].superview,
                  let container = titlebarView.superview,
                  let themeFrame = container.superview else { return }

            let targetContainer = NSRect(
                x: container.frame.origin.x,
                y: themeFrame.bounds.height - height,
                width: themeFrame.bounds.width,
                height: height
            )
            if container.frame != targetContainer {
                container.frame = targetContainer
            }
            if titlebarView.frame != container.bounds {
                titlebarView.frame = container.bounds
            }

            let leftInset: CGFloat = 16
            let spacing: CGFloat = 20
            for (i, btn) in buttons.enumerated() {
                let target = NSPoint(
                    x: leftInset + CGFloat(i) * spacing,
                    y: round((titlebarView.bounds.height - btn.frame.height) / 2)
                )
                if btn.frame.origin != target {
                    btn.setFrameOrigin(target)
                }
            }
        }
    }

    func makeNSView(context: Context) -> StripView {
        let v = StripView()
        v.titleBarHeight = titleBarHeight
        return v
    }

    func updateNSView(_ nsView: StripView, context: Context) {
        nsView.titleBarHeight = titleBarHeight
    }
}

// MARK: - Popover plumbing

/// Anchor frames (window coords) of popover trigger buttons.
private struct PopoverAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private func popoverAnchor(_ id: String) -> some View {
    GeometryReader { geo in
        Color.clear.preference(key: PopoverAnchorKey.self,
                               value: [id: geo.frame(in: .global)])
    }
}

/// Popover card chrome per the spec (§4): white, radius.panel, hairline stroke,
/// double shadow (near + far), width 308, padding 14, row spacing 10.
private struct PopoverCard<Content: View>: View {
    var width: CGFloat = 308
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusPanel)
                .fill(Design.bgSidebar)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                .shadow(color: .black.opacity(0.12), radius: 24, y: -4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.radiusPanel)
                .stroke(Design.hairline, lineWidth: 1)
        )
    }
}

/// 灰轨白胶囊分段控件（设备 popover「连接方式」，设计稿定稿样式）。
private struct Segmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(label: String, value: T)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let selected = selection == opt.value
                Text(opt.label)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Design.textPrimary : Design.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(selected ? Color.white : .clear)
                            .shadow(color: selected ? .black.opacity(0.08) : .clear, radius: 1, y: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = opt.value }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Design.bgCanvas))
    }
}

/// 行尾小徽章（「上次连接」「打印机」）。
private struct Badge: View {
    let text: String
    var tint: Color = Design.accent

    init(_ text: String, tint: Color = Design.accent) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.12)))
    }
}

// MARK: - Main view

struct ContentView: View {
    @ObservedObject var model: PrintModel
    /// 画布缩放是视图状态（§5.7）：不进撤销栈、不进文档。
    @State private var scale: CGFloat = 2.0
    @State private var showDevicePopover = false
    @State private var showPaperPopover = false
    @State private var anchorFrames: [String: CGRect] = [:]
    @AppStorage("P1Label.inspectorWidth") private var inspectorWidth: Double = 280
    @State private var dividerBase: Double?
    @State private var hoveringDivider = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                titleRow
                toolbarRow
                HStack(spacing: 0) {
                    LabelCanvas(model: model,
                                doc: Binding(
                                    get: { model.doc },
                                    // Canvas commits are whole-doc writes; funnel
                                    // through the history-recording setter.
                                    set: { model.applyCanvasWrite($0) }),
                                selection: Binding(
                                    get: { model.selectedIDs },
                                    set: { model.setSelection($0) }),
                                primaryID: Binding(
                                    get: { model.selectedElementID },
                                    set: { model.setPrimary($0) }),
                                scale: $scale,
                                spacePanning: $model.spacePanning,
                                snapEnabled: $model.snapEnabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    inspectorDivider
                    InspectorPanel(model: model, scale: $scale)
                        .frame(width: inspectorWidth)
                }
                statusBar
            }
            .background(Design.bgWindow)

            // Popover overlay: a transparent catcher dismisses on outside click.
            if showDevicePopover || showPaperPopover {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { closePopovers() }
            }
            if showDevicePopover, let f = anchorFrames["device"] {
                DevicePopover(model: model)
                    .offset(x: f.minX + f.width - 308, y: f.maxY + 6)
            }
            if showPaperPopover, let f = anchorFrames["paper"] {
                PaperPopover(model: model)
                    .offset(x: f.minX + f.width - 308, y: f.maxY + 6)
            }
        }
        .onPreferenceChange(PopoverAnchorKey.self) { anchorFrames = $0 }
        .ignoresSafeArea(edges: .top)
        .onAppear {
            model.startGlobalMonitors()
            model.connect()
            setDefaultWindowSizeIfNeeded()
        }
    }

    private func setDefaultWindowSizeIfNeeded() {
        let key = "P1Label.didDefaultFrame"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
            window.setFrame(CGRect(origin: window.frame.origin, size: CGSize(width: 1280, height: 800)),
                            display: true)
        }
    }

    private func closePopovers() {
        showDevicePopover = false
        showPaperPopover = false
    }

    // MARK: Title row (48pt)

    private var titleRow: some View {
        HStack(spacing: 12) {
            // 系统红绿灯由 WindowDragStrip 垂直居中在 48pt 顶栏左侧（右缘 x=70）；
            // 留出 64pt 空位（加左侧 12pt padding 与 12pt spacing，标题从 x=88 起）。
            Spacer().frame(width: 64)
            Text("P1Label")
                .font(.designTitle)
                .foregroundStyle(Design.textPrimary)
            Spacer()
            paperButton
                .background(popoverAnchor("paper"))
            deviceChip
                .background(popoverAnchor("device"))
            IconButton(symbol: "slider.horizontal.3", help: "打印机与连接") {
                showDevicePopover.toggle()
                showPaperPopover = false
            }
            .padding(.trailing, 12)
        }
        .padding(.leading, 12)
        .frame(height: 48)
        .background(Design.bgSidebar)
        .background(WindowDragStrip(titleBarHeight: 48))
    }

    private var paperButton: some View {
        Button {
            showPaperPopover.toggle()
            showDevicePopover = false
        } label: {
            HStack(spacing: 6) {
                Text("纸张 · \(model.paperSummary)")
                    .font(.designBody)
                    .foregroundStyle(Design.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Design.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Design.radiusControl).fill(Design.bgSidebar))
            .overlay(RoundedRectangle(cornerRadius: Design.radiusControl).stroke(Design.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var deviceChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.connected ? Design.stateOK
                        : model.connecting ? Design.textTertiary
                        : model.isStateError ? Design.stateError : Design.textTertiary)
                .frame(width: 8, height: 8)
            Text(model.stateText)
                .font(.designCaption)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(Rectangle())
        .onTapGesture {
            showDevicePopover.toggle()
            showPaperPopover = false
        }
        .help("打印机与连接")
    }

    // MARK: Toolbar row (44pt)

    private var toolbarRow: some View {
        HStack(spacing: 8) {
            addButton("文字", kind: .text)
            addButton("二维码", kind: .qr)
            addButton("条码", kind: .barcode)
            IconButton(symbol: "arrow.uturn.left", help: "撤销 ⌘Z",
                       disabled: !model.canUndo) { model.undo() }
            IconButton(symbol: "arrow.uturn.right", help: "重做 ⇧⌘Z",
                       disabled: !model.canRedo) { model.redo() }
            Divider().frame(height: 18).overlay(Design.hairline)
            IconButton(symbol: "doc.on.doc", help: "复制 ⌘C",
                       disabled: model.selectedIDs.isEmpty) { model.copySelection() }
            IconButton(symbol: "trash", help: "删除 ⌫",
                       disabled: model.selectedIDs.isEmpty) { model.deleteSelection() }
            Spacer()
            ZoomStepper(scale: $scale, onFit: { model.requestFit() })
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Design.bgSidebar)
        .background(WindowDragStrip())
        .overlay(alignment: .bottom) { Divider().overlay(Design.hairline) }
    }

    private func addButton(_ title: String, kind: LabelElement.Kind) -> some View {
        Button {
            model.addElement(kind)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Design.accent)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Design.radiusControl).fill(Design.accentSubtle))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("添加\(title)元素")
    }

    // MARK: Inspector divider (240–340, remembered)

    private var inspectorDivider: some View {
        ZStack {
            Rectangle().fill(Design.hairline).frame(width: 1)
            Color.clear
                .frame(width: 10)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            let base = dividerBase ?? inspectorWidth
                            if dividerBase == nil { dividerBase = base }
                            inspectorWidth = min(340, max(240, base - g.translation.width))
                        }
                        .onEnded { _ in dividerBase = nil }
                )
                .onHover { hovering in
                    if hovering && !hoveringDivider {
                        hoveringDivider = true
                        NSCursor.resizeLeftRight.push()
                    } else if !hovering && hoveringDivider {
                        hoveringDivider = false
                        NSCursor.pop()
                    }
                }
                .onDisappear {
                    if hoveringDivider {
                        hoveringDivider = false
                        NSCursor.pop()
                    }
                }
        }
        .frame(width: 9)
    }

    // MARK: Status bar (32pt, §6.4)

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.connected ? Design.stateOK
                        : model.connecting ? Design.textTertiary
                        : model.isStateError ? Design.stateError : Design.textTertiary)
                .frame(width: 6, height: 6)
            Text(bottomStateText)
                .font(.designCaption)
                .foregroundStyle(Design.textSecondary)
            Text("· \(model.paperSummary)")
                .font(.designCaption)
                .foregroundStyle(Design.textSecondary)
            if model.doc.isDieCut {
                Text("· 间隙 \(String(format: "%.1f", model.doc.gapLenMM)) mm")
                    .font(.designCaption)
                    .foregroundStyle(Design.textSecondary)
            }
            Text("· \(model.doc.elements.filter { !$0.hidden }.count) 个元素")
                .font(.designCaption)
                .foregroundStyle(Design.textSecondary)
            Spacer()
            if model.printing {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(Design.accent)
                    .frame(width: 160)
                Text(model.pageText)
                    .font(.designCaption)
                    .foregroundStyle(Design.textSecondary)
                    .monospacedDigit()
            } else if let result = model.printResult {
                Text(result.text)
                    .font(.designCaption)
                    .foregroundStyle(result.ok ? Design.stateOK : Design.stateError)
                    .transition(.opacity)
            } else {
                Text("缩放 \(Int((scale * 100).rounded()))%")
                    .font(.designCaption)
                    .foregroundStyle(Design.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Design.bgSidebar)
        .overlay(alignment: .top) { Divider().overlay(Design.hairline) }
    }

    private var bottomStateText: String {
        if model.connected { return "设备已连接 · \(model.mode.rawValue)" }
        if model.connecting { return model.status }
        return model.isStateError ? "设备连接失败" : "设备未连接"
    }
}

// MARK: - Device popover (§6.2)

private struct DevicePopover: View {
    @ObservedObject var model: PrintModel

    var body: some View {
        PopoverCard {
            Text("打印机与连接")
                .font(.designTitle)
                .foregroundStyle(Design.textPrimary)

            HStack(spacing: 8) {
                Circle()
                    .fill(model.connected ? Design.stateOK
                            : model.connecting ? Design.textTertiary
                            : model.isStateError ? Design.stateError : Design.textTertiary)
                    .frame(width: 8, height: 8)
                Text(model.stateText)
                    .font(.designValue)
                    .foregroundStyle(model.isStateError && !model.connecting
                                     ? Design.stateError : Design.textPrimary)
                Spacer(minLength: 0)
                if model.connected && !model.deviceSummary.isEmpty {
                    Text(model.deviceSummary)
                        .font(.designCaption)
                        .foregroundStyle(Design.textTertiary)
                        .lineLimit(1)
                } else if !model.connected, !model.connecting {
                    PillButton(model.mode == .ble && !model.hasSavedBLEDevice ? "扫描" : "重连") {
                        if model.mode == .ble && !model.hasSavedBLEDevice {
                            model.scanForPrinters()
                        } else {
                            model.connect()
                        }
                    }
                    .disabled(model.connecting || model.printing)
                }
            }
            if let detail = model.connectionError {
                DisclosureGroup {
                    Text(detail)
                        .font(.designCaption)
                        .foregroundStyle(Design.stateError)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("详细信息")
                        .font(.designCaption)
                        .foregroundStyle(Design.textSecondary)
                }
            }

            Divider().overlay(Design.hairline)

            VStack(alignment: .leading, spacing: 8) {
                Text("连接方式")
                    .font(.designCaption)
                    .foregroundStyle(Design.textSecondary)
                Segmented(selection: Binding(get: { model.mode },
                                             set: { model.switchMode($0) }),
                          options: [("USB", TransportMode.usb), ("蓝牙", TransportMode.ble)])
                    .disabled(model.printing || model.connecting)
            }

            if model.mode == .usb {
                Text("USB 插入打印机即连；连接失败时点「重连」重试。")
                    .font(.designCaption)
                    .foregroundStyle(Design.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                bleSection
            }
        }
    }

    @ViewBuilder
    private var bleSection: some View {
        if model.hasSavedBLEDevice {
            HStack(spacing: 8) {
                Text("P1 打印机")
                    .font(.designValue)
                    .foregroundStyle(Design.accent)
                Badge("上次连接")
                Spacer(minLength: 0)
                PillButton("连接") { model.connectSavedBLE() }
                    .disabled(model.connecting || model.printing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Design.radiusControl).fill(Design.accentSubtle))
        }

        if !model.bleDevices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("附近设备")
                    .font(.designCaption)
                    .foregroundStyle(Design.textSecondary)
                ForEach(model.bleDevices) { d in
                    deviceRow(d)
                }
            }
        }

        Text("多数机型仅允许单连接：请先断开手机打印 App 的占用。")
            .font(.designCaption)
            .foregroundStyle(Design.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 附近设备行（32pt）：已识别 accent 点 + 「打印机」badge；未识别灰点。
    private func deviceRow(_ d: P1BLE.DeviceInfo) -> some View {
        let name = d.name.isEmpty ? "未命名设备" : d.name
        return HStack(spacing: 8) {
            Circle()
                .fill(d.matchesPrinter ? Design.accent : Design.textTertiary)
                .frame(width: 6, height: 6)
            Text(name)
                .font(.designBody)
                .foregroundStyle(d.matchesPrinter ? Design.textPrimary : Design.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if d.matchesPrinter {
                Badge("打印机")
            }
        }
        .frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture { model.selectBLEDevice(d) }
        .opacity(model.connecting || model.connected ? 0.5 : 1)
    }
}

// MARK: - Paper popover (§6.3)

private struct PaperPopover: View {
    @ObservedObject var model: PrintModel

    // Picking a preset applies its calibrated defaults; editing width/height
    // by hand demotes the document to "自定义" (presetID = nil) so the picker
    // never claims values that were changed since (v1 semantics preserved).
    private var paperSelection: Binding<String> {
        Binding(
            get: {
                guard let id = model.doc.presetID, PaperPreset.byID(id) != nil else {
                    return PaperPreset.customID
                }
                return id
            },
            set: { id in
                if let p = PaperPreset.byID(id) {
                    model.applyPreset(p)
                } else {
                    model.editPaper { $0.presetID = nil }
                }
            }
        )
    }

    private var paperWidthBinding: Binding<Double> {
        Binding(
            get: { model.doc.widthMM },
            set: { newValue in
                model.editPaper { $0.presetID = nil; $0.widthMM = newValue.rounded() }
            }
        )
    }

    private var paperHeightBinding: Binding<Double> {
        Binding(
            get: { model.doc.heightMM },
            set: { newValue in
                model.editPaper { $0.presetID = nil; $0.heightMM = newValue.rounded() }
            }
        )
    }

    private var leftPadBinding: Binding<Double> {
        Binding(
            get: { Double(model.doc.leftPadDots) },
            set: { newValue in model.editPaper { $0.leftPadDots = Int(newValue.rounded()) } }
        )
    }

    private var selectedPreset: PaperPreset? {
        model.doc.presetID.flatMap { PaperPreset.byID($0) }
    }

    /// 仅自定义/未验证纸张显示警告条（§6.3）。
    private var unverified: Bool {
        selectedPreset.map { !$0.hardwareVerified } ?? true
    }

    var body: some View {
        PopoverCard {
            Text("纸张与校准")
                .font(.designTitle)
                .foregroundStyle(Design.textPrimary)

            HStack(spacing: 8) {
                RowLabel("尺寸", width: 36)
                PickerField(selection: paperSelection,
                            options: PaperPreset.all.map { ($0.name, $0.id) }
                                    + [("自定义", PaperPreset.customID)])
            }

            if unverified {
                Text("该尺寸未经真机验证，打印前请用真机校准水平偏移")
                    .font(.designCaption)
                    .foregroundStyle(Design.stateWarn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Design.radiusControl)
                        .fill(Design.stateWarn.opacity(0.12)))
            }

            HStack(spacing: 8) {
                RowLabel("宽", width: 16)
                StepperField(value: paperWidthBinding, range: 20...48, step: 1,
                             format: { String(format: "%.0f mm", $0) })
                RowLabel("高", width: 16)
                StepperField(value: paperHeightBinding, range: 10...100, step: 1,
                             format: { String(format: "%.0f mm", $0) })
            }

            HStack(spacing: 8) {
                RowLabel("类型", width: 36)
                PickerField(selection: Binding(
                                get: { model.doc.isDieCut },
                                set: { newValue in model.editPaper { $0.isDieCut = newValue } }),
                            options: [("模切标签（有间隙）", true), ("连续纸", false)])
            }

            if model.doc.isDieCut {
                HStack(spacing: 8) {
                    RowLabel("间隙", width: 36)
                    StepperField(value: Binding(
                                     get: { model.doc.gapLenMM },
                                     set: { newValue in model.editPaper { $0.gapLenMM = newValue } }),
                                 range: 1...10, step: 0.5,
                                 format: { String(format: "%.1f mm", $0) })
                }
            }

            Divider().overlay(Design.hairline)

            Text("校准与边距（随纸张预设保存）")
                .font(.designCaption)
                .foregroundStyle(Design.textSecondary)

            HStack(spacing: 8) {
                RowLabel("水平偏移", width: 56)
                StepperField(value: leftPadBinding, range: 0...120, step: 1,
                             format: { String(format: "%.0f 点", $0) },
                             warnValue: unverified)
            }
            HStack(spacing: 8) {
                RowLabel("上边距", width: 56)
                StepperField(value: Binding(
                                 get: { model.doc.marginTopMM },
                                 set: { newValue in model.editPaper { $0.marginTopMM = newValue } }),
                             range: 0...10, step: 0.5,
                             format: { String(format: "%.1f mm", $0) })
            }
            HStack(spacing: 8) {
                RowLabel("下边距", width: 56)
                StepperField(value: Binding(
                                 get: { model.doc.marginBottomMM },
                                 set: { newValue in model.editPaper { $0.marginBottomMM = newValue } }),
                             range: 0...10, step: 0.5,
                             format: { String(format: "%.1f mm", $0) })
            }
        }
    }
}
