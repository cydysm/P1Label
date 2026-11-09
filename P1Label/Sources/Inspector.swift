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
// Right-hand property inspector (design spec v2 §6.5): document summary when
// nothing is selected, element properties for single selection, align /
// distribute for multi-selection, and the layer list (§5.6). All writes go
// through PrintModel.editText (coalesced into the undo history) or mutate.

import SwiftUI

struct InspectorPanel: View {
    @ObservedObject var model: PrintModel
    /// Canvas scale binding — 「适应窗口」lives in the document summary.
    @Binding var scale: CGFloat
    @State private var layersExpanded = true

    private let labelWidth: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.selectedIDs.count > 1 {
                        multiSection
                    } else if model.selectedElementID != nil {
                        elementSection
                    } else {
                        documentSection
                    }
                    layerSection
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            Spacer(minLength: 0)
            printButton
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background(Design.bgSidebar)
    }

    // MARK: Document summary (no selection)

    @ViewBuilder
    private var documentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文档")
                .font(.designTitle)
                .foregroundStyle(Design.textPrimary)
            summaryRow("纸张", value: paperDescription)
            summaryRow("元素数", value: "\(visibleCount) 个元素")
            HStack(spacing: 8) {
                RowLabel("网格", width: labelWidth)
                Toggle("", isOn: $model.showGrid)
                    .toggleStyle(.switch)
                    .tint(Design.accent)
                    .labelsHidden()
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                RowLabel("缩放", width: labelWidth)
                Button {
                    model.requestFit()
                } label: {
                    Text("适应窗口")
                        .font(.designCaption)
                        .foregroundStyle(Design.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: Design.radiusControl).fill(Design.bgWindow))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(Design.hairline).padding(.vertical, 2)
            // 打印参数（份数/浓度）：与打印按钮同侧（§2.1 动线说明）。
            HStack(spacing: 8) {
                RowLabel("份数", width: labelWidth)
                StepperField(value: Binding(get: { Double(model.copies) },
                                            set: { model.copies = Int($0.rounded()) }),
                             range: 1...50, step: 1, format: { String(format: "%.0f", $0) })
            }
            HStack(spacing: 8) {
                RowLabel("浓度", width: labelWidth)
                Slider(value: Binding(get: { Double(model.darkLevel) },
                                      set: { model.darkLevel = Int($0.rounded()) }),
                       in: 1...16)
                    .tint(Design.accent)
                valueBox("\(model.darkLevel)", width: 40)
            }
        }
    }

    private var paperDescription: String {
        model.doc.isDieCut
            ? "\(model.paperSummary) · 间隙 \(String(format: "%.1f", model.doc.gapLenMM)) mm"
            : model.paperSummary
    }

    private var visibleCount: Int {
        model.doc.elements.filter { !$0.hidden }.count
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack(spacing: 8) {
            RowLabel(label, width: labelWidth)
            Text(value)
                .font(.designBody)
                .foregroundStyle(Design.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: Single element

    @ViewBuilder
    private var elementSection: some View {
        if let id = model.selectedElementID, let el = model.element(id) {
            VStack(alignment: .leading, spacing: 10) {
                Text("元素属性 · \(el.kind.label)")
                    .font(.designTitle)
                    .foregroundStyle(Design.textPrimary)
                switch el.kind {
                case .text: textFields(id, el)
                case .qr: qrFields(id, el)
                case .barcode: barcodeFields(id, el)
                }
                positionRow(id, el)
                alignRow
            }
            // New identity per selected element: otherwise the text fields keep
            // their internal edit state across selection changes and show the
            // previous element's stale content (v1 pitfall, kept).
            .id(id)
        }
    }

    @ViewBuilder
    private func textFields(_ id: UUID, _ el: LabelElement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("内容").font(.designCaption).foregroundStyle(Design.textSecondary)
            TextEditor(text: bindText(id, el))
                .font(.designBody)
                .foregroundStyle(Design.textPrimary)
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: Design.radiusControl)
                    .stroke(Design.hairline, lineWidth: 1))
        }
        HStack(spacing: 8) {
            RowLabel("字号", width: labelWidth)
            Slider(value: bindFontSize(id, el), in: 12...72).tint(Design.accent)
            valueBox("\(Int(el.fontSize))", width: 44)
        }
        HStack(spacing: 8) {
            RowLabel("粗体", width: labelWidth)
            Toggle("", isOn: bindBold(id, el))
                .toggleStyle(.switch)
                .tint(Design.accent)
                .labelsHidden()
                .controlSize(.small)
        }
        HStack(spacing: 8) {
            RowLabel("换行宽", width: labelWidth)
            PickerField(selection: bindWrapWidth(id, el), options: wrapWidthOptions(el))
        }
    }

    @ViewBuilder
    private func qrFields(_ id: UUID, _ el: LabelElement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("内容").font(.designCaption).foregroundStyle(Design.textSecondary)
            TextField("二维码内容", text: bindText(id, el))
                .textFieldStyle(.plain)
                .font(.designBody)
                .foregroundStyle(Design.textPrimary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .fieldFrame()
        }
        HStack(spacing: 8) {
            RowLabel("尺寸", width: labelWidth)
            Slider(value: bindSize(id, el, range: 24...160), in: 24...160).tint(Design.accent)
            valueBox("\(el.size)", width: 44)
        }
        HStack(spacing: 8) {
            RowLabel("纠错", width: labelWidth)
            PickerField(selection: bindErrorCorrection(id, el),
                        options: [("M（默认）", Optional<String>.none),
                                  ("L", "L"), ("M", "M"), ("Q", "Q"), ("H", "H")])
        }
    }

    @ViewBuilder
    private func barcodeFields(_ id: UUID, _ el: LabelElement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("内容").font(.designCaption).foregroundStyle(Design.textSecondary)
            TextField("条码内容(字母/数字)", text: bindText(id, el))
                .textFieldStyle(.plain)
                .font(.designBody)
                .foregroundStyle(Design.textPrimary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .fieldFrame()
        }
        HStack(spacing: 8) {
            RowLabel("高度", width: labelWidth)
            Slider(value: bindSize(id, el, range: 24...160), in: 24...160).tint(Design.accent)
            valueBox("\(el.size)", width: 44)
        }
        // 条码宽度由内容推算，不可手调（§6.5）。
        summaryRow("宽度", value: "自动")
    }

    @ViewBuilder
    private func positionRow(_ id: UUID, _ el: LabelElement) -> some View {
        HStack(spacing: 8) {
            RowLabel("位置", width: labelWidth)
            PositionField(prefix: "X", value: bindPosition(id, el, axis: \.x))
                .frame(width: 72)
            PositionField(prefix: "Y", value: bindPosition(id, el, axis: \.y))
                .frame(width: 72)
        }
    }

    @ViewBuilder
    private var alignRow: some View {
        HStack(spacing: 8) {
            RowLabel("对齐", width: labelWidth)
            alignButtons
        }
    }

    /// 与纸张对齐（单选）/ 选区对齐（多选）六键（§5.4）。
    @ViewBuilder
    private var alignButtons: some View {
        HStack(spacing: 4) {
            miniIconButton("align.horizontal.left", "左对齐") { model.alignSelection(.left) }
            miniIconButton("align.horizontal.center", "水平居中") { model.alignSelection(.hCenter) }
            miniIconButton("align.horizontal.right", "右对齐") { model.alignSelection(.right) }
            miniIconButton("align.vertical.top", "顶对齐") { model.alignSelection(.top) }
            miniIconButton("align.vertical.center", "垂直居中") { model.alignSelection(.vCenter) }
            miniIconButton("align.vertical.bottom", "底对齐") { model.alignSelection(.bottom) }
        }
    }

    private func miniIconButton(_ symbol: String, _ help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Design.textSecondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 4).fill(Design.bgSidebar))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Design.hairline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func valueBox(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.designValue)
            .foregroundStyle(Design.textPrimary)
            .monospacedDigit()
            .frame(width: width, height: 28)
            .fieldFrame()
    }

    // MARK: Multi-selection (≥2)

    @ViewBuilder
    private var multiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已选中 \(model.selectedIDs.count) 个元素")
                .font(.designTitle)
                .foregroundStyle(Design.textPrimary)
            alignRow
            if model.selectedIDs.count >= 3 {
                HStack(spacing: 8) {
                    RowLabel("分布", width: labelWidth)
                    miniIconButton("arrow.left.and.right", "水平等距") {
                        model.distributeSelection(horizontal: true)
                    }
                    miniIconButton("arrow.up.and.down", "垂直等距") {
                        model.distributeSelection(horizontal: false)
                    }
                }
            }
            Button {
                model.deleteSelection()
            } label: {
                Label("删除所选", systemImage: "trash")
                    .font(.designBody)
                    .foregroundStyle(Design.stateError)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: Design.radiusControl).fill(Design.bgSidebar))
                    .overlay(RoundedRectangle(cornerRadius: Design.radiusControl).stroke(Design.hairline, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Layer list (§5.6)

    @ViewBuilder
    private var layerSection: some View {
        Divider().overlay(Design.hairline).padding(.top, 8)
        DisclosureGroup(isExpanded: $layersExpanded) {
            // z 序：顶部在前 = 文档数组倒序。
            ForEach(model.doc.elements.reversed()) { el in
                LayerRow(el: el,
                         selected: model.selectedIDs.contains(el.id),
                         onSelect: {
                             model.commitPendingTextEdit()
                             model.setSelection([el.id], primary: el.id)
                             model.scrollToElementID = el.id
                         },
                         onToggleHidden: { model.setHidden(el.id, !el.hidden) },
                         draggingID: draggingLayerID,
                         onDragStart: { draggingLayerID = el.id },
                         onDrop: { source in
                             model.moveElement(source, to: el.id)
                             draggingLayerID = nil
                         })
            }
        } label: {
            Text("图层")
                .font(.designTitle)
                .foregroundStyle(Design.textPrimary)
        }
        .padding(.top, 6)
    }

    /// Currently dragged layer row (set in onDrag, consumed by performDrop).
    @State private var draggingLayerID: UUID?

    // MARK: Print button (right column bottom, 常驻可见 §2.1)

    private var printButton: some View {
        Button {
            model.print_()
        } label: {
            HStack(spacing: 6) {
                if model.printing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "printer")
                        .font(.system(size: 12, weight: .medium))
                }
                Text(model.printing ? "发送中…" : "打印")
                    .font(.designTitle)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Design.accent))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.connected || model.printing)
        .opacity(model.connected ? 1 : 0.4)
    }

    // MARK: Bindings (routed through editText → coalesced history)

    private func bindText(_ id: UUID, _ el: LabelElement) -> Binding<String> {
        Binding(
            get: { model.element(id)?.text ?? el.text },
            set: { newText in model.editText(id) { $0.text = newText } }
        )
    }

    private func bindFontSize(_ id: UUID, _ el: LabelElement) -> Binding<Double> {
        Binding(
            get: { Double(model.element(id)?.fontSize ?? el.fontSize) },
            set: { newSize in model.editText(id) { $0.fontSize = CGFloat(newSize) } }
        )
    }

    private func bindBold(_ id: UUID, _ el: LabelElement) -> Binding<Bool> {
        Binding(
            get: { model.element(id)?.bold ?? el.bold },
            set: { newBold in model.editText(id) { $0.bold = newBold } }
        )
    }

    private func bindWrapWidth(_ id: UUID, _ el: LabelElement) -> Binding<Int> {
        Binding(
            get: { model.element(id)?.width ?? el.width },
            set: { newWidth in model.editText(id) { $0.width = newWidth } }
        )
    }

    private func wrapWidthOptions(_ el: LabelElement) -> [(label: String, value: Int)] {
        var options: [(label: String, value: Int)] = [("自动", 0)]
        for w in stride(from: 40, through: 304, by: 8) {
            options.append(("\(w)", w))
        }
        let current = el.width
        if current > 0, !options.contains(where: { $0.value == current }) {
            options.append(("\(current)", current))
        }
        return options
    }

    private func bindSize(_ id: UUID, _ el: LabelElement, range: ClosedRange<Int>) -> Binding<Double> {
        Binding(
            get: { Double(model.element(id)?.size ?? el.size) },
            set: { newSize in model.editText(id) { $0.size = Int(newSize.rounded()) } }
        )
    }

    private func bindErrorCorrection(_ id: UUID, _ el: LabelElement) -> Binding<String?> {
        Binding(
            get: { model.element(id)?.errorCorrection ?? el.errorCorrection },
            set: { newLevel in model.editText(id) { $0.errorCorrection = newLevel } }
        )
    }

    private func bindPosition(_ id: UUID, _ el: LabelElement,
                              axis: WritableKeyPath<LabelElement, Int>) -> Binding<Int> {
        Binding(
            get: { model.element(id)?[keyPath: axis] ?? el[keyPath: axis] },
            set: { newPos in model.editText(id) { $0[keyPath: axis] = max(0, newPos) } }
        )
    }
}

