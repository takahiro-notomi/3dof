import Metal
import QuartzCore
import simd

/// 仮想ウルトラワイドの一部をグラスに描く。
///
/// 「ドット等倍」方式：頭の yaw/pitch は仮想画面上の平行移動、roll は回転として扱う。
/// 透視投影をしないので、正面でも端でも 仮想 1px = グラス 1px のまま。
/// - 静止中：表示位置を整数ピクセルに固定し、補間なし(nearest)で写す → 文字がにじまない
/// - 動作中：Catmull-Rom 双三次補間でなめらかに
/// - 姿勢も画面も変わらないフレームは描画そのものを省く
final class Renderer {
    struct Uniforms: Equatable {
        var center: SIMD2<Float>      // グラス中央に来る仮想画面上の座標
        var panelCenter: SIMD2<Float> // グラス画面の中心（ピクセル）
        var axisX: SIMD2<Float>       // グラスで右へ 1px 進んだときの仮想座標の変化
        var axisY: SIMD2<Float>       // グラスで下へ 1px 進んだときの仮想座標の変化
        var virtualSize: SIMD2<Float>
        var mode: UInt32              // 0: nearest, 1: bicubic
        var _pad: UInt32 = 0
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let layer: CAMetalLayer
    private let capture: ScreenCapture
    private let poses: PoseStore
    private let virtualSize: SIMD2<Float>

    private var reference: simd_quatf?
    private var recenterRequested = false
    private var lastDrawn: (Uniforms, UInt64)?

    // 画面が止まっている間の整数ピクセル固定
    private var anchor = SIMD2<Float>(0, 0)
    private var previousCenter = SIMD2<Float>(0, 0)
    private var stillFrames = 0

