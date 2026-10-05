import simd

/// IMU サンプルから頭の姿勢(クォータニオン)を推定する。IMU スレッド専用。
///
/// - Mahony 型の相補フィルタ(gyro + accel)で pitch/roll を重力に合わせ続ける（= 真の姿勢）
/// - 起動直後の静止区間でジャイロのバイアスを測り、その後も完全に静止している間だけ少しずつ追従する
/// - 速度適応：表示用の姿勢は「角速度 × ゲイン」で積分する。ゲインは角速度に応じて
///   0（手ぶれ程度の微小な動き）〜 1（はっきりした首振り）へ連続的に変わる。
///   微小な動きの間にたまった真の姿勢とのずれは、はっきり動いている間にだけ縮める（動きに紛れて見えない）
struct OrientationFilter {
    enum State { case calibrating, running }

    private(set) var state: State = .calibrating
    /// 表示に使う 世界 ← グラス の回転（速度適応済み）
    private(set) var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    /// 表示用姿勢の角速度（グラス座標, rad/s, 軽く平滑化済み）。描画時の先読みに使う
    private(set) var angularVelocity = SIMD3<Float>(repeating: 0)

    /// 真の姿勢の推定値
    private var raw = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var gyroBias = SIMD3<Float>(repeating: 0)
    private var lastTimestamp: UInt64 = 0
    private var runningTime: Float = 0

    // 起動時キャリブレーション
    private var calibSum = SIMD3<Float>(repeating: 0)
    private var calibCount = 0
    private var calibTime: Float = 0
    private var calibMaxRate: Float = 0
    private static let calibDuration: Float = 2.0

    // 静止中のバイアス追従
    private var stillTime: Float = 0

    // 速度適応のパラメータ（°/s）。lowSpeed 以下はゲイン 0、highSpeed 以上はゲイン 1
    var lowSpeed: Float = 0.3
    var highSpeed: Float = 2.5
    /// 動いている間に真の姿勢へ寄せる速さ [1/s]
    var correctionRate: Float = 4.0
    private var smoothedSpeed: Float = 0

    mutating func update(_ s: IMUSample) {
        defer { lastTimestamp = s.timestampMicros }
        guard lastTimestamp != 0, s.timestampMicros > lastTimestamp else { return }
        let dt = Float(s.timestampMicros - lastTimestamp) * 1e-6
        guard dt < 0.05 else { return } // 取りこぼし直後は 1 サンプル捨てる

        switch state {
        case .calibrating:
            calibrate(s, dt: dt)
        case .running:
            track(s, dt: dt)
        }
    }

    /// 現在の姿勢を初期化する（キャリブレーションからやり直す）
    mutating func reset() {
        self = OrientationFilter()
    }

    private mutating func calibrate(_ s: IMUSample, dt: Float) {
        // 重力方向だけは先に合わせておく
        raw = integrate(raw, gyro: .zero, accel: s.accel, dt: dt, gain: 10)
        calibSum += s.gyro
        calibCount += 1
        calibTime += dt
        calibMaxRate = max(calibMaxRate, simd_length(s.gyro - calibSum / Float(calibCount)))

        if calibMaxRate > 0.1 { // 動いていたらやり直し
            calibSum = .zero; calibCount = 0; calibTime = 0; calibMaxRate = 0
            return
        }
        if calibTime >= Self.calibDuration {
            gyroBias = calibSum / Float(calibCount)
            orientation = raw
            state = .running
        }
    }

    private mutating func track(_ s: IMUSample, dt: Float) {
        let gyro = s.gyro - gyroBias
        let speed = simd_length(gyro)
        runningTime += dt

        // 完全に静止している（机に置いた等）ときだけバイアスをゆっくり追従。
        // かけている間のゆっくりした首の動きをバイアスと誤認しないよう、閾値はごく小さく
        let accelErr = abs(simd_length(s.accel) - 9.81)
        if speed < 0.005 && accelErr < 0.15 {
            stillTime += dt
            if stillTime > 2.0 { gyroBias += (s.gyro - gyroBias) * min(dt * 0.05, 1) }
        } else {
            stillTime = 0
        }

        // 真の姿勢。動いている間は加速度の信頼度を下げる
        let accelGain: Float = accelErr < 1.0 ? 0.3 : 0
        raw = integrate(raw, gyro: gyro, accel: s.accel, dt: dt, gain: accelGain)

        // 速度適応ゲイン（速度は 30Hz 程度で平滑化してから判定）
        smoothedSpeed += (speed - smoothedSpeed) * alpha(cutoff: 30, dt: dt)
        let gain = adaptiveGain(smoothedSpeed * 180 / .pi)

        // 表示用の姿勢をゲイン付きで積分し、動いている間だけ真の姿勢へ寄せる
        let w = gyro * gain
        orientation = integrate(orientation, gyro: w, accel: .zero, dt: dt, gain: 0)
        if gain > 0 {
            orientation = simd_slerp(orientation, raw, min(correctionRate * gain * dt, 1))
        }
        angularVelocity += (w - angularVelocity) * alpha(cutoff: 25, dt: dt)
    }

    /// 0（lowSpeed 以下）→ 1（highSpeed 以上）へなめらかに変わるゲイン
    private func adaptiveGain(_ speedDeg: Float) -> Float {
        guard highSpeed > lowSpeed else { return 1 }
        return simd_smoothstep(lowSpeed, highSpeed, speedDeg)
    }

    private func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    /// Mahony 型の相補フィルタ（地球座標の上方向 = +Y）。
    /// 加速度計が示す「上」と推定姿勢の「上」のずれを角速度に足し戻して積分する。
    private func integrate(_ q: simd_quatf, gyro g: SIMD3<Float>, accel a: SIMD3<Float>,
                           dt: Float, gain: Float) -> simd_quatf {
        var w = g
        let aLen = simd_length(a)
        if gain > 0, aLen > 1e-3 {
            let estimatedUp = q.inverse.act(SIMD3<Float>(0, 1, 0)) // グラス座標での「上」
            w += simd_cross(a / aLen, estimatedUp) * gain
        }
        // q̇ = ½ q ⊗ ω
        let qDot = (q * simd_quatf(ix: w.x, iy: w.y, iz: w.z, r: 0)).vector * 0.5
        return simd_quatf(vector: simd_normalize(q.vector + qDot * dt))
    }
}
