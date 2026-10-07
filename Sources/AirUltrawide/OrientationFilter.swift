import Foundation
import simd

/// IMU サンプルから頭の姿勢(クォータニオン)を推定する。IMU スレッド専用。
///
/// - Mahony 型の相補フィルタ(gyro + accel)で pitch/roll を重力に合わせ続ける（= 真の姿勢）
/// - 起動直後の静止区間でジャイロのバイアスを測る。その後も「値が揺れずに一定」の区間を静止とみなして
///   ゆっくり追従する（グラスの発熱でバイアスが動いても追い直せるよう、判定に値の大きさは使わない）
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
    private var calibSqSum: Float = 0
    private static let calibDuration: Float = 2.0

    // 静止中のバイアス追従。生のジャイロ値の短時間平均と、その周りの揺れ（標準偏差）で静止を判定する
    private var stillTime: Float = 0
    private var gyroMean = SIMD3<Float>(repeating: 0)
    private var gyroVariance: Float = 0
    /// 起動時の静止区間で測ったジャイロのノイズ [rad/s]
    private var noiseStd: Float = 0.002
    private var loggedBias = SIMD3<Float>(repeating: 0)
    /// 揺れがこれ以下なら静止 [rad/s]（ノイズの 3 倍か 0.4°/s の大きい方）
    private var stillThreshold: Float { max(noiseStd * 3, 0.007) }
    /// バイアスとの差がこれ以上なら、一定でも「ゆっくり回している」とみなして追従しない [rad/s]（約 2°/s）
    private static let maxBiasOffset: Float = 0.035
    /// バイアス追従の時定数 [s]
    private static let biasTimeConstant: Float = 8
    /// バイアスを動かす速さの上限 [rad/s²]（ゆっくりした首振りを誤って取り込んでも影響を小さく）
    private static let maxBiasRate: Float = 0.002

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
        calibSqSum += simd_length_squared(s.gyro)
        calibCount += 1
        calibTime += dt
        calibMaxRate = max(calibMaxRate, simd_length(s.gyro - calibSum / Float(calibCount)))

        if calibMaxRate > 0.1 { // 動いていたらやり直し
            calibSum = .zero; calibSqSum = 0; calibCount = 0; calibTime = 0; calibMaxRate = 0
            return
        }
        if calibTime >= Self.calibDuration {
            gyroBias = calibSum / Float(calibCount)
            noiseStd = sqrt(max(calibSqSum / Float(calibCount) - simd_length_squared(gyroBias), 0))
            gyroMean = gyroBias
            loggedBias = gyroBias
            Log.write(String(format: "ジャイロ較正 バイアス %@ °/s ノイズ %.3f °/s",
                             Self.degrees(gyroBias), noiseStd * 180 / .pi))
            orientation = raw
            state = .running
        }
    }

    private mutating func track(_ s: IMUSample, dt: Float) {
        let gyro = s.gyro - gyroBias
        let speed = simd_length(gyro)
        runningTime += dt

        let accelErr = abs(simd_length(s.accel) - 9.81)
        trackBias(s, dt: dt, accelErr: accelErr)

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

    /// 生のジャイロ値が一定（揺れがノイズ程度）の間は静止とみなし、その平均へバイアスをゆっくり寄せる。
    /// 値の大きさではなく揺れで判定するので、発熱でバイアスがずれていても静止を見つけられる
    private mutating func trackBias(_ s: IMUSample, dt: Float, accelErr: Float) {
        let a = alpha(cutoff: 0.5, dt: dt)
        gyroMean += (s.gyro - gyroMean) * a
        gyroVariance += (simd_length_squared(s.gyro - gyroMean) - gyroVariance) * a

        let steady = sqrt(gyroVariance) < stillThreshold
            && simd_length(gyroMean - gyroBias) < Self.maxBiasOffset
            && accelErr < 0.5
        guard steady else { stillTime = 0; return }
        stillTime += dt
        guard stillTime > 1.0 else { return }

        var step = (gyroMean - gyroBias) * min(dt / Self.biasTimeConstant, 1)
        let maxStep = Self.maxBiasRate * dt
        if simd_length(step) > maxStep { step *= maxStep / simd_length(step) }
        gyroBias += step

        if simd_length(gyroBias - loggedBias) > 0.1 * .pi / 180 {
            loggedBias = gyroBias
            Log.write("ジャイロのバイアス追従 \(Self.degrees(gyroBias)) °/s")
        }
    }

    private static func degrees(_ v: SIMD3<Float>) -> String {
        let d = v * 180 / .pi
        return String(format: "(%.2f, %.2f, %.2f)", d.x, d.y, d.z)
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
