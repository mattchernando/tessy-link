import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Low-latency H.264 encoder (VideoToolbox). Emits Annex B chunks: keyframes are
/// prefixed with SPS/PPS. Also derives the WebCodecs codec string from the SPS.
final class H264Encoder {

    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private var codecString: String?

    /// (annexBData, isKeyframe, timestampMicros)
    var onChunk: ((Data, Bool, Int64) -> Void)?
    /// (codecString, width, height) — fired once the SPS is known.
    var onConfig: ((String, Int, Int) -> Void)?

    init(width: Int, height: Int) {
        self.width = Int32(width)
        self.height = Int32(height)
    }

    func start() {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else {
            NSLog("[TessyLink] h264: VTCompressionSessionCreate failed (\(status))"); return
        }
        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 3_000_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        NSLog("[TessyLink] h264: encoder ready \(width)x\(height)")
    }

    func stop() {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        codecString = nil
    }

    /// The last known codec string (for resending config when a viewer joins).
    var currentCodec: String? { codecString }

    func encode(_ pixelBuffer: CVPixelBuffer, timestampMicros: Int64, forceKeyframe: Bool) {
        guard let session = session else { return }
        let pts = CMTime(value: timestampMicros, timescale: 1_000_000)
        var props: CFDictionary?
        if forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sb = sampleBuffer, CMSampleBufferDataIsReady(sb) else { return }
            self.handleEncoded(sb)
        }
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        let isKey = !notSync

        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let tsMicros = Int64((CMTimeGetSeconds(pts)) * 1_000_000)

        var out = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]

        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            var nalHeaderLen: Int32 = 0
            var sps: UnsafePointer<UInt8>?
            var spsSize = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: &sps, parameterSetSizeOut: &spsSize, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLen) == noErr, let sps = sps {
                out.append(contentsOf: startCode)
                out.append(sps, count: spsSize)
                if codecString == nil, spsSize >= 4 {
                    let s = String(format: "avc1.%02X%02X%02X", sps[1], sps[2], sps[3])
                    codecString = s
                    onConfig?(s, Int(width), Int(height))
                }
            }
            var pps: UnsafePointer<UInt8>?
            var ppsSize = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 1, parameterSetPointerOut: &pps, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pps = pps {
                out.append(contentsOf: startCode)
                out.append(pps, count: ppsSize)
            }
        }

        if let bb = CMSampleBufferGetDataBuffer(sb) {
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr, let dp = dataPointer {
                dp.withMemoryRebound(to: UInt8.self, capacity: totalLength) { bytes in
                    var i = 0
                    while i + 4 <= totalLength {
                        let nalLen = (Int(bytes[i]) << 24) | (Int(bytes[i+1]) << 16) | (Int(bytes[i+2]) << 8) | Int(bytes[i+3])
                        i += 4
                        if nalLen <= 0 || i + nalLen > totalLength { break }
                        out.append(contentsOf: startCode)
                        out.append(UnsafeBufferPointer(start: bytes + i, count: nalLen))
                        i += nalLen
                    }
                }
            }
        }

        if !out.isEmpty { onChunk?(out, isKey, tsMicros) }
    }
}
