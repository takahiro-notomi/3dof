import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

/// 非公開 API CGVirtualDisplay で作るウルトラワイドの仮想ディスプレイ。
/// オブジェクトを解放すると仮想ディスプレイも消える。
final class VirtualDisplay {
    let width: Int
    let height: Int
    private let display: CGVirtualDisplay

    var displayID: CGDirectDisplayID { display.displayID }

    init?(width: Int, height: Int, refreshRate: Double = 60, name: String = "XR Ultrawide") {
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.main
        desc.name = name
        desc.maxPixelsWide = UInt32(width)
        desc.maxPixelsHigh = UInt32(height)
        // 49 インチ 32:9 相当の物理サイズ（macOS の UI 倍率計算にだけ使われる）
        desc.sizeInMillimeters = CGSize(width: 1196, height: 336)
        desc.vendorID = 0xEEEE
        desc.productID = 0x5120
        desc.serialNum = 0x0001

        guard let d = CGVirtualDisplay(descriptor: desc) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0 // 1:1 で写すので HiDPI にはしない
        settings.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: refreshRate)]
        guard d.apply(settings) else { return nil }

        self.display = d
        self.width = width
        self.height = height
    }
}
