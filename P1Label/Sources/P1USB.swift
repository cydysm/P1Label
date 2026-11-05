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
// USB transport for the P1 label printer (libusb).
// Interface 0 is a standard USB printer class device: bulk OUT 0x01, bulk IN 0x81.

import Foundation
import libusb

// Common surface of the USB and Bluetooth transports. Both present a
// synchronous blocking API; PrintModel drives them from detached tasks.
protocol P1Transport: AnyObject {
    var isOpen: Bool { get }
    var dpi: Int { get }
    var printerWidth: Int { get }
    var deviceName: String { get }
    var softwareVersion: String { get }
    var lastError: String? { get }
    func open() throws
    func close()
    func write(_ bytes: [UInt8], timeoutMS: Int) throws
    func sendPage(_ payload: [UInt8], progress: ((Double) -> Void)?) throws
    func query(_ cmd: UInt8, timeoutSeconds: Double) -> [UInt8]?
}

enum USBError: Error, CustomStringConvertible {
    case deviceNotFound
    case libusbError(String)
    case noResponse

    var description: String {
        switch self {
        case .deviceNotFound: return "未找到打印机 (VID 0x3533 / PID 0x5A11)"
        case .libusbError(let m): return "USB 错误: \(m)"
        case .noResponse: return "打印机无响应"
        }
    }
}

final class P1USB: P1Transport {
    static let vendorID: UInt16 = 0x3533
    static let productID: UInt16 = 0x5A11
    static let bulkOut: UInt8 = 0x01
    static let bulkIn: UInt8 = 0x81

    private var ctx: OpaquePointer?
    private var handle: OpaquePointer?
    private var claimed = false
    private(set) var isOpen = false
    private var rxBuffer: [UInt8] = []
    private(set) var lastError: String?

    // Printer facts queried at open
    private(set) var dpi: Int = 203
    private(set) var printerWidth: Int = 384
    private(set) var deviceName: String = ""
    private(set) var softwareVersion: String = ""

    deinit { close() }

    func open() throws {
        guard handle == nil else { return }
        var ctx: OpaquePointer?
        guard libusb_init(&ctx) == 0 else { throw USBError.libusbError("init failed") }
        self.ctx = ctx

        guard let h = libusb_open_device_with_vid_pid(ctx, Self.vendorID, Self.productID) else {
            close()
            throw USBError.deviceNotFound
        }
        handle = h
        libusb_set_auto_detach_kernel_driver(h, 1)

        if libusb_claim_interface(h, 0) != 0 {
            libusb_reset_device(h)
            guard libusb_claim_interface(h, 0) == 0 else {
                close()
                throw USBError.libusbError("无法占用打印机接口 (可能被其他程序使用)")
            }
        }
        claimed = true

        if let name = query(LPAPI.deviceNameCmd) {
            deviceName = String(bytes: name.dropLast(1), encoding: .utf8) ?? ""
        }
        if let ver = query(LPAPI.softwareVersionCmd) {
            softwareVersion = String(bytes: ver.dropLast(1), encoding: .utf8) ?? ""
        }
        if let d = query(LPAPI.printerDPICmd), let v = d.first {
            dpi = Int(v)
        }
        if let w = query(LPAPI.printerWidthCmd), w.count >= 2 {
            // 01 80 -> 0x0180 = 384 dots big-endian
            printerWidth = Int(w[0]) << 8 | Int(w[1])
        }
        isOpen = true
    }

    func close() {
        if let h = handle {
            if claimed { libusb_release_interface(h, 0) }
            libusb_close(h)
        }
        handle = nil
        claimed = false
        isOpen = false
        if let c = ctx { libusb_exit(c) }
        ctx = nil
    }

    // MARK: - Raw IO

    func write(_ bytes: [UInt8], timeoutMS: Int = 2000) throws {
        guard let h = handle else { throw USBError.libusbError("未打开") }
        var sent: Int32 = 0
        var offset = 0
        let arr = Array(bytes)
        while offset < arr.count {
            let chunkSize = min(4096, arr.count - offset)
            let chunk = Array(arr[offset..<offset+chunkSize])
            let r = chunk.withUnsafeBufferPointer { buf in
                libusb_bulk_transfer(h, Self.bulkOut, UnsafeMutablePointer(mutating: buf.baseAddress), Int32(chunkSize), &sent, UInt32(timeoutMS))
            }
            guard r == 0, sent > 0 else {
                throw USBError.libusbError("bulk write failed: \(libusb_error_name(r).map { String(cString: $0) } ?? "unknown")")
            }
            offset += Int(sent)
        }
    }

    private func readInto(timeoutMS: Int32) -> Int {
        guard let h = handle else { return 0 }
        var buf = [UInt8](repeating: 0, count: 64)
        var received: Int32 = 0
        let r = buf.withUnsafeMutableBufferPointer { ptr in
            libusb_bulk_transfer(h, Self.bulkIn, ptr.baseAddress, 64, &received, UInt32(timeoutMS))
        }
        if r == 0 && received > 0 {
            rxBuffer += buf[0..<Int(received)]
            return Int(received)
        }
        return 0
    }

    /// Query one command, waiting for its framed response.
    func query(_ cmd: UInt8, timeoutSeconds: Double = 1.5) -> [UInt8]? {
        guard let _ = handle else { return nil }
        rxBuffer.removeAll()
        do { try write(LPAPI.frame(cmd)) } catch { lastError = "\(error)"; return nil }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let (pkgs, leftover) = LPAPI.parsePackages(rxBuffer)
            rxBuffer = leftover
            if let hit = pkgs.first(where: { $0.cmd == cmd }) {
                return hit.data
            }
            _ = readInto(timeoutMS: 100)
        }
        return nil
    }

    /// Send a full page payload in small chunks.
    ///
    /// The printer accepts ~10 KB at once and stops answering status queries
    /// while a page is being streamed, so we pace blindly (validated against hardware)
    /// and only poll the buffer between larger payloads.
    func sendPage(_ payload: [UInt8], progress: ((Double) -> Void)? = nil) throws {
        let chunkSize = 512
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            try writeReliable(Array(payload[offset..<end]))
            offset = end
            progress?(Double(offset) / Double(payload.count))
            usleep(15_000)
        }
    }

    /// Write with a single retry — a transient bulk timeout must not truncate a page
    /// (an unterminated page wedges the printer until power-cycle).
    private func writeReliable(_ bytes: [UInt8]) throws {
        do {
            try write(bytes)
        } catch {
            usleep(200_000)
            try write(bytes)
        }
    }
}
