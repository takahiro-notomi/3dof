import Foundation
import IOKit
import IOKit.hid
import os
import simd

/// IMU スレッドと描画スレッドの間で受け渡す最新の姿勢。
final class PoseStore: @unchecked Sendable {
    struct Pose {
        var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var angularVelocity = SIMD3<Float>(repeating: 0)
        /// サンプルを受け取ったホスト時刻（秒, CACurrentMediaTime 系）
        var hostTime: Double = 0
        var calibrated = false
    }

    private var lock = os_unfair_lock()
    private var pose = Pose()

    func write(_ p: Pose) {
        os_unfair_lock_lock(&lock); pose = p; os_unfair_lock_unlock(&lock)
    }

    func read() -> Pose {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return pose
    }
}

/// XREAL Air 2 の IMU インターフェースを開き、専用スレッドで姿勢を更新し続ける。
final class AirHID: @unchecked Sendable {
    let poses = PoseStore()
    /// 接続状態が変わったときに呼ばれる（IMU スレッド上）
    var onConnectionChange: ((Bool) -> Void)?

    private var manager: IOHIDManager!
    private var imuDevice: IOHIDDevice?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var filter = OrientationFilter()
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    private var pendingReset = false

    func start() {
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "AirHID.IMU"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [self] in
            if let dev = imuDevice { send(dev, IMUProtocol.command(IMUProtocol.cmdIMUStream, data: [0x00])) }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            CFRunLoopStop(rl)
        }
        CFRunLoopWakeUp(rl)
    }

    /// ジャイロのキャリブレーションからやり直す（静止させて呼ぶ）
    func recalibrate() { pendingReset = true }

    /// IMU ストリームの開始コマンドを送り直す（スリープ復帰後、グラスが送信を止めていることがある）
    func resumeStream() {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [self] in
            guard let dev = imuDevice else { return }
            send(dev, IMUProtocol.command(IMUProtocol.cmdIMUStream, data: [0x01]))
        }
        CFRunLoopWakeUp(rl)
    }

    // MARK: - IMU スレッド

    private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = IMUProtocol.productIDs.map {
            [kIOHIDVendorIDKey: IMUProtocol.vendorID, kIOHIDProductIDKey: $0] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<AirHID>.fromOpaque(ctx!).takeUnretainedValue().deviceMatched(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<AirHID>.fromOpaque(ctx!).takeUnretainedValue().deviceRemoved(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            Log.write("IOHIDManagerOpen 失敗 \(String(r, radix: 16))")
        }
        CFRunLoopRun()
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        guard imuDevice == nil, Self.interfaceNumber(of: device) == IMUProtocol.imuInterface else { return }
        imuDevice = device
        filter.reset()

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 512, { ctx, _, _, _, _, report, length in
            Unmanaged<AirHID>.fromOpaque(ctx!).takeUnretainedValue().handle(report: report, length: length)
        }, ctx)

        send(device, IMUProtocol.command(IMUProtocol.cmdIMUStream, data: [0x01]))
        onConnectionChange?(true)
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard device == imuDevice else { return }
        imuDevice = nil
        poses.write(.init())
        onConnectionChange?(false)
    }

    private func handle(report: UnsafePointer<UInt8>, length: Int) {
        guard let sample = IMUSample(report: report, length: length) else { return }
        if pendingReset { pendingReset = false; filter.reset() }
        let (lo, hi) = Settings.smoothing.speedRange
        filter.lowSpeed = lo
        filter.highSpeed = hi
        filter.update(sample)
        poses.write(.init(orientation: filter.orientation,
                          angularVelocity: filter.angularVelocity,
                          hostTime: CACurrentMediaTimeCompat(),
                          calibrated: filter.state == .running))
    }

    private func send(_ device: IOHIDDevice, _ bytes: [UInt8]) {
        let r = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
        if r != kIOReturnSuccess { Log.write("SetReport 失敗 \(String(r, radix: 16))") }
    }

    /// HID デバイスの親をたどって USB インターフェース番号を得る
    private static func interfaceNumber(of device: IOHIDDevice) -> Int? {
        let service = IOHIDDeviceGetService(device)
        let v = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "bInterfaceNumber" as CFString,
                                                kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        return (v as? NSNumber)?.intValue
    }
}

/// QuartzCore を読み込まずに CACurrentMediaTime と同じ時刻系(mach_absolute_time)を得る
@inline(__always) func CACurrentMediaTimeCompat() -> Double {
    Double(mach_absolute_time()) * machTimebaseSeconds
}

let machTimebaseSeconds: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) * 1e-9
}()
