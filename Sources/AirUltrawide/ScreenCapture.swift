import CoreMedia
import CoreVideo
import Metal
import os
import ScreenCaptureKit

/// 仮想ディスプレイを ScreenCaptureKit で取り込み、IOSurface をコピーせずに Metal テクスチャとして渡す。
/// 画面に変化があったときだけフレームが届くので、静止中はほぼ負荷がない。
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame {
        let texture: MTLTexture
        let pixelBuffer: CVPixelBuffer // テクスチャ使用中に IOSurface が再利用されないよう保持
        let cvTexture: CVMetalTexture
        let sequence: UInt64
    }

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "ScreenCapture", qos: .userInteractive)
    private var lock = os_unfair_lock()
    private var latest: Frame?
    private var sequence: UInt64 = 0

    /// 新しいフレームが届いたとき（キャプチャキュー上）
    var onFrame: (() -> Void)?

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    func latestFrame() -> Frame? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return latest
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int = 60) async throws {
        // 仮想ディスプレイが ScreenCaptureKit から見えるまで少し待つことがある
        var display: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            display = content.displays.first { $0.displayID == displayID }
            if display != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let display else { throw CaptureError.displayNotFound }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 4
        config.showsCursor = true
        config.scalesToFit = false
        config.captureResolution = .best

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let pb = sb.imageBuffer, isComplete(sb), let cache = textureCache else { return }

        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return }

        os_unfair_lock_lock(&lock)
        sequence &+= 1
        latest = Frame(texture: tex, pixelBuffer: pb, cvTexture: cvTex, sequence: sequence)
        os_unfair_lock_unlock(&lock)
        if sequence == 1 || sequence % 300 == 0 { Log.write("フレーム受信 #\(sequence) \(w)x\(h)") }
        onFrame?()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("キャプチャ停止: \(error)")
    }

    /// 変化のない「idle」フレームは捨てる
    private func isComplete(_ sb: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    enum CaptureError: Error { case displayNotFound }
}
