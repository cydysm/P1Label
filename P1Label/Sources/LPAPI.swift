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
// LPAPI protocol encoder — reverse-engineered from Detong's lpapi-ble-uni SDK
// (used as protocol reference only; see THIRD-PARTY-NOTICES.md at repo root).
// Wire format: [0x1F, cmd, EBV(len), data..., crc]
//   - EBV length: <192 -> 1 byte; >=192 -> (len>>8)|192, len&0xFF
//   - Host->device packages always carry the fixed CRC marker 0x88.
//   - Bitmap rows / repeat rows are NOT CRC-framed: header + raw raster bytes.

enum LPAPI {
    static let start: UInt8 = 0x1F
    static let fixedCRC: UInt8 = 0x88

    // Commands. All known LPAPI commands stay listed here as the protocol
    // reference, including ones the app's validated page flow never sends
    // (e.g. pagePrint: a page simply ends with 0x0C; the SDK's explicit print
    // command is not needed — hardware-verified).
    static let pageStart: UInt8 = 32      // data: pageKey, 2 bytes big-endian
    static let pagePrint: UInt8 = 33
    static let pageWidth: UInt8 = 39      // data: EBV(byteWidth)
    static let bitmapPrint: UInt8 = 43    // header [1F 2B EBV(skip) EBV(len)] + raster bytes
    static let bitmapRepeat: UInt8 = 46   // header [1F 2E EBV(count-1)]
    static let isPrintable: UInt8 = 112
    static let printerDPICmd: UInt8 = 113
    static let printerWidthCmd: UInt8 = 114
    static let bufferSize: UInt8 = 119
    static let deviceNameCmd: UInt8 = 121
    static let softwareVersionCmd: UInt8 = 124
    static let manufacturer: UInt8 = 117
    static let gapTypeCmd: UInt8 = 66     // data: 0 = continuous, 2 = die-cut gap
    static let darknessCmd: UInt8 = 67    // data: darkness 0..15
    static let gapLenCmd: UInt8 = 69      // data: EBV(gap length in 0.01mm)

    static func ebv(_ value: Int) -> [UInt8] {
        value >= 192 ? [UInt8((value >> 8) | 192), UInt8(value & 0xFF)] : [UInt8(value)]
    }

    /// Framed command package (fixed CRC marker, like the official SDK).
    static func frame(_ cmd: UInt8, _ data: [UInt8] = []) -> [UInt8] {
        [start, cmd] + ebv(data.count) + data + [fixedCRC]
    }

    /// One raster line, skip = leading blank bytes.
    static func bitmapRow(skip: Int, bytes: ArraySlice<UInt8>) -> [UInt8] {
        [start, bitmapPrint] + ebv(skip) + ebv(bytes.count) + bytes
    }

    static func bitmapRepeat(count: Int) -> [UInt8] {
        count > 0 ? [start, bitmapRepeat] + ebv(count - 1) : []
    }

    /// ESC J n — feed n blank lines (raw, not framed).
    static func blankLines(_ n: Int) -> [UInt8] {
        var out: [UInt8] = []
        var rest = n
        while rest >= 255 { out += [27, 74, 255]; rest -= 255 }
        if rest > 0 { out += [27, 74, UInt8(rest)] }
        return out
    }

    /// Encode raster rows into row buffers (bitmap print + repeat + ESC J blanks).
    /// Identical to the encoder validated against real hardware.
    static func encodeRows(_ rows: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < rows.count {
            let row = rows[i]
            var nz = row.count
            while nz > 0 && row[nz - 1] == 0 { nz -= 1 }

            if nz == 0 {
                var n = 0
                while i < rows.count && rows[i].allSatisfy({ $0 == 0 }) { n += 1; i += 1 }
                out += blankLines(n)
                continue
            }
            var repeatCount = 1
            while i + repeatCount < rows.count && rows[i + repeatCount] == row { repeatCount += 1 }
            out += bitmapRow(skip: 0, bytes: row[..<nz])
            if repeatCount > 1 { out += bitmapRepeat(count: repeatCount - 1) }
            i += repeatCount
        }
        return out
    }

    /// Parse device->host packages from a stream. Returns parsed (cmd, data) pairs and leftover bytes.
    static func parsePackages(_ buffer: [UInt8]) -> (packages: [(cmd: UInt8, data: [UInt8])], leftover: [UInt8]) {
        var out: [(UInt8, [UInt8])] = []
        var i = 0
        while true {
            while i < buffer.count && buffer[i] != start { i += 1 }
            guard i < buffer.count else { break }
            let rest = Array(buffer[i...])
            if rest.count < 4 { break }
            let length: Int
            let headerLen: Int
            if rest[2] >= 192 {
                length = (Int(rest[2] & 0x3F) << 8) | Int(rest[3])
                headerLen = 4
            } else {
                length = Int(rest[2])
                headerLen = 3
            }
            if rest.count < headerLen + length + 1 { break }
            out.append((rest[1], Array(rest[headerLen..<(headerLen + length)])))
            i += headerLen + length + 1
        }
        return (out, Array(buffer[min(i, buffer.count)...]))
    }
}
