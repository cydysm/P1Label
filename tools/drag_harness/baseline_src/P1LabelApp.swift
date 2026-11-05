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

    let usb = P1USB()
    private let defaultsKey = "P1Label.document"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(LabelDocument.self, from: data) {
            doc = saved
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

    func connect() {
        // Guard against concurrent open() calls: a second attempt would race the
        // same P1USB instance (leaked handle, double interface claim).
        guard !connecting, !connected else { return }
        connecting = true
        status = "连接中…"
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let usb = await MainActor.run { self.usb }
                try usb.open()
                let summary = "P1 · DPI \(usb.dpi) · 宽 \(usb.printerWidth)点"
                    + (usb.softwareVersion.isEmpty ? "" : " · 固件 \(usb.softwareVersion)")
                await MainActor.run {
                    self.connected = true
                    self.connecting = false
                    self.status = "已连接"
                    self.deviceSummary = summary
                }
            } catch {
                await MainActor.run {
                    self.connected = false
                    self.connecting = false
                    self.status = "连接失败：\(error.localizedDescription)"
                }
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
                let usb = await MainActor.run { self.usb }
                // Render off the main thread — all inputs are value copies and
                // LabelRenderer's caches are lock-guarded, so this is safe to
                // run concurrently and keeps the UI responsive while rendering.
                let payload = LabelRenderer.pagePayload(doc, pageKey: pageKey, copies: copies,
                                                        gapType: gapType, gapLenHundredthsMM: gapLen)
                try usb.write(LPAPI.frame(LPAPI.darknessCmd, [UInt8(darkness - 1)]))
                try usb.sendPage(payload) { p in
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

// MARK: - Main view

struct ContentView: View {
    @StateObject private var model = PrintModel()
    @State private var previewScale: CGFloat = 2.0

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
                        HStack {
                            Text("宽").frame(width: 56, alignment: .leading)
                            Stepper(value: $model.doc.widthMM, in: 20...48, step: 1) {
                                Text("\(model.doc.widthMM, specifier: "%.0f") mm")
                            }
                        }
                        HStack {
                            Text("高").frame(width: 56, alignment: .leading)
                            Stepper(value: $model.doc.heightMM, in: 10...100, step: 1) {
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
                HStack(spacing: 12) {
                    Text("位置").foregroundStyle(.secondary)
                    Text("x \(el.x)").monospacedDigit()
                    Text("y \(el.y)").monospacedDigit()
                    Spacer()
                    Stepper("←→", value: Binding(get: { el.x }, set: { binding.wrappedValue.x = $0 }), step: 2)
                    Stepper("↑↓", value: Binding(get: { el.y }, set: { binding.wrappedValue.y = $0 }), step: 2)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var statusHeader: some View {
        HStack {
            Circle()
                .fill(model.connected ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status).font(.callout)
                if !model.deviceSummary.isEmpty {
                    Text(model.deviceSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !model.connected {
                Button("重连") { model.connect() }
                    .disabled(model.connecting)
            }
        }
        .padding(.vertical, 2)
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
