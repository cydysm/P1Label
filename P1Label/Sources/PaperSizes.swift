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
// Paper size catalog. Each preset bundles the printing defaults that were (or
// still need to be) calibrated on real hardware, so adapting a new paper size
// means adding one entry here and verifying it — no UI or renderer changes.
//
// Calibration notes
// -----------------
// leftPadDots: horizontal head offset applied when rastering (see
// LabelRenderer.rasterRows). 68 was calibrated for 40×30mm die-cut only;
// do NOT assume it generalizes to other widths. Fill in the value measured
// on real paper for each new preset and flip hardwareVerified to true.

import Foundation

struct PaperPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let widthMM: Double
    let heightMM: Double
    let isDieCut: Bool
    let gapLenMM: Double
    /// Per-size horizontal calibration in dots (真机标定).
    let leftPadDots: Int
    /// True only after a real print on this paper matched the preview.
    let hardwareVerified: Bool
}

extension PaperPreset {
    /// Selection value used by the picker when the document has no preset
    /// (edited by hand, or loaded from an archive saved before presets).
    static let customID = "custom"

    /// Catalog: only hardware-verified sizes ship here. To adapt a new paper
    /// size, add an entry, calibrate leftPadDots on real hardware, then flip
    /// hardwareVerified to true.
    static let all: [PaperPreset] = [
        PaperPreset(id: "40x30", name: "40×30 模切",
                    widthMM: 40, heightMM: 30, isDieCut: true, gapLenMM: 3,
                    leftPadDots: 68, hardwareVerified: true),
    ]

    static func byID(_ id: String) -> PaperPreset? {
        all.first { $0.id == id }
    }

    /// Preset whose every calibrated value matches the given document
    /// settings. Used to label archives saved before presets existed —
    /// only an exact match is adopted, anything else stays "自定义".
    static func matching(widthMM: Double, heightMM: Double, isDieCut: Bool,
                         gapLenMM: Double) -> PaperPreset? {
        all.first {
            $0.widthMM == widthMM && $0.heightMM == heightMM
                && $0.isDieCut == isDieCut && $0.gapLenMM == gapLenMM
        }
    }
}
