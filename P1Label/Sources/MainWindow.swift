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
// Main window UI, restyled after the "P1 标签打印 · 主窗口（重构版）" design
// (pagx export). Layout: custom title bar + 360pt settings sidebar + canvas
// area with info bar and bottom status bar. All printing/transport logic
// stays in PrintModel (P1LabelApp.swift) — this file is presentation only.

import SwiftUI
import AppKit

// MARK: - Design tokens (values taken from the pagx design)

enum Design {
    static let accent = Color(red: 0x0A / 255, green: 0x60 / 255, blue: 0xFF / 255)
    static let accentSoft = Color(red: 0xED / 255, green: 0xF3 / 255, blue: 0xFF / 255)
    static let textPrimary = Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255)
    static let textMid = Color(red: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255)
    static let textSecondary = Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255)
    static let textTertiary = Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8B / 255)
    static let errorText = Color(red: 0xB3 / 255, green: 0x26 / 255, blue: 0x1E / 255)
    static let errorBg = Color(red: 0xFD / 255, green: 0xF1 / 255, blue: 0xF0 / 255)
    static let errorDot = Color(red: 0xD7 / 255, green: 0x00 / 255, blue: 0x15 / 255)
    static let okDot = Color(red: 0x28 / 255, green: 0xC8 / 255, blue: 0x40 / 255)
    static let idleDot = Color(red: 0xC7 / 255, green: 0xC7 / 255, blue: 0xCC / 255)
    static let fieldBorder = Color(red: 0xD9 / 255, green: 0xD9 / 255, blue: 0xDE / 255)
    static let sliderTrack = Color(red: 0xE3 / 255, green: 0xE3 / 255, blue: 0xE8 / 255)
    static let segmentBg = Color(red: 0xE7 / 255, green: 0xE7 / 255, blue: 0xEC / 255)
    static let sidebarBg = Color(red: 0xF9 / 255, green: 0xFB / 255, blue: 0xFF / 255)
    static let canvasBg = Color(red: 0xDC / 255, green: 0xE0 / 255, blue: 0xE9 / 255)
    static let hairline = Color.black.opacity(0.06)
}

// MARK: - Shared styling helpers

extension View {
    /// White rounded card with the design's soft drop shadow.
    func card() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
            .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
    }

    /// White bordered field chrome used by steppers, menus and value boxes.
    func fieldFrame(height: CGFloat = 26, radius: CGFloat = 6) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Design.fieldBorder, lineWidth: 1))
    }
}

/// Section heading above a card ("添加元素", "纸张", …).
private func sectionTitle(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Design.textMid)
}

/// Row label inside a card.
private func rowLabel(_ text: String, width: CGFloat) -> some View {
    Text(text)
        .font(.system(size: 11))
        .foregroundStyle(Design.textSecondary)
        .frame(width: width, alignment: .leading)
}

// MARK: - Window chrome helpers

/// hiddenTitleBar windows have no title bar to drag. Enabling
/// isMovableByWindowBackground instead would hijack EVERY drag — the canvas
/// gesture surface is a non-opaque SwiftUI view, so the window-move machinery
/// moves the window instead of dragging elements (verified on hardware).
/// Fix: keep the flag off and forward mouse-downs from the title bar only to
/// NSWindow.performDrag, which runs the real window-drag tracking loop.
private struct TitleBarDragView: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Custom controls

/// Horizontal slider matching the design: 3pt track, blue fill, blue knob.
/// `snap` quantizes the value (nil = continuous).
private struct HSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var snap: Double?

    var body: some View {
        GeometryReader { geo in
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(Design.sliderTrack).frame(height: 3)
                Capsule().fill(Design.accent)
                    .frame(width: max(0, min(geo.size.width, geo.size.width * frac)), height: 3)
                Circle().fill(Design.accent)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                    .offset(x: max(0, min(geo.size.width - 12, geo.size.width * frac - 6)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(max(g.location.x / geo.size.width, 0), 1)
                var v = range.lowerBound + f * (range.upperBound - range.lowerBound)
                if let snap { v = (v / snap).rounded() * snap }
                value = min(max(v, range.lowerBound), range.upperBound)
            })
        }
        .frame(height: 16)
    }
}

