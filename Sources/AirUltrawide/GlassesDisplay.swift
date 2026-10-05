import AppKit
import CoreGraphics

/// Air 2 の物理ディスプレイを見つけ、ミラー解除・ネイティブ 1920×1080 化・配置を行う。
/// 設定は .forAppOnly で行うため、アプリ終了時に macOS が元の状態へ戻す。
enum GlassesDisplay {
    static let nativeWidth = 1920
    static let nativeHeight = 1080

    /// Air 2 の EDID 上のベンダー番号
    static let edidVendor: UInt32 = 0x3647

    /// グラスの CGDirectDisplayID。ミラー先になっていると NSScreen には現れないため CG の一覧から探す
    static func findDisplayID(excluding virtualID: CGDirectDisplayID) -> CGDirectDisplayID? {
        let candidates = onlineDisplays().filter { $0 != virtualID && CGDisplayIsBuiltin($0) == 0 }
        if let id = candidates.first(where: { CGDisplayVendorNumber($0) == edidVendor }) { return id }
        return NSScreen.screens.first { s in
            candidates.contains(s.displayID) && s.localizedName.localizedCaseInsensitiveContains("Air")
        }?.displayID
    }

    /// ミラー中・ネイティブ解像度でない場合は構成し直しが必要
    static func needsConfiguration(_ id: CGDirectDisplayID) -> Bool {
        guard CGDisplayIsInMirrorSet(id) == 0, let mode = CGDisplayCopyDisplayMode(id) else { return true }
        return mode.pixelWidth != nativeWidth || mode.pixelHeight != nativeHeight || mode.width != nativeWidth
    }

    /// ミラー解除とネイティブ解像度（最も高いリフレッシュレート）を適用
    @discardableResult
    static func configure(_ glassesID: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }

        // ミラーを解除（グラス側がミラー元/先どちらでも外す）
        CGConfigureDisplayMirrorOfDisplay(config, glassesID, kCGNullDirectDisplay)
        let mirrorMaster = CGDisplayMirrorsDisplay(glassesID)
        if mirrorMaster != kCGNullDirectDisplay {
            CGConfigureDisplayMirrorOfDisplay(config, mirrorMaster, kCGNullDirectDisplay)
        }
        if let mode = nativeMode(glassesID) {
            CGConfigureDisplayWithDisplayMode(config, glassesID, mode, nil)
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }

    /// 画面の配置：[手元の画面][ウルトラワイド] を横に並べ（メイン指定に応じて左右を決める）、
    /// グラス画面は左下の角に斜めに接する位置へ置いてカーソルが入り込まないようにする
    static func desiredOrigins(glassesID: CGDirectDisplayID, virtualID: CGDirectDisplayID,
                               virtualIsMain: Bool) -> [CGDirectDisplayID: CGPoint] {
        let others = onlineDisplays().filter { $0 != glassesID && $0 != virtualID && CGDisplayIsInMirrorSet($0) == 0 }
        let desk = others.first { CGDisplayIsBuiltin($0) != 0 } ?? others.first
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        let vb = CGDisplayBounds(virtualID)
        var minX: CGFloat = 0, bottom = vb.height

        if let desk {
            let db = CGDisplayBounds(desk)
            if virtualIsMain {
                origins[virtualID] = .zero
                origins[desk] = CGPoint(x: -db.width, y: 0)
                minX = -db.width
            } else {
                origins[desk] = .zero
                origins[virtualID] = CGPoint(x: db.width, y: 0)
            }
            bottom = db.height // 左端にある手元の画面の左下角に接する
        } else {
            origins[virtualID] = .zero
        }
        origins[glassesID] = CGPoint(x: minX - CGFloat(nativeWidth), y: bottom)
        return origins
    }

    static func isArranged(_ origins: [CGDirectDisplayID: CGPoint]) -> Bool {
        origins.allSatisfy { CGDisplayBounds($0.key).origin == $0.value }
    }

    @discardableResult
    static func arrange(_ origins: [CGDirectDisplayID: CGPoint]) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for (id, p) in origins {
            CGConfigureDisplayOrigin(config, id, Int32(p.x), Int32(p.y))
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }

    /// 1920×1080 の非 HiDPI モードのうち最もリフレッシュレートが高いもの
    static func nativeMode(_ id: CGDirectDisplayID) -> CGDisplayMode? {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        return modes
            .filter { $0.pixelWidth == nativeWidth && $0.pixelHeight == nativeHeight && $0.width == nativeWidth }
            .max { $0.refreshRate < $1.refreshRate }
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        return Array(ids.prefix(Int(n)))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
