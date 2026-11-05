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
// Bluetooth LE transport for the P1 label printer (CoreBluetooth).
//
// The LPAPI byte stream is identical to the USB path — LPAPI.swift was
// reverse-engineered from Detong's lpapi-ble-uni *BLE* SDK — only the pipe
// differs: GATT service FF00 (write FF02 / notify FF01), classic fallback
// FFE0 (FFE2 / FFE1), per DothanTech's reference BLE implementations.
// When the known UUIDs are absent we fall back to picking characteristics
// by property (write / notify) from non-system services.
//
// Write strategy: chunked .withResponse writes, waiting for each ACK, paced
// to the USB-validated envelope (512 bytes / 15 ms — see sendPage). The
// tunables are grouped below; adjust them against hardware if a page prints
// garbled or stalls.

import Foundation
@preconcurrency import CoreBluetooth

enum BLEError: Error, CustomStringConvertible {
    case bluetoothOff
    case notFound
    case ambiguous([P1BLE.DeviceInfo])
    case connectFailed(String)
    case characteristicNotFound
    case noResponse

    var description: String {
        switch self {
        case .bluetoothOff:
            return "蓝牙未开启"
        case .notFound:
            return "未发现蓝牙打印机（请确认打印机已开机、未被手机 App 占用）"
        case .ambiguous:
            return "发现多台蓝牙打印机，请手动选择"
        case .connectFailed(let m):
            return "蓝牙连接失败: \(m)"
        case .characteristicNotFound:
            return "打印机缺少所需的蓝牙特征（写/通知）"
        case .noResponse:
            return "打印机无响应"
        }
    }
}

final class P1BLE: NSObject, P1Transport {
    // MARK: Tunables (USB-validated envelope; retune against hardware here)
    static let pageChunkBytes = 512          // bytes per pacing window, same as P1USB.sendPage
    static let pageChunkDelayMS = 15         // sleep per pacing window, same as P1USB.sendPage
    static let maxWriteLen = 512             // GATT write cap, matches the reference SDK
    static let writeAckTimeoutMS = 2000      // per-chunk ack wait (withResponse)
    static let stateTimeoutSeconds = 5.0     // waiting for bluetooth poweredOn
    static let scanTimeoutSeconds = 4.0      // one discovery window
    static let connectTimeoutSeconds = 10.0  // overall connect + GATT discovery

    // DothanTech reference GATT UUIDs.
    static let serviceUUIDs: [CBUUID] = [CBUUID(string: "FF00"), CBUUID(string: "FFE0"), CBUUID(string: "18F0")]
    private static let serviceUUIDSet = Set(serviceUUIDs)
    private static let writeUUIDs: Set<CBUUID> = [CBUUID(string: "FF02"), CBUUID(string: "FFE2")]
    private static let notifyUUIDs: Set<CBUUID> = [CBUUID(string: "FF01"), CBUUID(string: "FFE1")]
    private static let systemServiceUUIDs: Set<CBUUID> = [
        CBUUID(string: "1800"), CBUUID(string: "1801"), CBUUID(string: "180A"), CBUUID(string: "180F")
    ]

    struct DeviceInfo: Identifiable {
        let identifier: UUID
        let name: String
        let rssi: Int
        let matchesPrinter: Bool   // advertises one of the candidate printer services
        var id: UUID { identifier }
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse
    private let queue = DispatchQueue(label: "P1BLE.transport")
    private let rxLock = NSLock()
    private var rxBuffer: [UInt8] = []
    private var writeAckSem: DispatchSemaphore?

    private(set) var isOpen = false
    private(set) var lastError: String?
    private(set) var dpi: Int = 203
    private(set) var printerWidth: Int = 384
    private(set) var deviceName: String = ""
    private(set) var softwareVersion: String = ""

    /// Called from the CoreBluetooth queue when the connection drops unexpectedly.
    var onDisconnect: (() -> Void)?

    // Scan/connect bookkeeping — all delegate callbacks arrive on `queue`.
    private var seen: [UUID: (info: DeviceInfo, ref: CBPeripheral)] = [:]
    private var connectTarget: UUID?
    private var pickerRequireName = false
    private var didFullDiscovery = false
    private var pendingServiceCount = 0

