// Measurement harness for the P1Label LabelCanvas drag behaviour.
//
// Plain AppKit entry point (the app's own @main is commented out in
// P1LabelApp.swift).  Shows the REAL ContentView in an NSHostingView, injects
// mouse events with NSApp.postEvent, and dumps raw grayscale + PNG frames of
// the window (via the runtime-only CGWindowListCreateImage symbol).
//
// Usage:
//   p1harness --probe <outdir>
//   p1harness --drag  <target.json> <outdir>
//   p1harness --burst <target.json> <outdir>
//
// target.json: {"x": <window-base points>, "y": <window-base points>}

import AppKit
import SwiftUI
import CoreGraphics
import Foundation

// MARK: - Runtime lookup of the removed CGWindowListCreateImage symbol

typealias CGWLCI = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

func legacyWindowImage(_ wid: CGWindowID) -> CGImage? {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
          let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
    let fn = unsafeBitCast(sym, to: CGWLCI.self)
    let optionIncludingWindow: UInt32 = 1 << 3
    let boundsIgnoreFraming: UInt32 = 1 << 0
    return fn(CGRect.null, optionIncludingWindow, UInt32(wid), boundsIgnoreFraming)?.takeRetainedValue()
}

// MARK: - Defaults / seed document

enum HarnessDefaults {
    // Exactly one black text element, near the paper's top-left.
    static let documentJSON = """
    {"widthMM":40,"heightMM":30,"marginTopMM":0,"marginBottomMM":0,"darkThreshold":128,\
    "rasterWidth":384,"leftPadDots":68,"elements":[\
    {"id":"A1B2C3D4-0000-0000-0000-000000000001","kind":"text","x":32,"y":45,\
    "text":"拖拽测试","fontSize":30,"bold":true,"size":96,"width":0}]}
    """

    static func install() {
        let d = UserDefaults.standard
        // Remove every stale P1Label.* key from this raw executable's domain.
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("P1Label.") {
            d.removeObject(forKey: key)
        }
        d.set(Data(documentJSON.utf8), forKey: "P1Label.document")
        d.synchronize()
        let keys = d.dictionaryRepresentation().keys.filter { $0.hasPrefix("P1Label.") }.sorted()
        print("[harness] bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "<nil>")")
        print("[harness] defaults domain=\(UserDefaults.standard) keys=\(keys)")
        if let data = d.data(forKey: "P1Label.document") {
            print("[harness] seeded P1Label.document bytes=\(data.count)")
        } else {
            print("[harness] WARNING: failed to seed P1Label.document")
        }
    }
}

// MARK: - Options

struct HarnessOptions {
    enum Mode { case probe, drag, burst }
    var mode: Mode
    var outdir: String
    var targetPath: String?
}

func parseOptions(_ args: [String]) -> HarnessOptions {
    func usage() -> Never {
        FileHandle.standardError.write(Data("usage: p1harness --probe <outdir> | --drag <target.json> <outdir> | --burst <target.json> <outdir>\n".utf8))
        exit(2)
    }
    guard args.count >= 2 else { usage() }
    switch args[1] {
    case "--probe":
        guard args.count >= 3 else { usage() }
        return HarnessOptions(mode: .probe, outdir: args[2], targetPath: nil)
    case "--drag", "--burst":
        guard args.count >= 4 else { usage() }
        return HarnessOptions(mode: args[1] == "--drag" ? .drag : .burst,
                              outdir: args[3], targetPath: args[2])
    default:
        usage()
    }
}

// MARK: - Window capture

struct BlueBox {
    var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min, count = 0
    var dict: [String: Any]? {
        guard count > 0 else { return nil }
        return ["x0": x0, "y0": y0, "x1": x1, "y1": y1, "count": count]
    }
}

struct CaptureResult {
    var width: Int
    var height: Int
    var blue: BlueBox
    var captureMs: Double
    var windowMs: Double = 0
    var convertMs: Double = 0
    var rawMs: Double = 0
    var pngMs: Double = 0
}

enum HarnessError: Error, CustomStringConvertible {
    case captureUnavailable
    case contextFailed
    case writeFailed(String)
    var description: String {
        switch self {
        case .captureUnavailable: return "CGWindowListCreateImage returned nil"
        case .contextFailed: return "could not create bitmap context"
        case .writeFailed(let s): return "write failed: \(s)"
        }
    }
}

func now() -> Double { ProcessInfo.processInfo.systemUptime }

func writeJSON(_ object: Any, to path: String) {
    do {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("[harness] JSON write \(path) failed: \(error)\n".utf8))
    }
}

func writeData(_ data: Data, to url: URL) throws {
    do { try data.write(to: url) }
    catch { throw HarnessError.writeFailed("\(url.path): \(error)") }
}

