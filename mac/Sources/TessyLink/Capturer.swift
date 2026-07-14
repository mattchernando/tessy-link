import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia
import CoreVideo

enum StreamMode { case jpeg, h264 }

/// Captures a display via ScreenCaptureKit and emits type-prefixed binary frames:
///   'J' + jpeg                         (MJPEG fallback)
///   'K' + 8-byte ts(us, BE) + annexB   (H.264 keyframe)
///   'D' + 8-byte ts(us, BE) + annexB   (H.264 delta)
final class Capturer: NSObject, SCStreamOutput {

    private var stream: SCStream?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let sampleQueue = DispatchQueue(label: "com.tessylink.capture.samples")
    private var lastEmit = Date.distantPast
    private var lastJPEG: Data?          // includes the 'J' prefix
    private var keepalive: DispatchSourceTimer?
    private var h264: H264Encoder?
    private var pendingKeyframe = false
    private var frameCount = 0
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastTsMicros: Int64 = 0

    var mode: StreamMode = .jpeg
    var jpegQuality: CGFloat = 0.5
    var targetFPS: Double = 15
    var onFrame: ((Data) -> Void)?
    var onVideoConfig: ((String, Int, Int) -> Void)?

    func requestKeyframe() { sampleQueue.async { self.pendingKeyframe = true } }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int) {
        let encoder = H264Encoder(width: width, height: height)
        encoder.onConfig = { [weak self] codec, w, h in self?.onVideoConfig?(codec, w, h) }
        encoder.onChunk = { [weak self] annexB, isKey, ts in
            guard let self else { return }
            var out = Data()
            out.append(isKey ? 0x4B : 0x44) // 'K' or 'D'
            var be = ts.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
            out.append(annexB)
            self.onFrame?(out)
        }
        encoder.start()
        self.h264 = encoder

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            if let error = error { NSLog("[TessyLink] capture: shareable error: \(error.localizedDescription)"); return }
            guard let content = content else { NSLog("[TessyLink] capture: no shareable content"); return }
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                NSLog("[TessyLink] capture: display \(displayID) NOT found (\(content.displays.count) shareable)"); return
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, self.targetFPS)))
            config.queueDepth = 6
            config.showsCursor = true
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
                stream.startCapture { err in
                    if let err = err { NSLog("[TessyLink] capture: startCapture error: \(err.localizedDescription)") }
                    else { NSLog("[TessyLink] capture: started \(width)x\(height) for display \(displayID)") }
                }
                self.stream = stream
                self.startKeepalive()
            } catch {
                NSLog("[TessyLink] capture: addStreamOutput error: \(error.localizedDescription)")
            }
        }
    }

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard Date().timeIntervalSince(self.lastEmit) > 0.9 else { return }
            if self.mode == .h264, let pb = self.lastPixelBuffer, let enc = self.h264 {
                self.lastTsMicros += 100_000
                self.lastEmit = Date()
                enc.encode(pb, timestampMicros: self.lastTsMicros, forceKeyframe: true)
            } else if self.mode == .jpeg, let jpeg = self.lastJPEG {
                self.onFrame?(jpeg)
            }
        }
        timer.resume()
        keepalive = timer
    }

    func stop() {
        keepalive?.cancel(); keepalive = nil
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil
        h264?.stop(); h264 = nil
        lastJPEG = nil
        lastPixelBuffer = nil
        frameCount = 0
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = Date()
        if now.timeIntervalSince(lastEmit) < (1.0 / targetFPS) { return }
        lastEmit = now
        frameCount += 1
        lastPixelBuffer = pixelBuffer

        if mode == .h264, let h264 = h264 {
            let ts = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000)
            let force = pendingKeyframe
            pendingKeyframe = false
            lastTsMicros = ts
            h264.encode(pixelBuffer, timestampMicros: ts, forceKeyframe: force)
            return
        }

        // JPEG path
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): jpegQuality
        ]
        guard let jpeg = ciContext.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: options) else { return }
        var out = Data([0x4A]) // 'J'
        out.append(jpeg)
        lastJPEG = out
        if frameCount == 1 { NSLog("[TessyLink] capture: first frame (\(jpeg.count) bytes jpeg)") }
        onFrame?(out)
    }
}