/// Numeric stepper styled like the design: value text + stacked chevrons.
private struct StepperField: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String

    var body: some View {
        HStack(spacing: 0) {
            Text(format(value))
                .font(.system(size: 12))
                .foregroundStyle(Design.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.leading, 10)
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                chevron("chevron.up") { bump(+1) }
                chevron("chevron.down") { bump(-1) }
            }
            .padding(.trailing, 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .fieldFrame()
    }

    private func chevron(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(Design.textSecondary)
                .frame(width: 16, height: 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bump(_ direction: Double) {
        value = min(max(value + direction * step, range.lowerBound), range.upperBound)
    }
}

/// Dropdown styled like the design's value fields with an up/down chevron.
/// The chevron is an overlay (hit-test disabled): .borderlessButton menus
/// center their own label and swallow in-label decorations.
private struct MenuField<T: Hashable>: View {
    @Binding var selection: T
    let options: [(label: String, value: T)]

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { opt in
                Button(opt.label) { selection = opt.value }
            }
        } label: {
            HStack(spacing: 4) {
                Text(options.first(where: { $0.value == selection })?.label ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(Design.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .fieldFrame()
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Design.textTertiary)
                .padding(.trailing, 8)
                .allowsHitTesting(false)
        }
    }
}

/// Segmented control per the design: gray track, white selected pill.
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
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selected ? Color.white : .clear)
                            .shadow(color: selected ? .black.opacity(0.08) : .clear, radius: 1, y: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = opt.value }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7).fill(Design.segmentBg))
    }
}

// MARK: - Formatting helpers

private func formatMM0(_ v: Double) -> String { String(format: "%.0f mm", v) }
private func formatMM1(_ v: Double) -> String { String(format: "%.1f mm", v) }

/// Numeric text field that commits valid (>= 0) integers on every keystroke
/// and resyncs its display from the binding on submit and external changes
/// (drags, steppers, element switches).
private struct PositionField: View {
    var placeholder: String
    @Binding var value: Int
    @State private var text = ""