    // Continuations (each resumed exactly once, always on `queue`).
    private var stateCont: CheckedContinuation<Void, Error>?
    private var scanCont: CheckedContinuation<CBPeripheral, Error>?
    private var pickCont: CheckedContinuation<[DeviceInfo], Never>?
    private var readyCont: CheckedContinuation<Void, Error>?

    private final class ResultBox {
        var result: Result<Void, Error>?
    }

    override init() {
        super.init()
    }

    deinit { close() }

    // MARK: - Open / close

    func open() throws {
        try open(target: nil)
    }

    /// Connect to a printer. `target` = previously selected peripheral (auto
    /// reconnect); nil = scan and auto-pick when exactly one candidate matches.
    func open(target: UUID?) throws {
        if isOpen { return }
        if peripheral != nil || central != nil { close() }
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task { [weak self] in
            guard let self else {
                box.result = .failure(BLEError.connectFailed("传输已释放"))
                sem.signal()
                return
            }
            do {
                try await self.connectPipeline(target: target)
                box.result = .success(())
            } catch {
                box.result = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        switch box.result! {
        case .success: break
        case .failure(let e): throw e
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardown()
        }
    }

    private func teardown() {
        isOpen = false
        writeChar = nil
        notifyChar = nil
        writeAckSem = nil
        connectTarget = nil
        if let p = peripheral {
            p.delegate = nil
            if p.state != .disconnected {
                central?.cancelPeripheralConnection(p)
            }
        }
        peripheral = nil
        central?.stopScan()
        seen = [:]
        if let c = readyCont { readyCont = nil; c.resume(throwing: BLEError.connectFailed("已断开")) }
        if let c = scanCont { scanCont = nil; c.resume(throwing: BLEError.connectFailed("已断开")) }
        if let c = pickCont { pickCont = nil; c.resume(returning: []) }
        if let c = stateCont { stateCont = nil; c.resume(throwing: BLEError.bluetoothOff) }
    }

    private func connectPipeline(target: UUID?) async throws {
        let central = try await ensurePoweredOn()
        let p = try await obtainPeripheral(central: central, target: target)
        try await bringReady(p)
        // CCCD write needs a beat before the first notify can arrive.
        try? await Task.sleep(nanoseconds: 200_000_000)
        // Same fact queries, same order as P1USB.open().
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

    // MARK: - Discovery

    private func ensurePoweredOn() async throws -> CBCentralManager {
        if let c = central {
            switch c.state {
            case .poweredOn:
                return c
            case .unknown:
                try await waitForPoweredOn(c)
                guard c.state == .poweredOn else { throw BLEError.bluetoothOff }
                return c
            default:
                throw BLEError.bluetoothOff
            }
        }
        let c = CBCentralManager(delegate: self, queue: queue)
        central = c
        if c.state == .unknown {
            try await waitForPoweredOn(c)
        }
        guard c.state == .poweredOn else { throw BLEError.bluetoothOff }
        return c
    }

    private func waitForPoweredOn(_ c: CBCentralManager) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: BLEError.connectFailed("传输已释放")); return }
                if c.state == .poweredOn {
                    cont.resume()
                    return
                }
                self.stateCont = cont
                self.queue.asyncAfter(deadline: .now() + Self.stateTimeoutSeconds) { [weak self] in
                    guard let self, let pending = self.stateCont else { return }
                    self.stateCont = nil
                    if c.state == .poweredOn {
                        pending.resume()
                    } else {
                        pending.resume(throwing: BLEError.bluetoothOff)
                    }
                }
            }
        }
    }

    private func obtainPeripheral(central: CBCentralManager, target: UUID?) async throws -> CBPeripheral {
        // Fast path: the system remembers previously seen peripherals even when
        // they are not advertising right now.
        if let target, let cached = central.retrievePeripherals(withIdentifiers: [target]).first {
            return cached
        }
        return try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: BLEError.connectFailed("传输已释放")); return }
                self.scanCont = cont
                self.connectTarget = target
                self.seen = [:]
                central.stopScan()
                central.scanForPeripherals(withServices: Self.serviceUUIDs)
                self.queue.asyncAfter(deadline: .now() + Self.scanTimeoutSeconds) { [weak self] in
                    self?.scanWatchdogFired()
                }
            }
        }
    }

    /// Scan window elapsed: pick the target, a single candidate, or fail.
    private func scanWatchdogFired() {
        guard scanCont != nil else { return }
        let matches = seen.values.filter { $0.info.matchesPrinter }
            .sorted { $0.info.rssi > $1.info.rssi }
        if let target = connectTarget, let hit = seen[target] {
            finishScan(.success(hit.ref))
        } else if connectTarget == nil, matches.count == 1 {
            finishScan(.success(matches[0].ref))
        } else if connectTarget == nil, matches.count > 1 {
            finishScan(.failure(BLEError.ambiguous(matches.map { $0.info })))
        } else {
            finishScan(.failure(BLEError.notFound))
        }
    }

    private func finishScan(_ result: Result<CBPeripheral, Error>) {
        guard let cont = scanCont else { return }
        scanCont = nil
        connectTarget = nil
        central?.stopScan()
        cont.resume(with: result)
    }

    /// Blocking scan for the device picker. Falls back to an unfiltered sweep
    /// when no device advertises the candidate printer services.
    func scanDevices(timeoutSeconds: Double = P1BLE.scanTimeoutSeconds) -> [DeviceInfo] {
        let sem = DispatchSemaphore(value: 0)
        let box = DeviceListBox()
        Task { [weak self] in
            guard let self else { sem.signal(); return }
            box.devices = await self.runScan(timeoutSeconds: timeoutSeconds)
            sem.signal()
        }
        sem.wait()
        return box.devices
    }

    private final class DeviceListBox {
        var devices: [DeviceInfo] = []
    }

    private func runScan(timeoutSeconds: Double) async -> [DeviceInfo] {
        guard let central = try? await ensurePoweredOn() else { return [] }
        var results = await scanWindow(central: central, services: Self.serviceUUIDs,
                                       seconds: timeoutSeconds, requireName: false)
        if results.isEmpty {
            // The printer may not advertise the expected services — sweep for
            // any named device so the user can still pick it manually.
            results = await scanWindow(central: central, services: nil,
                                       seconds: timeoutSeconds, requireName: true)
        }
        return results
    }

    private func scanWindow(central: CBCentralManager, services: [CBUUID]?, seconds: Double,
                            requireName: Bool) async -> [DeviceInfo] {
        await withCheckedContinuation { (cont: CheckedContinuation<[DeviceInfo], Never>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(returning: []); return }
                self.pickCont = cont
                self.seen = [:]
                self.pickerRequireName = requireName
                central.stopScan()
                central.scanForPeripherals(withServices: services)
                self.queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.finishPickerScan()
                }
            }
        }
    }

    private func finishPickerScan() {
        guard let cont = pickCont else { return }
        pickCont = nil
        central?.stopScan()
        var items = seen.values.map { $0.info }
        if pickerRequireName {
            items = items.filter { !$0.name.isEmpty }
        }
        // Printer candidates first, then strongest signal.
        let sorted = items.sorted {
            if $0.matchesPrinter != $1.matchesPrinter { return $0.matchesPrinter }
            return $0.rssi > $1.rssi
        }
        cont.resume(returning: Array(sorted.prefix(20)))
    }

    // MARK: - GATT setup

    private func bringReady(_ p: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: BLEError.connectFailed("传输已释放")); return }
                self.readyCont = cont
                self.peripheral = p
                self.rxLock.lock()
                self.rxBuffer.removeAll()
                self.rxLock.unlock()
                p.delegate = self
                self.central?.connect(p)
                self.queue.asyncAfter(deadline: .now() + Self.connectTimeoutSeconds) { [weak self] in
                    guard let self, self.readyCont != nil else { return }
                    self.resumeReady(.failure(BLEError.connectFailed("连接超时")))
                    if let stuck = self.peripheral, stuck.state != .disconnected {
                        self.central?.cancelPeripheralConnection(stuck)
                    }
                }
            }
        }
    }

    private func resumeReady(_ result: Result<Void, Error>) {
        guard let cont = readyCont else { return }
        readyCont = nil
        cont.resume(with: result)
    }

    /// Pick write + notify characteristics: known UUIDs first, then by
    /// property over non-system services.
    private func resolveCharacteristics() -> (write: CBCharacteristic, notify: CBCharacteristic)? {
        var write: CBCharacteristic?
        var notify: CBCharacteristic?
        for s in peripheral?.services ?? [] {
            for c in s.characteristics ?? [] {
                if write == nil, Self.writeUUIDs.contains(c.uuid) { write = c }
                if notify == nil, Self.notifyUUIDs.contains(c.uuid) { notify = c }
            }
        }
        let fallbackServices = (peripheral?.services ?? []).filter { !Self.systemServiceUUIDs.contains($0.uuid) }
        if write == nil {
            write = fallbackServices.flatMap { $0.characteristics ?? [] }.first {
                $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
            }
        }
        if notify == nil {
            notify = fallbackServices.flatMap { $0.characteristics ?? [] }.first {
                $0.properties.contains(.notify) || $0.properties.contains(.indicate)
            }
        }
        if let w = write, let n = notify { return (w, n) }
        return nil
    }

    // MARK: - Raw IO

    func write(_ bytes: [UInt8], timeoutMS: Int = 2000) throws {
        // No isOpen check: write() also serves the fact queries inside open(),
        // before isOpen is set (same as P1USB).
        guard let p = peripheral, writeChar != nil else {
            throw BLEError.connectFailed("未连接")
        }
        let mtu = p.maximumWriteValueLength(for: writeType)
        let cap = max(20, min(Self.maxWriteLen, mtu))
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + cap, bytes.count)
            try writeChunkWithRetry(Array(bytes[offset..<end]), timeoutMS: timeoutMS)
            offset = end
        }
    }

    /// Write with a single retry — a transient failure must not truncate a page
    /// (an unterminated page wedges the printer until power-cycle). Same
    /// semantics as P1USB.writeReliable.
    private func writeChunkWithRetry(_ chunk: [UInt8], timeoutMS: Int) throws {
        do {
            try writeChunk(chunk, timeoutMS: timeoutMS)
        } catch {
            usleep(200_000)
            try writeChunk(chunk, timeoutMS: timeoutMS)
        }
    }

    private func writeChunk(_ chunk: [UInt8], timeoutMS: Int) throws {
        // No isOpen check: writeChunk also serves the fact queries inside open().
        guard let p = peripheral, let wc = writeChar else {
            throw BLEError.connectFailed("未连接")
        }
        guard writeType == .withResponse else {
            // No ack available; the pacing in sendPage is the flow control.
            p.writeValue(Data(chunk), for: wc, type: .withoutResponse)
            return
        }
        let sem = DispatchSemaphore(value: 0)
        queue.sync { writeAckSem = sem }
        p.writeValue(Data(chunk), for: wc, type: .withResponse)
        let outcome = sem.wait(timeout: .now() + .milliseconds(timeoutMS))
        queue.sync { if writeAckSem === sem { writeAckSem = nil } }
        if outcome == .timedOut {
            throw BLEError.noResponse
        }
    }

    /// Send a full page payload, preserving the USB-validated pacing envelope:
    /// pageChunkBytes per pageChunkDelayMS regardless of the negotiated MTU
    /// (smaller GATT writes are batched inside each window).
    func sendPage(_ payload: [UInt8], progress: ((Double) -> Void)? = nil) throws {
        guard isOpen else { throw BLEError.connectFailed("未连接") }
        let mtu = max(20, min(Self.maxWriteLen, peripheral?.maximumWriteValueLength(for: writeType) ?? 20))
        let writesPerWindow = max(1, Int((Double(Self.pageChunkBytes) / Double(mtu)).rounded(.up)))
        var sent = 0
        while sent < payload.count {
            var writes = 0
            while writes < writesPerWindow && sent < payload.count {
                let end = min(sent + mtu, payload.count)
                try writeChunkWithRetry(Array(payload[sent..<end]), timeoutMS: Self.writeAckTimeoutMS)
                sent = end
                writes += 1
                progress?(Double(sent) / Double(payload.count))
            }
            usleep(useconds_t(Self.pageChunkDelayMS) * 1000)
        }
    }

    // MARK: - Query

    private func pushRx(_ data: Data) {
        rxLock.lock()
        rxBuffer.append(contentsOf: data)
        rxLock.unlock()
    }

    private func drainParsed(matching cmd: UInt8) -> [UInt8]? {
        rxLock.lock()
        defer { rxLock.unlock() }
        let (pkgs, leftover) = LPAPI.parsePackages(rxBuffer)
        rxBuffer = leftover
        return pkgs.first(where: { $0.cmd == cmd })?.data
    }

    /// Query one command, waiting for its framed response over notifications.
    func query(_ cmd: UInt8, timeoutSeconds: Double = 1.5) -> [UInt8]? {
        guard peripheral != nil, writeChar != nil else { return nil }
        rxLock.lock()
        rxBuffer.removeAll()
        rxLock.unlock()
        do { try write(LPAPI.frame(cmd)) } catch { lastError = "\(error)"; return nil }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let hit = drainParsed(matching: cmd) { return hit }
            usleep(50_000)
        }
        return nil
    }
}