// MARK: - Layer row

private struct LayerRow: View {
    let el: LabelElement
    let selected: Bool
    let onSelect: () -> Void
    let onToggleHidden: () -> Void
    /// Layer currently being dragged (set by onDragStart on any row).
    let draggingID: UUID?
    let onDragStart: () -> Void
    let onDrop: (UUID) -> Void

    @State private var isDropTarget = false

    private var summary: String {
        switch el.kind {
        case .text:
            let t = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "未命名" : String(t.prefix(8))
        case .qr: return el.text.isEmpty ? "二维码" : String(el.text.prefix(8))
        case .barcode: return el.text.isEmpty ? "条码" : String(el.text.prefix(8))
        }
    }

    private var kindSymbol: String {
        switch el.kind {
        case .text: return "textformat.alt"
        case .qr: return "qrcode"
        case .barcode: return "barcode"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kindSymbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 14)
            Text("\(el.kind.label) · \(summary)")
                .font(.designBody)
                .foregroundStyle(textColor)
                .lineLimit(1)
            if el.hidden {
                Text("已隐藏")
                    .font(.designCaption)
                    .foregroundStyle(Design.textTertiary)
            }
            Spacer(minLength: 0)
            Button(action: onToggleHidden) {
                Image(systemName: el.hidden ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(el.hidden ? Design.textTertiary : Design.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(el.hidden ? "显示" : "隐藏")
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Design.accentSubtle.opacity(0.6)
                        : selected ? Design.accentSubtle : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onDrag {
            onDragStart()
            return NSItemProvider(object: el.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: LayerDropDelegate(target: el.id,
                                                         draggingID: draggingID,
                                                         active: $isDropTarget,
                                                         onDrop: onDrop))
    }

    private var iconColor: Color {
        selected ? Design.accent : (el.hidden ? Design.textTertiary : Design.textSecondary)
    }

    private var textColor: Color {
        selected ? Design.accent : (el.hidden ? Design.textTertiary : Design.textPrimary)
    }
}

/// Drop delegate for layer reordering: dropping row A on row B moves A to B.
/// The source id is tracked by InspectorPanel (set in onDrag) — reading the
/// async NSItemProvider inside performDrop would need blocking.
private struct LayerDropDelegate: DropDelegate {
    let target: UUID
    let draggingID: UUID?
    @Binding var active: Bool
    let onDrop: (UUID) -> Void

    func dropEntered(info: DropInfo) { active = true }
    func dropExited(info: DropInfo) { active = false }

    func performDrop(info: DropInfo) -> Bool {
        active = false
        guard let source = draggingID else { return false }
        onDrop(source)
        return true
    }

    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }
}
