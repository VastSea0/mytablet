import CoreMedia
import Foundation
import ScreenCaptureKit

final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "capture", qos: .userInteractive)
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onIdle: (() -> Void)?

    func start(displayID: CGDirectDisplayID, width: Int, height: Int) async throws {
        var target: SCDisplay?
        for _ in 0..<40 {
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            target = c.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let target else { throw NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "virtual display not visible to ScreenCaptureKit"]) }
        let cfg = SCStreamConfiguration()
        cfg.width = width; cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.showsCursor = false
        cfg.queueDepth = 4
        let s = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async { try? await stream?.stopCapture(); stream = nil }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let st = SCFrameStatus(rawValue: raw) else { return }
        if st == .idle { onIdle?(); return }
        guard st == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // displayTime is the mach-host time this frame was composited.
        let t = info[.displayTime] as? UInt64 ?? mach_absolute_time()
        onFrame?(pb, Clock.nanos(t))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { Log.write("capture stopped: \(error)") }
}

enum Clock {
    private static let tb: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    static func nanos(_ t: UInt64) -> UInt64 { t &* UInt64(tb.numer) / UInt64(tb.denom) }
    static func now() -> UInt64 { nanos(mach_absolute_time()) }
}