// MARK: - CBCentralManagerDelegate

extension P1BLE: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Already on `queue`.
        guard central.state != .unknown, let cont = stateCont else { return }
        stateCont = nil
        if central.state == .poweredOn {
            cont.resume()
        } else {
            cont.resume(throwing: BLEError.bluetoothOff)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Already on `queue`.
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let advServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let matches = !Set(advServices).isDisjoint(with: Self.serviceUUIDSet)
        seen[peripheral.identifier] = (
            DeviceInfo(identifier: peripheral.identifier, name: name,
                       rssi: RSSI.intValue, matchesPrinter: matches),
            peripheral
        )
        // Found the explicitly wanted device — skip the rest of the scan window.
        if scanCont != nil, let target = connectTarget, peripheral.identifier == target {
            finishScan(.success(peripheral))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Already on `queue`.
        guard peripheral === self.peripheral else { return }
        didFullDiscovery = false
        peripheral.discoverServices(Self.serviceUUIDs)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        // Already on `queue`.
        resumeReady(.failure(BLEError.connectFailed(error?.localizedDescription ?? "连接失败")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // Already on `queue`.
        guard peripheral === self.peripheral else { return }
        let wasReady = readyCont == nil
        teardown()
        if wasReady {
            let cb = onDisconnect
            if let cb { cb() }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension P1BLE: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Already on `queue`.
        if let error {
            resumeReady(.failure(BLEError.connectFailed("服务发现失败: \(error.localizedDescription)")))
            return
        }
        let services = peripheral.services ?? []
        if services.isEmpty && !didFullDiscovery {
            // The advertised services may not match our candidate list.
            didFullDiscovery = true
            peripheral.discoverServices(nil)
            return
        }
        if services.isEmpty {
            resumeReady(.failure(BLEError.characteristicNotFound))
            return
        }
        pendingServiceCount = services.count
        for s in services {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        // Already on `queue`. One callback per service whose characteristics
        // were just discovered.
        if let error {
            resumeReady(.failure(BLEError.connectFailed("特征发现失败: \(error.localizedDescription)")))
            return
        }
        pendingServiceCount -= 1
        guard pendingServiceCount <= 0 else { return }
        guard let (w, n) = resolveCharacteristics() else {
            resumeReady(.failure(BLEError.characteristicNotFound))
            return
        }
        writeChar = w
        notifyChar = n
        writeType = w.properties.contains(.write) ? .withResponse : .withoutResponse
        if n.properties.contains(.notify) || n.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: n)
        }
        resumeReady(.success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Notifications are best-effort; a failed CCCD write only degrades the
        // status-query path, printing is blind anyway.
        if let error {
            lastError = "通知订阅失败: \(error.localizedDescription)"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Already on `queue`.
        guard characteristic === notifyChar, let data = characteristic.value, !data.isEmpty else { return }
        pushRx(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Already on `queue`.
        if let error {
            // Don't ack: the wait times out and writeChunkWithRetry resends the
            // chunk — a silently dropped chunk would corrupt the page.
            lastError = "写入确认失败: \(error.localizedDescription)"
            return
        }
        guard let sem = writeAckSem else { return }
        writeAckSem = nil
        sem.signal()
    }
}
