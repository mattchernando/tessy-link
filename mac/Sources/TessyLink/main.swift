import AppKit
import CoreGraphics
import CoreVideo
import CVirtualDisplay

func stderrLog(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

if CommandLine.arguments.contains("--selftest") {
    if let vd = TLVirtualDisplay(width: 1920, height: 1200, hiDPI: false, name: "Tessy Link SelfTest") {
        stderrLog("SELFTEST OK displayID=\(vd.displayID)"); exit(0)
    } else { stderrLog("SELFTEST FAIL"); exit(1) }
}

// Validate the H.264 encoder with synthetic frames (no Screen Recording needed).
if CommandLine.arguments.contains("--h264test") {
    let w = 1280, h = 800
    let enc = H264Encoder(width: w, height: h)
    var codec = "?", total = 0, keys = 0
    let path = "/tmp/tl_test.h264"
    FileManager.default.createFile(atPath: path, contents: nil)
    let fh = FileHandle(forWritingAtPath: path)!
    enc.onConfig = { c, _, _ in codec = c }
    enc.onChunk = { data, isKey, _ in total += 1; if isKey { keys += 1 }; fh.write(data) }
    enc.start()
    let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    for i in 0..<40 {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &pb)
        if let pb = pb {
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, Int32((i * 6) % 250) + 3, CVPixelBufferGetBytesPerRow(pb) * h)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            enc.encode(pb, timestampMicros: Int64(i) * 33333, forceKeyframe: i == 0)
        }
        Thread.sleep(forTimeInterval: 0.03)
    }
    Thread.sleep(forTimeInterval: 0.6)
    try? fh.close()
    stderrLog("H264TEST chunks=\(total) keyframes=\(keys) codec=\(codec) file=\(path)")
    exit(total > 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--capturetest") {
    guard let vd = TLVirtualDisplay(width: 1920, height: 1200, hiDPI: false, name: "Tessy Link CaptureTest") else {
        stderrLog("CAPTURETEST FAIL: no virtual display"); exit(1)
    }
    let cap = Capturer(); cap.mode = .jpeg; var count = 0
    cap.onFrame = { _ in count += 1 }
    cap.start(displayID: vd.displayID, width: 1280, height: 800)
    RunLoop.main.run(until: Date().addingTimeInterval(6))
    stderrLog("CAPTURETEST frames=\(count)")
    exit(count > 0 ? 0 : 3)
}

if let ri = CommandLine.arguments.firstIndex(of: "--relaytest") {
    let args = CommandLine.arguments
    guard args.count > ri + 2 else { stderrLog("usage: --relaytest <wsURL> <code>"); exit(2) }
    let relay = RelayClient(urlString: args[ri + 1], code: args[ri + 2])
    relay.onStatus = { s in stderrLog("STATUS: \(s)") }
    relay.onInput = { ev in stderrLog("INPUT: \(ev)") }
    relay.onViewerJoined = { h in stderrLog("VIEWER h264=\(h)") }
    relay.start()
    let frame = Data([0x4A, 0xff, 0xd8, 0xff, 0xd9])
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in relay.send(frame: frame) }
    RunLoop.main.run(until: Date().addingTimeInterval(8))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
