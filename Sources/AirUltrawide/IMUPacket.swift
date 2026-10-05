import simd

/// XREAL Air 系の IMU インターフェース(if#3)で使うパケット。
/// 形式は ar-drivers-rs (MIT) の公開情報に基づく。
enum IMUProtocol {
    static let vendorID = 0x3318
    static let productIDs: Set<Int> = [0x0424, 0x0428, 0x0432] // Air / Air 2 / Air 2 Pro
    static let imuInterface = 3
    static let packetSize = 64

    static let cmdIMUStream: UInt8 = 0x19

    /// 0xAA ヘッダのコマンドパケット: head(1) checksum(4) length(2) cmd(1) data...
    /// checksum は offset 5 から length バイトの CRC32。
    static func command(_ cmd: UInt8, data: [UInt8]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: packetSize)
        let length = UInt16(data.count + 3)
        p[0] = 0xAA
        p[5] = UInt8(length & 0xFF)
        p[6] = UInt8(length >> 8)
        p[7] = cmd
        p.replaceSubrange(8..<(8 + data.count), with: data)
        let crc = CRC32.checksum(p[5..<(5 + Int(length))])
        p[1] = UInt8(crc & 0xFF)
        p[2] = UInt8((crc >> 8) & 0xFF)
        p[3] = UInt8((crc >> 16) & 0xFF)
        p[4] = UInt8(crc >> 24)
        return p
    }
}

/// 1 サンプル分の IMU 値。座標はグラス基準（x: 右, y: 上, z: 後ろ）。
struct IMUSample {
    var timestampMicros: UInt64
    var gyro: SIMD3<Float>   // rad/s
    var accel: SIMD3<Float>  // m/s^2
}

extension IMUSample {
    /// 0x01 0x02 で始まる IMU レポートを解析する。それ以外は nil。
    init?(report p: UnsafePointer<UInt8>, length: Int) {
        guard length >= 42, p[0] == 0x01, p[1] == 0x02 else { return nil }

        func u16(_ o: Int) -> UInt16 { UInt16(p[o]) | UInt16(p[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 {
            UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24
        }
        func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
        func i24(_ o: Int) -> Float {
            let v = Int32(p[o]) | Int32(p[o + 1]) << 8 | Int32(p[o + 2]) << 16
            return Float((v << 8) >> 8) // 符号拡張
        }

        timestampMicros = u64(4) / 1000

        let gyroScale = Float(u16(12)) / Float(max(u32(14), 1)) * (.pi / 180)
        let gx = i24(18) * gyroScale, gy = i24(21) * gyroScale, gz = i24(24) * gyroScale
        gyro = SIMD3(-gx, gz, gy)

        let accScale = Float(u16(27)) / Float(max(u32(29), 1)) * 9.81
        let ax = i24(33) * accScale, ay = i24(36) * accScale, az = i24(39) * accScale
        accel = SIMD3(-ax, az, ay)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var r: UInt32 = 0xFFFF_FFFF
        for b in bytes { r = (r >> 8) ^ table[Int((r ^ UInt32(b)) & 0xFF)] }
        return r ^ 0xFFFF_FFFF
    }
}