// MARK: - App delegate

final class HarnessAppDelegate: NSObject, NSApplicationDelegate {
    let options: HarnessOptions
    var window: NSWindow!
    var eventNumber = 0
    var metaWritten = false

    init(options: HarnessOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = ContentView()
        let hosting = NSHostingView(rootView: root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 683),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "P1Label measurement harness"
        window.contentView = hosting
        window.setContentSize(NSSize(width: 980, height: 683))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Give SwiftUI / the canvas a fixed 1.5 s to lay out and draw.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.runMode()
        }
    }

    // MARK: run-loop pumping

    func spin(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            // Nested RunLoop.run does not dequeue NSApplication's event queue;
            // pull events explicitly so posted mouse events reach SwiftUI.
            if let event = NSApp.nextEvent(matching: .any,
                                           until: Date(timeIntervalSinceNow: 0.002),
                                           inMode: .default,
                                           dequeue: true) {
                NSApp.sendEvent(event)
            } else {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            }
        } while Date() < deadline
    }

    // MARK: capture

    func capture(_ name: String, outdir: URL) throws -> CaptureResult {
        let t0 = now()
        let wid = CGWindowID(window.windowNumber)
        guard let cg = legacyWindowImage(wid) else { throw HarnessError.captureUnavailable }
        let tWindow = now()
        let w = cg.width, h = cg.height

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drew = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        guard drew else { throw HarnessError.contextFailed }

        // Grayscale for analysis.  Blue-dominant pixels (the selection box) are
        // forced to white so they cannot be mistaken for a second black copy;
        // PNG keeps the true colour for human inspection.
        var gray = [UInt8](repeating: 255, count: w * h)
        var blue = BlueBox()
        let blueMinX = Int(Double(w) * 0.36)  // paper/canvas only (skip editor controls)
        let blueMaxY = h - 110        // skip the bottom toolbar (blue slider etc.)
        for y in 0..<h {
            let row = y * w * 4
            let grayRow = y * w
            for x in 0..<w {
                let i = row + x * 4
                let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                if b > r + 25 && b > g + 25 {
                    gray[grayRow + x] = 255
                    if x >= blueMinX && y < blueMaxY {
                        blue.count += 1
                        blue.x0 = min(blue.x0, x); blue.x1 = max(blue.x1, x)
                        blue.y0 = min(blue.y0, y); blue.y1 = max(blue.y1, y)
                    }
                } else {
                    gray[grayRow + x] = UInt8((299 * r + 587 * g + 114 * b) / 1000)
                }
            }
        }

        let tConvert = now()
        var data = Data(capacity: 8 + gray.count)
        var w32 = Int32(w).littleEndian
        var h32 = Int32(h).littleEndian
        withUnsafeBytes(of: &w32) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &h32) { data.append(contentsOf: $0) }
        data.append(contentsOf: gray)
        try writeData(data, to: outdir.appendingPathComponent("\(name).raw"))
        let tRaw = now()

        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]) {
            try writeData(png, to: outdir.appendingPathComponent("\(name).png"))
        } else {
            print("[harness] WARNING: PNG encode failed for \(name)")
        }
        let tEnd = now()
        return CaptureResult(width: w, height: h, blue: blue, captureMs: (tEnd - t0) * 1000,
                             windowMs: (tWindow - t0) * 1000,
                             convertMs: (tConvert - tWindow) * 1000,
                             rawMs: (tRaw - tConvert) * 1000,
                             pngMs: (tEnd - tRaw) * 1000)
    }

    func windowMeta(imageWidth: Int, imageHeight: Int) -> [String: Any] {
        let f = window.frame
        let scale = Double(imageHeight) / Double(f.height)
        return [
            "frameWidth": Double(f.width),
            "frameHeight": Double(f.height),
            "frameX": Double(f.origin.x),
            "frameY": Double(f.origin.y),
            "imageWidthPx": imageWidth,
            "imageHeightPx": imageHeight,
            "scale": scale,
            "windowNumber": window.windowNumber,
            "contentWidth": Double(window.contentView?.frame.width ?? 0),
            "contentHeight": Double(window.contentView?.frame.height ?? 0),
            "backingScaleFactor": Double(window.backingScaleFactor),
            "isKeyWindow": window.isKeyWindow,
            "isMainWindow": window.isMainWindow,
            "appIsActive": NSApp.isActive,
            "screenScale": Double(window.screen?.backingScaleFactor ?? 0),
        ]
    }

    // MARK: input injection

    @discardableResult
    func postMouse(_ type: NSEvent.EventType, at point: CGPoint, pressure: Float = 1.0) -> Bool {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: pressure
        ) else {
            print("[harness] failed to create \(type.rawValue) event")
            return false
        }
        NSApp.postEvent(event, atStart: false)
        return true
    }

    // MARK: modes

    func runMode() {
        // Re-assert activation right before measuring.  Activation is
        // asynchronous and occasionally loses the race with the launching
        // terminal, so retry until the window is key (max ~2 s).
        let activationDeadline = Date().addingTimeInterval(2.0)
        repeat {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            spin(0.05)
        } while Date() < activationDeadline && !(NSApp.isActive && window.isKeyWindow)
        print("[harness] activation: active=\(NSApp.isActive) key=\(window.isKeyWindow)")

        let outdir = URL(fileURLWithPath: options.outdir)
        do {
            try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("[harness] cannot create outdir: \(error)\n".utf8))
            exit(3)
        }

        switch options.mode {
        case .probe: runProbe(outdir: outdir)
        case .drag: runDrag(outdir: outdir, burst: false)
        case .burst: runDrag(outdir: outdir, burst: true)
        }
    }

    func runProbe(outdir: URL) {
        do {
            let cap = try capture("probe", outdir: outdir)
            let meta = windowMeta(imageWidth: cap.width, imageHeight: cap.height)
            writeJSON(meta, to: "/tmp/p1harness/window_meta.json")
            writeJSON(meta, to: outdir.appendingPathComponent("window_meta.json").path)
            print(String(format: "[harness] probe capture %dx%dpx in %.1f ms (window %.1f, convert %.1f, raw %.1f, png %.1f)",
                         cap.width, cap.height, cap.captureMs, cap.windowMs,
                         cap.convertMs, cap.rawMs, cap.pngMs))
            print("[harness] window frame \(window.frame) content \(window.contentView?.frame ?? .zero)")
            print("[harness] isKey=\(window.isKeyWindow) isMain=\(window.isMainWindow) active=\(NSApp.isActive)")
            print("[harness] meta written to /tmp/p1harness/window_meta.json")
            fflush(stdout)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("[harness] probe failed: \(error)\n".utf8))
            exit(4)
        }
    }

    func readTarget() -> CGPoint? {
        guard let path = options.targetPath,
              let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = obj["x"] as? NSNumber,
              let y = obj["y"] as? NSNumber else { return nil }
        return CGPoint(x: x.doubleValue, y: y.doubleValue)
    }

    func runDrag(outdir: URL, burst: Bool) {
        guard let target = readTarget() else {
            FileHandle.standardError.write(Data("[harness] cannot read target JSON \(options.targetPath ?? "<nil>")\n".utf8))
            exit(5)
        }
        let env = ProcessInfo.processInfo.environment
        let steps = Int(env["HARNESS_STEPS"] ?? "") ?? 20
        let stepDX = Double(env["HARNESS_STEP_X"] ?? "") ?? 12.0
        let stepDY = Double(env["HARNESS_STEP_Y"] ?? "") ?? 6.0
        let label = burst ? "burst" : "drag"

        do {
            // Reference frame before any input.
            let before = try capture("frame_before", outdir: outdir)
            let meta = windowMeta(imageWidth: before.width, imageHeight: before.height)
            writeJSON(meta, to: "/tmp/p1harness/window_meta.json")
            writeJSON(meta, to: outdir.appendingPathComponent("window_meta.json").path)

            let t0 = now()
            var stepsLog: [[String: Any]] = []

            postMouse(.leftMouseDown, at: target)
            spin(0.15)
            // Reference frame with the selection box at dx/dy = 0 (grab state).
            let grabCap = try capture("frame_grab", outdir: outdir)
            var grabMeta: [String: Any] = [
                "frame": "frame_grab",
                "capStartT": now() - t0,
                "captureMs": grabCap.captureMs,
                "imageWidthPx": grabCap.width,
                "imageHeightPx": grabCap.height,
            ]
            if let b = grabCap.blue.dict { grabMeta["blueBBoxPx"] = b }

            var cursor = target
            var tails: [[String: Any]] = []
            var burstEvents: [[String: Any]] = []

            if burst {
                // Rapid event injection: one drag event every ~5 ms, no capture
                // in between (a CGWindowListCreateImage snapshot costs ~45 ms).
                // Snapshot every 5th event, then a tail of frames to see the
                // element catch up / settle.
                for i in 1...steps {
                    cursor = CGPoint(x: target.x + stepDX * Double(i),
                                     y: target.y + stepDY * Double(i))
                    let tPost = now()
                    postMouse(.leftMouseDragged, at: cursor)
                    spin(0.005)
                    burstEvents.append(["i": i, "cursorX": Double(cursor.x),
                                        "cursorY": Double(cursor.y), "postT": tPost - t0])
                    if i % 5 == 0 {
                        let name = String(format: "burst_%02d", i)
                        let tCapStart = now()
                        let cap = try capture(name, outdir: outdir)
                        let tCapEnd = now()
                        var step: [String: Any] = [
                            "i": i, "frame": name,
                            "cursorX": Double(cursor.x), "cursorY": Double(cursor.y),
                            "postT": tPost - t0,
                            "capStartT": tCapStart - t0, "capEndT": tCapEnd - t0,
                            "captureMs": cap.captureMs, "windowMs": cap.windowMs,
                            "convertMs": cap.convertMs, "rawMs": cap.rawMs,
                            "pngMs": cap.pngMs,
                            "imageWidthPx": cap.width, "imageHeightPx": cap.height,
                        ]
                        if let b = cap.blue.dict { step["blueBBoxPx"] = b }
                        stepsLog.append(step)
                    }
                }
                // Capture right after the final event (same cursor) then tails.
                for j in 0..<12 {
                    if j > 0 { spin(0.02) }
                    let name = j == 0 ? "burst_after" : String(format: "tail_%02d", j - 1)
                    let ts = now()
                    let cap = try capture(name, outdir: outdir)
                    var tail: [String: Any] = [
                        "i": steps, "frame": name,
                        "cursorX": Double(cursor.x), "cursorY": Double(cursor.y),
                        "postT": ts - t0 - cap.captureMs / 1000.0,
                        "capStartT": ts - t0,
                        "captureMs": cap.captureMs,
                        "windowMs": cap.windowMs, "convertMs": cap.convertMs,
                        "rawMs": cap.rawMs, "pngMs": cap.pngMs,
                    ]
                    if let b = cap.blue.dict { tail["blueBBoxPx"] = b }
                    stepsLog.append(tail)
                    tails.append(tail)
                }
            } else {
                for i in 1...steps {
                    cursor = CGPoint(x: target.x + stepDX * Double(i),
                                     y: target.y + stepDY * Double(i))
                    let tPost = now()
                    postMouse(.leftMouseDragged, at: cursor)
                    spin(0.03)
                    let tCapStart = now()
                    let cap = try capture(String(format: "frame_%02d", i), outdir: outdir)
                    let tCapEnd = now()
                    var step: [String: Any] = [
                        "i": i,
                        "frame": String(format: "frame_%02d", i),
                        "cursorX": Double(cursor.x),
                        "cursorY": Double(cursor.y),
                        "postT": tPost - t0,
                        "capStartT": tCapStart - t0,
                        "capEndT": tCapEnd - t0,
                        "captureMs": cap.captureMs,
                        "windowMs": cap.windowMs,
                        "convertMs": cap.convertMs,
                        "rawMs": cap.rawMs,
                        "pngMs": cap.pngMs,
                        "imageWidthPx": cap.width,
                        "imageHeightPx": cap.height,
                    ]
                    if let b = cap.blue.dict { step["blueBBoxPx"] = b }
                    stepsLog.append(step)
                }
            }

            let tUp = now()
            postMouse(.leftMouseUp, at: cursor, pressure: 0)
            spin(0.4)
            let tEnd = now()
            let endCap = try capture("frame_end", outdir: outdir)
            var endMeta: [String: Any] = [
                "frame": "frame_end",
                "capStartT": tEnd - t0,
                "captureMs": endCap.captureMs,
                "imageWidthPx": endCap.width,
                "imageHeightPx": endCap.height,
            ]
            if let b = endCap.blue.dict { endMeta["blueBBoxPx"] = b }

            let log: [String: Any] = [
                "mode": label,
                "target": ["x": Double(target.x), "y": Double(target.y)],
                "steps": stepsLog,
                "grabFrame": grabMeta,
                "tailFrames": tails,
                "burstEvents": burstEvents,
                "mouseUpT": tUp - t0,
                "endFrame": endMeta,
                "elapsed": now() - t0,
                "window": meta,
                "burstSpinSeconds": burst ? 0.005 : 0.03,
            ]
            writeJSON(log, to: outdir.appendingPathComponent("drag_log.json").path)
            print("[harness] \(label) done: \(steps) steps, elapsed \(String(format: "%.2f", now() - t0)) s")
            print("[harness] final cursor \(cursor) ; outdir \(outdir.path)")
            fflush(stdout)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("[harness] \(label) failed: \(error)\n".utf8))
            exit(6)
        }
    }
}

// MARK: - Entry point

@main
struct HarnessMain {
    static func main() {
        let options = parseOptions(CommandLine.arguments)
        HarnessDefaults.install()

        let app = NSApplication.shared
        let delegate = HarnessAppDelegate(options: options)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
