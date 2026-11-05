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
// P1 Label — Mac app for the DeTong P1 label printer (USB).
// Free-layout editor: drag text / QR / barcode elements on the label canvas.

import SwiftUI

// MARK: - App entry

@main
struct P1LabelApp: App {
    var body: some Scene {
        WindowGroup("P1 标签打印") {
            ContentView()
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Print model

enum TransportMode: String {
    case usb = "USB"
    case ble = "蓝牙"
}

@MainActor
final class PrintModel: ObservableObject {
    @Published var doc = LabelDocument() {
        didSet { schedulePersist() }
    }
    @Published var selectedElementID: UUID?
    @Published var copies = 1
    @Published var darkLevel = 8             // 1..16
    @Published var isDieCut = true
    @Published var gapLenMM = 3.0
    @Published var status = "未连接"
    @Published var connected = false
    @Published var connecting = false
    @Published var deviceSummary = ""
    @Published var printing = false
    @Published var progress: Double = 0
    @Published var mode: TransportMode
    @Published var bleDevices: [P1BLE.DeviceInfo] = []

    let usb = P1USB()
    let ble = P1BLE()
    private let defaultsKey = "P1Label.document"
    private let modeKey = "P1Label.transport"
    private let bleDeviceKey = "P1Label.blePeripheral"

    var hasSavedBLEDevice: Bool {
        UserDefaults.standard.string(forKey: bleDeviceKey) != nil
    }

    init() {
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
                                        isDieCut: isDieCut, gapLenMM: gapLenMM) {
            doc.presetID = p.id
        }
        ble.onDisconnect = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connected else { return }
                self.connected = false
                self.status = "蓝牙连接已断开"
                self.deviceSummary = ""
            }
        }
    }

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

    var selectedElement: Binding<LabelElement>? {
        guard let id = selectedElementID,
              doc.elements.contains(where: { $0.id == id }) else { return nil }
        // Bind by element ID, not by array index: inspector controls can flush
        // writes in the same SwiftUI transaction that removes the element, and a
        // captured index would then read/write out of range (crash).
        return Binding(
            get: { self.doc.elements.first(where: { $0.id == id }) ?? LabelElement(kind: .text) },
            set: { updated in
                if let i = self.doc.elements.firstIndex(where: { $0.id == id }) {
                    self.doc.elements[i] = updated
                }
            }
        )
    }

    func addElement(_ kind: LabelElement.Kind) {
        let el: LabelElement
        switch kind {
        case .text:
            el = LabelElement(kind: .text, x: 6, y: 6, text: "新文字", fontSize: 24)
        case .qr:
            el = LabelElement(kind: .qr, x: 220, y: 40, text: "内容", size: 80)
        case .barcode:
            el = LabelElement(kind: .barcode, x: 6, y: 180, text: "12345678", size: 48)
        }
        doc.elements.append(el)
        selectedElementID = el.id
    }

    func deleteSelected() {
        guard let id = selectedElementID else { return }
        doc.elements.removeAll { $0.id == id }
        selectedElementID = nil
    }

    /// Apply a paper preset's calibrated defaults and record its id so the
    /// picker reflects it. Hand edits to width/height afterwards demote the
    /// document to "自定义" (presetID = nil).
    func applyPreset(_ p: PaperPreset) {
        doc.presetID = p.id
        doc.widthMM = p.widthMM
        doc.heightMM = p.heightMM
        doc.leftPadDots = p.leftPadDots
        isDieCut = p.isDieCut
        gapLenMM = p.gapLenMM
    }

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
            // localizedDescription on these plain Error enums renders the
            // useless "The operation couldn't be completed. (… error N.)";
            // the enums carry real Chinese descriptions via description.
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

