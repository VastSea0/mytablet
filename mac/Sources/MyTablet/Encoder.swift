import CoreMedia
import Foundation
import VideoToolbox

struct EncodedFrame { let data: Data; let isKey: Bool; let config: Data?; let captureNs: UInt64 }

/// H.264 hardware encoder tuned for a USB link: no reordering, one-in one-out.
final class Encoder {
    private var session: VTCompressionSession?
    private var forceKey = true
    var onFrame: ((EncodedFrame) -> Void)?

    init(width: Int, height: Int, bitrate: Int) throws {
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
                    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw NSError(domain: "VT", code: Int(st)) }
        session = s
        let set = { (k: CFString, v: CFTypeRef) in
            let r = VTSessionSetProperty(s, key: k, value: v)
            if r != noErr { Log.write("VT property \(k) failed: \(r)") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 600 as CFNumber)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func requestKeyFrame() { forceKey = true }

    func encode(_ pb: CVPixelBuffer, captureNs: UInt64) {
        guard let session else { return }
        let pts = CMTime(value: Int64(captureNs), timescale: 1_000_000_000)
        var props: CFDictionary?
        if forceKey { props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary; forceKey = false }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.deliver(sample, captureNs: captureNs)
        }
    }

    private func deliver(_ sample: CMSampleBuffer, captureNs: UInt64) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var isKey = true
        if let a = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let n = a.first?[kCMSampleAttachmentKey_NotSync] as? Bool { isKey = !n }
        var config: Data?
        if isKey, let f = CMSampleBufferGetFormatDescription(sample) { config = Self.parameterSets(f) }
        var total = 0; var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &ptr) == noErr, let ptr else { return }
        var out = Data(capacity: total + 16)
        var off = 0
        let raw = UnsafeRawPointer(ptr)
        while off + 4 <= total {
            let n = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)))
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(raw.advanced(by: off + 4).assumingMemoryBound(to: UInt8.self), count: n)
            off += 4 + n
        }
        onFrame?(EncodedFrame(data: out, isKey: isKey, config: config, captureNs: captureNs))
    }

    private static func parameterSets(_ f: CMFormatDescription) -> Data {
        var out = Data(); var i = 0; var count = 0
        repeat {
            var p: UnsafePointer<UInt8>?; var n = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(f, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr, let p else { break }
            out.append(contentsOf: [0, 0, 0, 1]); out.append(p, count: n); i += 1
        } while i < count
        return out
    }

    deinit { if let session { VTCompressionSessionInvalidate(session) } }
}