    var body: some View {
        // Left-aligned like every other field: .plain TextFields with
        // .multilineTextAlignment(.center) on macOS don't render their text
        // until focused (verified: value present via accessibility, invisible
        // on screen).
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(Design.textPrimary)
            .padding(.leading, 10)
            .frame(height: 26)
            .fieldFrame()
            .onAppear { text = "\(value)" }
            .onChange(of: value) { text = "\($0)" }
            .onChange(of: text) { new in
                if let v = Int(new), v >= 0, v != value { value = v }
            }
            .onSubmit { text = "\(value)" }
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var model = PrintModel()
    @State private var previewScale: CGFloat = 2.0

    // MARK: Paper size selection
    //
    // Picking a preset applies its calibrated defaults; editing width/height
    // by hand demotes the document to "自定义" (presetID = nil) so the picker
    // never claims values that were changed since.

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
                    model.doc.presetID = nil
                }
            }
        )
    }

    private var selectedPreset: PaperPreset? {
        model.doc.presetID.flatMap { PaperPreset.byID($0) }
    }

    private var paperWidthBinding: Binding<Double> {
        Binding(
            get: { model.doc.widthMM },
            set: {
                model.doc.presetID = nil
                model.doc.widthMM = $0
            }
        )
    }

    private var paperHeightBinding: Binding<Double> {
        Binding(
            get: { model.doc.heightMM },
            set: {
                model.doc.presetID = nil
                model.doc.heightMM = $0
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(Design.hairline).frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 360)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Design.hairline).frame(width: 1)
                    }
                canvasPane
            }
        }
        .background(
            LinearGradient(colors: [Color(red: 0xF5 / 255, green: 0xF6 / 255, blue: 0xFA / 255),
                                    Color(red: 0xE6 / 255, green: 0xE9 / 255, blue: 0xF2 / 255)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .background(Color.clear)
        .onAppear { model.connect() }
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack {
            Text("P1 标签打印")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Design.textPrimary)
            Spacer()
        }
        // Leaves room for the traffic lights (hiddenTitleBar keeps them).
        .padding(.leading, 78)
        .frame(height: 52)
        .background(Design.sidebarBg)
        .background(TitleBarDragView())
    }

    // MARK: Left column: device, tools, properties, paper, print

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 14) {
                deviceCard
                addElementsSection
                if let el = model.selectedElement {
                    elementSection(el)
                        // New identity per selected element: otherwise the
                        // TextFields keep their internal edit state across
                        // selection changes and show the previous element's
                        // stale content (verified: new element showed "1").
                        .id(model.selectedElementID)
                }
                paperSection
                printSection
            }
            .padding(16)
        }
        .background(Design.sidebarBg)
    }

    // MARK: Device status card

    /// Long failure text shown in the red detail box; nil when the state is
    /// plain (unconnected / connecting / connected).
    private var connectionError: String? {
        guard !model.connected, !model.connecting, !model.status.isEmpty else { return nil }
        return model.status == "未连接" ? nil : model.status
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.connected ? Design.okDot
                            : model.connecting ? Design.idleDot
                            : connectionError != nil ? Design.errorDot : Design.idleDot)
                    .frame(width: 8, height: 8)
                Text(model.connected ? "设备已连接"
                        : model.connecting ? model.status : "设备未连接")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(connectionError != nil && !model.connecting
                                     ? Design.errorText : Design.textPrimary)
                Spacer()
                if !model.connected {
                    reconnectControls
                }
            }
            if let detail = connectionError {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Design.errorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Design.errorBg))
            }
            if model.connected && !model.deviceSummary.isEmpty {
                Text(model.deviceSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(Design.textTertiary)
            }
            Segmented(selection: Binding(get: { model.mode }, set: { model.switchMode($0) }),
                      options: [("USB", TransportMode.usb), ("蓝牙", TransportMode.ble)])
                .disabled(model.printing || model.connecting)
        }
        .card()
    }

    @ViewBuilder
    private var reconnectControls: some View {
        if model.mode == .ble && !model.bleDevices.isEmpty {
            Menu {
                ForEach(model.bleDevices) { d in
                    Button(deviceLabel(d)) { model.selectBLEDevice(d) }
                }
            } label: {
                smallButtonLabel("选择打印机", color: Design.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Button {
                if model.mode == .ble && !model.hasSavedBLEDevice {
                    model.scanForPrinters()
                } else {
                    model.connect()
                }
            } label: {
                smallButtonLabel(model.mode == .ble && !model.hasSavedBLEDevice ? "扫描" : "重连",
                                 color: connectionError != nil ? Design.errorText : Design.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(model.connecting || model.printing)
        }
    }

    /// Small white pill button (the design's 重连 button).
    private func smallButtonLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Design.fieldBorder, lineWidth: 1))
            .contentShape(Rectangle())
    }

    private func deviceLabel(_ d: P1BLE.DeviceInfo) -> String {
        let name = d.name.isEmpty ? "未命名设备" : d.name
        return d.matchesPrinter ? "\(name) · 打印机" : name
    }

    // MARK: Add elements

    private var addElementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("添加元素")
            HStack(spacing: 8) {
                addButton("文字")
                addButton("二维码")
                addButton("条码")
            }
        }
    }

    private func addButton(_ title: String) -> some View {
        let kind: LabelElement.Kind = title == "文字" ? .text : title == "二维码" ? .qr : .barcode
        return Button {
            model.addElement(kind)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Design.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Design.accentSoft))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Selected element inspector

    private func elementSection(_ binding: Binding<LabelElement>) -> some View {
        let el = binding.wrappedValue
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("元素属性 · \(el.kind.label)")
            VStack(alignment: .leading, spacing: 10) {
                TextField(el.kind == .text ? "元素名称" :
                            el.kind == .qr ? "二维码内容" : "条码内容(字母/数字)",
                          text: binding.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Design.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .fieldFrame()

                if el.kind == .text {
                    HStack(spacing: 8) {
                        rowLabel("字号", width: 30)
                        HSlider(value: Binding(
                            get: { Double(el.fontSize) },
                            set: { binding.wrappedValue.fontSize = CGFloat($0) }
                        ), range: 12...72, snap: 2)
                        valueBox("\(Int(el.fontSize))", width: 44)
                        boldToggle(binding)
                    }
                    HStack(spacing: 8) {
                        rowLabel("换行宽", width: 44)
                        HSlider(value: Binding(
                            get: { Double(el.width == 0 ? 200 : el.width) },
                            set: { binding.wrappedValue.width = Int($0.rounded()) }
                        ), range: 40...304, snap: 4)
                        Text(el.width == 0 ? "自动" : "\(el.width)")
                            .font(.system(size: 12))
                            .foregroundStyle(Design.textPrimary)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                } else {
                    HStack(spacing: 8) {
                        rowLabel(el.kind == .qr ? "尺寸" : "高度", width: 30)
                        HSlider(value: Binding(
                            get: { Double(el.size) },
                            set: { binding.wrappedValue.size = Int($0.rounded()) }
                        ), range: 24...160, snap: 4)
                        valueBox("\(el.size)", width: 44)
                    }
                }

                HStack(spacing: 8) {
                    rowLabel("位置", width: 30)
                    positionField("X", value: Binding(
                        get: { el.x }, set: { binding.wrappedValue.x = max(0, $0) }))
                    positionField("Y", value: Binding(
                        get: { el.y }, set: { binding.wrappedValue.y = max(0, $0) }))
                }
            }
            .card()
        }
    }

    private func boldToggle(_ binding: Binding<LabelElement>) -> some View {
        let on = binding.wrappedValue.bold
        return Button {
            binding.wrappedValue.bold.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(on ? Design.accent : Design.textTertiary)
                Text("粗体")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func valueBox(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Design.textPrimary)
            .monospacedDigit()
            .frame(width: width, height: 26)
            .fieldFrame()
    }

    /// Editable x/y numeric field. String-backed (not TextField(value:format:))
    /// because a failed parse there leaves the field showing the stale typed
    /// text (e.g. empty) with no way back to the real value until it changes.
    private func positionField(_ placeholder: String,
                               value: Binding<Int>) -> some View {
        PositionField(placeholder: placeholder, value: value)
    }

    // MARK: Paper

    private var paperSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("纸张")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    rowLabel("尺寸", width: 30)
                    MenuField(selection: paperSelection,
                              options: PaperPreset.all.map { ($0.name, $0.id) }
                                      + [("自定义", PaperPreset.customID)])
                }
                if let preset = selectedPreset, !preset.hardwareVerified {
                    Text("⚠️ 该尺寸未经真机验证，打印前请用真机校准水平偏移")
                        .font(.system(size: 11))
                        .foregroundStyle(Design.textTertiary)
                }
                HStack(spacing: 8) {
                    rowLabel("宽", width: 30)
                    StepperField(value: paperWidthBinding, range: 20...48, step: 1,
                                 format: formatMM0)
                }
                HStack(spacing: 8) {
                    rowLabel("高", width: 30)
                    StepperField(value: paperHeightBinding, range: 10...100, step: 1,
                                 format: formatMM0)
                }
                HStack(spacing: 8) {
                    rowLabel("类型", width: 30)
                    MenuField(selection: $model.isDieCut,
                              options: [("模切标签（有间隙）", true), ("连续纸", false)])
                }
                if model.isDieCut {
                    HStack(spacing: 8) {
                        rowLabel("间隙", width: 30)
                        StepperField(value: $model.gapLenMM, range: 1...10, step: 0.5,
                                     format: formatMM1)
                    }
                }
            }
            .card()
        }
    }

    // MARK: Print

    private var copiesBinding: Binding<Double> {
        Binding(get: { Double(model.copies) }, set: { model.copies = Int($0) })
    }

    private var leftPadBinding: Binding<Double> {
        Binding(get: { Double(model.doc.leftPadDots) },
                set: { model.doc.leftPadDots = Int($0) })
    }

    private var printSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("打印")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    rowLabel("份数", width: 44)
                    StepperField(value: copiesBinding, range: 1...50, step: 1,
                                 format: { String(format: "%.0f", $0) })
                }
                HStack(spacing: 8) {
                    rowLabel("浓度", width: 44)
                    HSlider(value: Binding(get: { Double(model.darkLevel) },
                                           set: { model.darkLevel = Int($0) }),
                            range: 1...16, snap: 1)
                    Text("\(model.darkLevel)")
                        .font(.system(size: 12))
                        .foregroundStyle(Design.textPrimary)
                        .monospacedDigit()
                        .frame(width: 24, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    rowLabel("水平偏移", width: 44)
                    StepperField(value: leftPadBinding, range: 0...120, step: 1,
                                 format: { String(format: "%.0f 点", $0) })
                }
                HStack(spacing: 8) {
                    rowLabel("上边距", width: 44)
                    StepperField(value: $model.doc.marginTopMM, range: 0...10, step: 0.5,
                                 format: formatMM1)
                }
                HStack(spacing: 8) {
                    rowLabel("下边距", width: 44)
                    StepperField(value: $model.doc.marginBottomMM, range: 0...10, step: 0.5,
                                 format: formatMM1)
                }
            }
            .card()
        }
    }

    // MARK: Right: info bar + canvas + status bar

    private var paperDescription: String {
        model.isDieCut ? "模切标签 · 间隙 \(String(format: "%.1f", model.gapLenMM)) mm" : "连续纸"
    }

    private var canvasPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("标签预览")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Design.textPrimary)
                Text(paperDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(Design.textSecondary)
                Spacer()
                Text("\(model.doc.elements.count) 个元素")
                    .font(.system(size: 12))
                    .foregroundStyle(Design.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(.white)

            Rectangle().fill(Design.hairline).frame(height: 1)

            LabelCanvas(doc: $model.doc, selectedID: $model.selectedElementID,
                        scale: $previewScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Design.canvasBg)

            if model.printing {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(Design.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            Rectangle().fill(Design.hairline).frame(height: 1)

            HStack(spacing: 10) {
                Text("标签缩放")
                    .font(.system(size: 12))
                    .foregroundStyle(Design.textSecondary)
                HSlider(value: Binding(get: { Double(previewScale) },
                                       set: { previewScale = CGFloat($0) }),
                        range: 0.5...6)
                    .frame(width: 120)
                Button {
                    previewScale = 2.0
                } label: {
                    Text("适应窗口")
                        .font(.system(size: 11))
                        .foregroundStyle(Design.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Design.fieldBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    model.print_()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "printer")
                            .font(.system(size: 12, weight: .medium))
                        Text(model.printing ? "发送中…" : "打印")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 85, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Design.accent))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.connected || model.printing)
                .opacity(model.connected ? 1 : 0.4)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(.white)
        }
    }
}
