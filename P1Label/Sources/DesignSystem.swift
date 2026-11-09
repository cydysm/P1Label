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
// Design tokens v2 (docs/design-spec-v2.md §3.2) and the small set of shared
// controls that survive the v1 → v2 migration. The v1 `Design` enum lived in
// MainWindow.swift; tokens are now app-wide so the canvas layers can use the
// same palette without importing UI concepts. Discipline: no new bare
// Color(red:green:blue:) outside this file.

import SwiftUI

// MARK: - Design tokens v2

enum Design {
    // Color
    static let accent = Color(hex: 0x4C6FFF)
    static let accentSubtle = Color(hex: 0xEEF1FF)
    static let bgWindow = Color(hex: 0xF2F2F4)
    static let bgSidebar = Color.white
    static let bgCanvas = Color(hex: 0xE4E5E9)
    static let canvasGrid = Color.black.opacity(0.04)
    static let textPrimary = Color(hex: 0x1C1C1E)
    static let textSecondary = Color(hex: 0x6C6C70)
    static let textTertiary = Color(hex: 0x9A9AA0)
    static let hairline = Color.black.opacity(0.08)
    static let stateOK = Color(hex: 0x34C759)
    static let stateWarn = Color(hex: 0xFF9F0A)
    static let stateError = Color(hex: 0xFF3B30)
    static let guideSnap = Color(hex: 0xFF2D92)

    // Shape
    static let radiusControl: CGFloat = 6
    static let radiusPanel: CGFloat = 10
    static let radiusPaper: CGFloat = 2

    // Shadow — only these two tiers; everything else is a hairline stroke.
    static let shadowCard = Color.black.opacity(0.06)
    static let shadowPaper = Color.black.opacity(0.18)
}

/// Hex-only color initializer so token values stay readable (#RRGGBB).
private extension Color {
    init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / CGFloat(255),
                  green: CGFloat((hex >> 8) & 0xFF) / CGFloat(255),
                  blue: CGFloat(hex & 0xFF) / CGFloat(255))
    }
}

// MARK: - Typography helpers (system font, PingFang SC fallback)

extension Font {
    /// 面板标题、按钮主文案 (13 semibold).
    static let designTitle = Font.system(size: 13, weight: .semibold)
    /// 正文、控件标签 (12 regular).
    static let designBody = Font.system(size: 12)
    /// 辅助说明、状态条 (11 regular).
    static let designCaption = Font.system(size: 11)
    /// 控件值 (12 medium).
    static let designValue = Font.system(size: 12, weight: .medium)
}

// MARK: - Field chrome

extension View {
    /// White bordered field chrome (h28, radius.control, hairline stroke).
    func fieldFrame(height: CGFloat = 28, radius: CGFloat = Design.radiusControl) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius).fill(Design.bgSidebar))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Design.hairline, lineWidth: 1))
    }
}

/// Row label inside the inspector / popovers (11, text.secondary).
struct RowLabel: View {
    let text: String
    var width: CGFloat
    var color: Color = Design.textSecondary

    init(_ text: String, width: CGFloat, color: Color = Design.textSecondary) {
        self.text = text
        self.width = width
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.designCaption)
            .foregroundStyle(color)
            .frame(width: width, alignment: .leading)
    }
}

// MARK: - StepperField
//
// Carried over from v1 (design-verified): value text + stacked chevrons inside
// a bordered field. The spec's alternative (native Stepper + TextField) renders
// the +/- buttons outside the field and does not match the mockups.