    init(device: MTLDevice, layer: CAMetalLayer, capture: ScreenCapture, poses: PoseStore,
         virtualWidth: Int, virtualHeight: Int) throws {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.layer = layer
        self.capture = capture
        self.poses = poses
        self.virtualSize = SIMD2(Float(virtualWidth), Float(virtualHeight))

        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        desc.fragmentFunction = library.makeFunction(name: "virtualScreenFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: desc)

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2 // 遅延を最小に
        layer.isOpaque = true
    }

    /// 今の向きを正面にする
    func recenter() { recenterRequested = true }

    /// ディスプレイの垂直同期ごとに呼ぶ。targetTime はそのフレームが表示される予定時刻
    func tick(targetTime: Double) {
        let size = layer.drawableSize
        guard size.width > 0 else { return }
        let panelCenter = SIMD2(Float(size.width), Float(size.height)) * 0.5
        let frame = capture.latestFrame()
        let uniforms = computeUniforms(targetTime: targetTime, panelCenter: panelCenter, panelWidth: Float(size.width))
        let seq = frame?.sequence ?? 0

        if let (u, s) = lastDrawn, u == uniforms, s == seq { return } // 変化なし → 描かない
        draw(uniforms: uniforms, frame: frame)
        lastDrawn = (uniforms, seq)
    }

    private func computeUniforms(targetTime: Double, panelCenter: SIMD2<Float>, panelWidth: Float) -> Uniforms {
        let pose = poses.read()
        let scale = 1 / max(Settings.zoom, 0.1) // 仮想 px / グラス px
        let halfFOV = Settings.horizontalFOV * .pi / 360
        let pxPerRadian = panelWidth * 0.5 / tan(halfFOV) * scale

        var center = virtualSize * 0.5
        var roll: Float = 0
        let speed = simd_length(pose.angularVelocity)

        if pose.calibrated {
            let q = predict(pose, targetTime: targetTime, speed: speed)
            if reference == nil || recenterRequested {
                reference = q
                recenterRequested = false
            }
            let rel = reference!.inverse * q
            let forward = rel.act(SIMD3<Float>(0, 0, -1))
            let yaw = atan2(forward.x, -forward.z)
            let pitch = asin(simd_clamp(forward.y, -1, 1))
            center += SIMD2(yaw, -pitch) * pxPerRadian

            if Settings.trackRoll {
                let right = rel.act(SIMD3<Float>(1, 0, 0))
                let up = rel.act(SIMD3<Float>(0, 1, 0))
                roll = atan2(-right.y, up.y)
            }
        }

        // 画面がほぼ止まっている(1 フレームの移動 0.05px 未満が 3 フレーム続く)なら整数位置に固定し、
        // 補間なしで写す。0.75px 以上ずれたら位置を更新（ゆっくりした補正でちらつかない）
        let moved = simd_length(center - previousCenter)
        previousCenter = center
        stillFrames = moved < 0.05 ? stillFrames + 1 : 0
        var mode: UInt32 = 1
        if Settings.snapWhenStill && stillFrames >= 3 {
            if simd_reduce_max(simd_abs(center - anchor)) > 0.75 { anchor = center.rounded(.toNearestOrEven) }
            center = anchor
            if abs(roll) < 0.2 * .pi / 180 { roll = 0 }
            if roll == 0 && scale == 1 { mode = 0 }
        } else {
            anchor = center.rounded(.toNearestOrEven)
        }

        let c = cos(roll) * scale, s = sin(roll) * scale
        return Uniforms(center: center, panelCenter: panelCenter,
                        axisX: SIMD2(c, s), axisY: SIMD2(-s, c),
                        virtualSize: virtualSize, mode: mode)
    }

    /// 表示時刻まで角速度で姿勢を先読みする（表示遅延の分だけ。平滑化済みの角速度を使うのでノイズを増幅しない）
    private func predict(_ pose: PoseStore.Pose, targetTime: Double, speed: Float) -> simd_quatf {
        let dt = simd_clamp(Float(targetTime - pose.hostTime) + Settings.predictionMs / 1000, 0, 0.05)
        guard speed > 1e-6, dt > 0 else { return pose.orientation }
        let delta = simd_quatf(angle: speed * dt, axis: pose.angularVelocity / speed)
        return pose.orientation * delta
    }

    private func draw(uniforms: Uniforms, frame: ScreenCapture.Frame?) {
        guard let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            if let frame {
                var u = uniforms
                enc.setRenderPipelineState(pipeline)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setFragmentTexture(frame.texture, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
        }
        // フレーム(IOSurface)を GPU が使い終わるまで保持
        cmd.addCompletedHandler { _ in _ = frame }
        cmd.present(drawable)
        cmd.commit()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 center;
        float2 panelCenter;
        float2 axisX;
        float2 axisY;
        float2 virtualSize;
        uint mode;
        uint pad;
    };

    vertex float4 fullscreenVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    // Catmull-Rom 双三次補間（バイリニア 9 回で 16 タップ相当）
    static float4 sampleCatmullRom(texture2d<float> tex, float2 p) {
        constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_zero);
        float2 t1 = floor(p - 0.5) + 0.5;
        float2 f = p - t1;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2;
        float2 t0 = t1 - 1.0, t3 = t1 + 2.0, t12 = t1 + w2 / w12;

        float4 r = 0.0;
        r += tex.sample(s, float2(t0.x,  t0.y))  * w0.x  * w0.y;
        r += tex.sample(s, float2(t12.x, t0.y))  * w12.x * w0.y;
        r += tex.sample(s, float2(t3.x,  t0.y))  * w3.x  * w0.y;
        r += tex.sample(s, float2(t0.x,  t12.y)) * w0.x  * w12.y;
        r += tex.sample(s, float2(t12.x, t12.y)) * w12.x * w12.y;
        r += tex.sample(s, float2(t3.x,  t12.y)) * w3.x  * w12.y;
        r += tex.sample(s, float2(t0.x,  t3.y))  * w0.x  * w3.y;
        r += tex.sample(s, float2(t12.x, t3.y))  * w12.x * w3.y;
        r += tex.sample(s, float2(t3.x,  t3.y))  * w3.x  * w3.y;
        return saturate(r);
    }

    fragment float4 virtualScreenFragment(float4 pos [[position]],
                                          constant Uniforms& u [[buffer(0)]],
                                          texture2d<float> tex [[texture(0)]]) {
        float2 d = pos.xy - u.panelCenter;
        float2 v = u.center + u.axisX * d.x + u.axisY * d.y;
        if (any(v < 0.0) || any(v >= u.virtualSize)) {
            return float4(0.0, 0.0, 0.0, 1.0); // 黒 = グラスでは透明
        }
        if (u.mode == 0) {
            return tex.read(uint2(v));
        }
        return sampleCatmullRom(tex, v);
    }
    """
}
