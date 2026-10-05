import AppKit
import simd

if CommandLine.arguments.contains("--imu-log") {
    IMULogger.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

/// Step 1 用：IMU の姿勢を 10Hz でターミナルに出す。
/// 回転は「最初にキャリブレーションが終わった向き」からの回転ベクトル（度）で表示する。
enum IMULogger {
    static func run() {
        let hid = AirHID()
        hid.onConnectionChange = { print($0 ? "接続: IMU ストリーム開始" : "切断") }
        hid.start()
        print("グラスを机に置いて静止させてください（約2秒でキャリブレーション）… Ctrl+C で終了")

        var reference: simd_quatf?
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            let p = hid.poses.read()
            guard p.calibrated else { return }
            if reference == nil {
                let up = p.orientation.inverse.act(SIMD3<Float>(0, 1, 0))
                print(String(format: "重力から見た上方向（グラス座標）: x:%+.2f y:%+.2f z:%+.2f", up.x, up.y, up.z))
            }
            let ref = reference ?? p.orientation
            reference = ref
            let rel = ref.inverse * p.orientation
            let v = rel.axis * (rel.angle * 180 / .pi)
            let w = p.angularVelocity * (180 / .pi)
            let age = (CACurrentMediaTimeCompat() - p.hostTime) * 1000
            print(String(format: "rot x:%+7.2f y:%+7.2f z:%+7.2f °  |  ω x:%+7.1f y:%+7.1f z:%+7.1f °/s  age:%4.1fms",
                         v.x, v.y, v.z, w.x, w.y, w.z, age))
        }
        RunLoop.main.add(timer, forMode: .common)
        signal(SIGINT) { _ in exit(0) }
        RunLoop.main.run()
    }
}