struct StepperField: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String
    /// Highlight the value in the warn color (unverified-paper calibration hint).
    var warnValue = false

    var body: some View {
        HStack(spacing: 0) {
            Text(format(value))
                .font(.designValue)
                .foregroundStyle(warnValue ? Design.stateWarn : Design.textPrimary)
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
        .frame(height: 28)
        .fieldFrame()
    }

    private func chevron(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(Design.textSecondary)
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bump(_ direction: Double) {
        let v = value + direction * step
        value = min(max(v, range.lowerBound), range.upperBound)
    }
}

// MARK: - PickerField
//
// Dropdown styled like the design's value fields with a trailing chevron.
// The chevron is an overlay (hit-test disabled): .borderlessButton menus
// center their own label and swallow in-label decorations. Carried from v1,
// restyled to h28 / 12 medium.

struct PickerField<T: Hashable>: View {
    @Binding var selection: T
    let options: [(label: String, value: T)]
    /// Highlight the value in the warn color (unverified-paper calibration hint).
    var warnValue = false

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { opt in
                Button(opt.label) { selection = opt.value }
            }
        } label: {
            HStack(spacing: 4) {
                Text(options.first(where: { $0.value == selection })?.label ?? "—")
                    .font(.designValue)
                    .foregroundStyle(warnValue ? Design.stateWarn : Design.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(height: 28)   // borderless menus otherwise render ~30
        .frame(maxWidth: .infinity)
        .fieldFrame()
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Design.textTertiary)
                .padding(.trailing, 8)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - PositionField
//
// Editable x/y numeric field. String-backed (not TextField(value:format:))
// because a failed parse there leaves the field showing the stale typed text
// (e.g. empty) with no way back to the real value until it changes. Carried
// from v1 (spec §4 keeps it verbatim), restyled h28 with the X/Y prefix.

struct PositionField: View {
    var prefix: String
    @Binding var value: Int
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            Text(prefix)
                .font(.designCaption)
                .foregroundStyle(Design.textTertiary)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.designValue)
                .foregroundColor(Design.textPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .fieldFrame()
        .onAppear { text = "\(value)" }
        .onChange(of: value) { text = "\($0)" }
        .onChange(of: text) { new in
            if let v = Int(new), v >= 0, v != value { value = v }
        }
        .onSubmit { text = "\(value)" }
    }
}

// MARK: - Buttons

/// Small white pill button (扫描 / 重连 / 连接): white bg, hairline stroke,
/// 11 medium accent label.
struct PillButton: View {
    let title: String
    var action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Design.accent)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: Design.radiusControl).fill(Design.bgSidebar))
                .overlay(RoundedRectangle(cornerRadius: Design.radiusControl).stroke(Design.hairline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 36×36 toolbar icon button; hover paints a bg.window rounded square.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var disabled = false
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(disabled ? Design.textTertiary : Design.textSecondary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: Design.radiusControl)
                        .fill(hovered && !disabled ? Design.bgWindow : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .help(help)
    }
}

// MARK: - Zoom stepper ("− / 100% / ＋")
//
// One rounded container segmented by hairlines; the percentage segment opens
// 50% / 200% / 适应窗口 in its context menu (spec §5.7).

struct ZoomStepper: View {
    @Binding var scale: CGFloat
    var onFit: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            zoomButton("minus") { zoom(by: 1 / 1.25) }
            Divider().frame(height: 18).overlay(Design.hairline)
            Menu {
                Button("50%") { scale = 0.5 }
                Button("200%") { scale = 2.0 }
                Button("适应窗口") { onFit() }
            } label: {
                Text("\(Int((scale * 100).rounded()))%")
                    .font(.designCaption)
                    .foregroundStyle(Design.textPrimary)
                    .monospacedDigit()
                    .frame(width: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(height: 28)
            Divider().frame(height: 18).overlay(Design.hairline)
            zoomButton("plus") { zoom(by: 1.25) }
        }
        .background(RoundedRectangle(cornerRadius: Design.radiusControl).fill(Design.bgSidebar))
        .overlay(RoundedRectangle(cornerRadius: Design.radiusControl).stroke(Design.hairline, lineWidth: 1))
        .fixedSize()
    }

    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Design.textSecondary)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func zoom(by factor: Double) {
        scale = CGFloat(max(0.5, min(6, Double(scale) * factor)))
    }
}
