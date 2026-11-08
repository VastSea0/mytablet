import CoreGraphics
import CPrivate
import Foundation

/// Logical desktop sizes offered on the tablet. `Native` is exact 1:1 with the 1920x1200 panel.
struct DisplayLayout: Equatable {
    let name: String; let width: UInt32; let height: UInt32; let hiDPI: Bool
    var pixelWidth: Int { Int(width) * (hiDPI ? 2 : 1) }
    var pixelHeight: Int { Int(height) * (hiDPI ? 2 : 1) }
    static let all = [
        DisplayLayout(name: "Keskin (960×600, piksel birebir)", width: 960, height: 600, hiDPI: true),
        DisplayLayout(name: "Dengeli (1152×720)", width: 1152, height: 720, hiDPI: true),
        DisplayLayout(name: "Daha Fazla Alan (1280×800)", width: 1280, height: 800, hiDPI: true),
    ]
}

final class VirtualDisplay {
    private let display: CGVirtualDisplay
    var id: CGDirectDisplayID { display.displayID }
    var bounds: CGRect { CGDisplayBounds(id) }

    init(layout: DisplayLayout) {
        let d = CGVirtualDisplayDescriptor()
        d.setDispatchQueue(DispatchQueue.main)
        d.name = "MyTablet"
        d.maxPixelsWide = 2560; d.maxPixelsHigh = 1600
        d.sizeInMillimeters = CGSize(width: 226, height: 141) // Tab A8 10.5" active area
        d.vendorID = 0x4D54; d.productID = 0x0A08; d.serialNum = 1
        d.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        d.redPrimary = CGPoint(x: 0.64, y: 0.33)
        d.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        d.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        display = CGVirtualDisplay(descriptor: d)
        apply(layout)
    }

    func apply(_ layout: DisplayLayout) {
        let s = CGVirtualDisplaySettings()
        s.hiDPI = layout.hiDPI ? 1 : 0
        s.modes = [CGVirtualDisplayMode(width: layout.width, height: layout.height, refreshRate: 60)]
        if !display.apply(s) { Log.write("applySettings failed") }
    }
}