    func print_() {
        guard connected, !printing else { return }
        printing = true
        progress = 0
        status = "发送中…"
        let doc = self.doc
        let copies = max(self.copies, 1)
        let darkness = UInt8(min(max(darkLevel, 1), 16))
        let gapType: UInt8 = isDieCut ? 2 : 0
        let gapLen = Int(gapLenMM * 100)
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
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run {
                    self.printing = false
                    self.progress = 1
                    self.status = "已发送 \(copies) 张"
                }
            } catch {
                await MainActor.run {
                    self.printing = false
                    self.status = "打印失败：\(String(describing: error))"
                }
            }
        }
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
        HSplitView {
            editorPane.frame(minWidth: 300, maxWidth: 360)
            canvasPane.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.connect() }
    }

    // MARK: Left column: tools + properties + print settings

    private var editorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                statusHeader

                GroupBox("添加元素") {
                    HStack {
                        Button("＋文字") { model.addElement(.text) }
                        Button("＋二维码") { model.addElement(.qr) }
                        Button("＋条码") { model.addElement(.barcode) }
                        Spacer()
                        Button("删除", role: .destructive) { model.deleteSelected() }
                            .disabled(model.selectedElementID == nil)
                    }
                    Text("在右侧画布上拖动元素调整位置")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let el = model.selectedElement {
                    elementInspector(el)
                }

                GroupBox("纸张") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("尺寸", selection: paperSelection) {
                            ForEach(PaperPreset.all) { p in
                                Text(p.name).tag(p.id)
                            }
                            Text("自定义").tag(PaperPreset.customID)
                        }
                        if let preset = selectedPreset, !preset.hardwareVerified {
                            Text("⚠️ 该尺寸未经真机验证，打印前请用真机校准水平偏移")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("宽").frame(width: 56, alignment: .leading)
                            Stepper(value: paperWidthBinding, in: 20...48, step: 1) {
                                Text("\(model.doc.widthMM, specifier: "%.0f") mm")
                            }
                        }
                        HStack {
                            Text("高").frame(width: 56, alignment: .leading)
                            Stepper(value: paperHeightBinding, in: 10...100, step: 1) {
                                Text("\(model.doc.heightMM, specifier: "%.0f") mm")
                            }
                        }
                        Picker("类型", selection: $model.isDieCut) {
                            Text("模切标签(有间隙)").tag(true)
                            Text("连续纸").tag(false)
                        }
                        if model.isDieCut {
                            HStack {
                                Text("间隙").frame(width: 56, alignment: .leading)
                                Stepper(value: $model.gapLenMM, in: 1...10, step: 0.5) {
                                    Text("\(model.gapLenMM, specifier: "%.1f") mm")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                GroupBox("打印") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("份数").frame(width: 56, alignment: .leading)
                            Stepper(value: $model.copies, in: 1...50) { Text("\(model.copies)") }
                        }
                        HStack {
                            Text("浓度").frame(width: 56, alignment: .leading)
                            Slider(value: Binding(get: { Double(model.darkLevel) },
                                                  set: { model.darkLevel = Int($0) }), in: 1...16, step: 1)
                            Text("\(model.darkLevel)").monospacedDigit().frame(width: 24)
                        }
                        HStack {
                            Text("水平偏移").frame(width: 66, alignment: .leading)
                            Stepper(value: $model.doc.leftPadDots, in: 0...120, step: 1) {
                                Text("\(model.doc.leftPadDots) 点").monospacedDigit()
                            }
                        }
                        HStack {
                            Text("上边距").frame(width: 56, alignment: .leading)
                            Stepper(value: $model.doc.marginTopMM, in: 0...10, step: 0.5) {
                                Text("\(model.doc.marginTopMM, specifier: "%.1f") mm")
                            }
                        }
                        HStack {
                            Text("下边距").frame(width: 56, alignment: .leading)
                            Stepper(value: $model.doc.marginBottomMM, in: 0...10, step: 0.5) {
                                Text("\(model.doc.marginBottomMM, specifier: "%.1f") mm")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func elementInspector(_ binding: Binding<LabelElement>) -> some View {
        let el = binding.wrappedValue
        GroupBox("元素属性 · \(el.kind.label)") {
            VStack(alignment: .leading, spacing: 6) {
                if el.kind == .text {
                    TextField("内容", text: binding.text)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("字号").frame(width: 56, alignment: .leading)
                        Slider(value: binding.fontSize, in: 12...72, step: 2)
                        Text("\(Int(el.fontSize))").monospacedDigit().frame(width: 24)
                        Toggle("粗体", isOn: binding.bold).toggleStyle(.checkbox)
                    }
                    HStack {
                        Text("换行宽").frame(width: 56, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(el.width == 0 ? 200 : el.width) },
                            set: { binding.wrappedValue.width = Int($0) }), in: 40...304, step: 4)
                        Text(el.width == 0 ? "自动" : "\(el.width)").monospacedDigit().frame(width: 40)
                    }
                } else {
                    TextField(el.kind == .qr ? "二维码内容" : "条码内容(字母/数字)",
                              text: binding.text)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text(el.kind == .qr ? "尺寸" : "高度").frame(width: 56, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(el.size) },
                            set: { binding.wrappedValue.size = Int($0) }), in: 24...160, step: 4)
                        Text("\(el.size)").monospacedDigit().frame(width: 24)
                    }
                }
                HStack(spacing: 8) {
                    Text("位置").foregroundStyle(.secondary)
                    // Editable x/y for quick positioning; negative input clamps to 0.
                    TextField("x", value: Binding(
                        get: { el.x },
                        set: { binding.wrappedValue.x = max(0, $0) }
                    ), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 46)
                        .monospacedDigit()
                    Text(",").foregroundStyle(.secondary)
                    TextField("y", value: Binding(
                        get: { el.y },
                        set: { binding.wrappedValue.y = max(0, $0) }
                    ), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 46)
                        .monospacedDigit()
                    Spacer()
                    Stepper("←→", value: Binding(get: { el.x }, set: { binding.wrappedValue.x = $0 }), step: 2)
                    Stepper("↑↓", value: Binding(get: { el.y }, set: { binding.wrappedValue.y = $0 }), step: 2)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var statusHeader: some View {
        // Two rows: status + mode picker on top, connection actions below.
        // Squeezing all three into one HStack let a long error message wrap
        // into a narrow column and shove the controls aside.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.connected ? Color.green
                          : (model.connecting ? Color.orange : Color.red))
                    .frame(width: 9, height: 9)
                Text(model.status)
                    .font(.callout)
                    .lineLimit(2)
                    .help(model.status)
                Spacer()
                Picker("连接方式", selection: Binding(get: { model.mode }, set: { model.switchMode($0) })) {
                    Text("USB").tag(TransportMode.usb)
                    Text("蓝牙").tag(TransportMode.ble)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 118)
                .disabled(model.printing || model.connecting)
            }
            if !model.deviceSummary.isEmpty {
                Text(model.deviceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.deviceSummary)
            }
            if !model.connected {
                HStack(spacing: 8) {
                    Button(model.mode == .ble && !model.hasSavedBLEDevice ? "扫描" : "重连") {
                        if model.mode == .ble && !model.hasSavedBLEDevice {
                            model.scanForPrinters()
                        } else {
                            model.connect()
                        }
                    }
                    .disabled(model.connecting)
                    if model.mode == .ble && !model.bleDevices.isEmpty {
                        Menu("选择打印机") {
                            ForEach(model.bleDevices) { d in
                                Button(deviceLabel(d)) { model.selectBLEDevice(d) }
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func deviceLabel(_ d: P1BLE.DeviceInfo) -> String {
        let name = d.name.isEmpty ? "未命名设备" : d.name
        return d.matchesPrinter ? "\(name) · 打印机" : name
    }

    // MARK: Right: interactive canvas + print button

    private var canvasPane: some View {
        VStack(spacing: 8) {
            LabelCanvas(doc: $model.doc, selectedID: $model.selectedElementID,
                        scale: $previewScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.printing {
                ProgressView(value: model.progress).frame(width: 240)
            }
            HStack {
                Text("预览缩放").font(.caption).foregroundStyle(.secondary)
                Slider(value: $previewScale, in: 0.5...6, step: 0.25)
                    .frame(width: 140)
                Button("适应窗口") { previewScale = 2.0 }
                Spacer()
                Button {
                    model.print_()
                } label: {
                    Text(model.printing ? "发送中…" : "打 印")
                        .frame(width: 120, height: 26)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.connected || model.printing)
            }
        }
        .padding(10)
    }
}
