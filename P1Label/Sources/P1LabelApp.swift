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
                .frame(minWidth: 1080, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
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
        // One-time migration: pull saved elements back inside the paper.
        // Archives saved with the old drag clamp may hold off-paper elements
        // that rendered invisible yet still counted ("空画布却有 N 个元素").
        clampElementsIntoPaper()
        ble.onDisconnect = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connected else { return }
                self.connected = false
                self.status = "蓝牙连接已断开"
                self.deviceSummary = ""
            }
        }
    }

    /// Clamp every element fully inside the current paper (see LabelCanvas.commit).
    private func clampElementsIntoPaper() {
        let printable = LabelRenderer.paperWidthDots(doc)
        let (_, hDots) = LabelRenderer.contentSize(doc)
        for i in doc.elements.indices {
            let el = doc.elements[i]
            let maxX = max(0, printable - el.dotsWidth(printableWidth: printable))
            let maxY = max(0, hDots - el.dotsHeight(printableWidth: printable))
            doc.elements[i].x = max(0, min(el.x, maxX))
            doc.elements[i].y = max(0, min(el.y, maxY))
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
            status = "连接失败：\(error.localizedDescription)"
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
                    self.status = "打印失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
