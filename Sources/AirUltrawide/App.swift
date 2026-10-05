import AppKit
import Carbon.HIToolbox
import Metal
import QuartzCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let virtualWidth = 5120
    private let virtualHeight = 1440

    private let device = MTLCreateSystemDefaultDevice()!
    private let hid = AirHID()
    private var virtualDisplay: VirtualDisplay?
    private var capture: ScreenCapture!
    private var renderer: Renderer?
    private var window: NSWindow?
    private var metalView: MetalView?
    private var displayLink: CADisplayLink?
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var hotKey: HotKey?
    private var imuConnected = false
    private var configureAttempts: [String: Int] = [:]

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.write("起動")
        buildMenu()
        hotKey = HotKey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey) { [weak self] in
            self?.renderer?.recenter()
        }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        guard let vd = VirtualDisplay(width: virtualWidth, height: virtualHeight) else {
            fail("仮想ディスプレイを作成できませんでした。")
            return
        }
        virtualDisplay = vd
        capture = ScreenCapture(device: device)

        hid.onConnectionChange = { [weak self] connected in
            DispatchQueue.main.async { self?.imuConnected = connected }
        }
        hid.start()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // 仮想ディスプレイが NSScreen に現れるまで少し待ってから組み立てる
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            setUpGlasses()
            Task { @MainActor in
                do {
                    try await capture.start(displayID: vd.displayID, width: virtualWidth, height: virtualHeight)
                    Log.write("キャプチャ開始 preflight=\(CGPreflightScreenCaptureAccess())")
                } catch {
                    fail("画面の取り込みを開始できませんでした。\nシステム設定 > プライバシーとセキュリティ > 画面収録 で AirUltrawide を許可し、再起動してください。\n(\(error.localizedDescription))")
                }
            }
        }

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateStatus() }
    }

    func applicationWillTerminate(_ note: Notification) {
        displayLink?.invalidate()
        hid.stop()
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [capture] in await capture?.stop(); sem.signal() }
        _ = sem.wait(timeout: .now() + 1)
        virtualDisplay = nil // 仮想ディスプレイを破棄
    }

    // MARK: - グラス画面

    @objc private func screensChanged() {
        // グラスの抜き差しなどで画面構成が変わったら組み直す（setUpGlasses は何度呼んでもよい）
        setUpGlasses()
    }

    private func setUpGlasses() {
        guard let vd = virtualDisplay else { return }
        guard let glassesID = GlassesDisplay.findDisplayID(excluding: vd.displayID) else {
            tearDownWindow()
            configureAttempts = [:]
            return
        }
        // 構成変更のたびに通知(screensChanged)で再度呼ばれる。
        // 失敗し続けてループしないよう、各手順は 1 接続につき 2 回まで
        if GlassesDisplay.needsConfiguration(glassesID) {
            guard attempt("mode") else { return }
            tearDownWindow()
            GlassesDisplay.configure(glassesID)
            return
        }
        let origins = GlassesDisplay.desiredOrigins(glassesID: glassesID, virtualID: vd.displayID,
                                                    virtualIsMain: Settings.virtualIsMain)
        if !GlassesDisplay.isArranged(origins), attempt("arrange") {
            GlassesDisplay.arrange(origins)
            return
        }

        guard let screen = NSScreen.screens.first(where: { $0.displayID == glassesID }) else { return }
        if let window, window.screen == screen {
            if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            return
        }
        tearDownWindow()

        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.ignoresMouseEvents = true
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false

        let view = MetalView(frame: NSRect(origin: .zero, size: screen.frame.size))
        w.contentView = view
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        view.updateDrawableSize(scale: screen.backingScaleFactor)

        do {
            renderer = try Renderer(device: device, layer: view.metalLayer, capture: capture, poses: hid.poses,
                                    virtualWidth: virtualWidth, virtualHeight: virtualHeight)
        } catch {
            fail("描画の初期化に失敗しました: \(error)")
            return
        }
        let link = view.displayLink(target: self, selector: #selector(displayTick(_:)))
        link.add(to: .main, forMode: .common)

        window = w
        metalView = view
        displayLink = link
        Log.write("グラス画面にウィンドウを作成 \(screen.frame) drawable=\(view.metalLayer.drawableSize)")
    }

    private func attempt(_ step: String) -> Bool {
        let n = configureAttempts[step, default: 0]
        configureAttempts[step] = n + 1
        return n < 2
    }

    private func tearDownWindow() {
        displayLink?.invalidate()
        displayLink = nil
        renderer = nil
        window?.orderOut(nil)
        window = nil
        metalView = nil
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        renderer?.tick(targetTime: link.targetTimestamp)
    }

    // MARK: - メニュー

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "AirUltrawide")

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "起動中…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let recenter = NSMenuItem(title: "正面に戻す（⌃⌥R）", action: #selector(recenter), keyEquivalent: "")
        menu.addItem(recenter)
        menu.addItem(NSMenuItem(title: "ジャイロを再キャリブレーション（静止させて実行）", action: #selector(recalibrate), keyEquivalent: ""))
        menu.addItem(.separator())

        let zoomMenu = NSMenu()
        for (title, value) in [("100%（ドット等倍・最高画質）", 1.0), ("90%", 0.9), ("80%", 0.8), ("67%", 0.67)] as [(String, Float)] {
            let item = NSMenuItem(title: title, action: #selector(setZoom(_:)), keyEquivalent: "")
            item.representedObject = value
            item.state = abs(Settings.zoom - value) < 0.001 ? .on : .off
            zoomMenu.addItem(item)
        }
        let zoomItem = NSMenuItem(title: "表示倍率", action: nil, keyEquivalent: "")
        zoomItem.submenu = zoomMenu
        menu.addItem(zoomItem)

        let smoothMenu = NSMenu()
        for option in Settings.Smoothing.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(setSmoothing(_:)), keyEquivalent: "")
            item.tag = option.rawValue
            item.state = option == Settings.smoothing ? .on : .off
            item.target = self
            smoothMenu.addItem(item)
        }
        let smoothItem = NSMenuItem(title: "追従の滑らかさ（手ぶれの抑え方）", action: nil, keyEquivalent: "")
        smoothItem.submenu = smoothMenu
        menu.addItem(smoothItem)

        let snap = NSMenuItem(title: "止まっているときはピクセル固定（くっきり表示）", action: #selector(toggleSnap(_:)), keyEquivalent: "")
        snap.state = Settings.snapWhenStill ? .on : .off
        menu.addItem(snap)

        let roll = NSMenuItem(title: "首の傾き（ロール）にも追従", action: #selector(toggleRoll(_:)), keyEquivalent: "")
        roll.state = Settings.trackRoll ? .on : .off
        menu.addItem(roll)

        let main = NSMenuItem(title: "ウルトラワイドをメインディスプレイにする", action: #selector(toggleMain(_:)), keyEquivalent: "")
        main.state = Settings.virtualIsMain ? .on : .off
        menu.addItem(main)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        for item in zoomMenu.items { item.target = self }
        statusItem.menu = menu
    }

    private func updateStatus() {
        let pose = hid.poses.read()
        let imu = !imuConnected ? "グラス未接続" : (pose.calibrated ? "トラッキング中" : "キャリブレーション中（静止してください）")
        let glasses = window == nil ? " / グラス画面なし" : ""
        statusLine.title = imu + glasses
    }

    @objc private func recenter() { renderer?.recenter() }
    @objc private func recalibrate() { hid.recalibrate(); renderer?.recenter() }

    @objc private func setZoom(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Float else { return }
        Settings.zoom = v
        sender.menu?.items.forEach { $0.state = $0 == sender ? .on : .off }
    }

    @objc private func setSmoothing(_ sender: NSMenuItem) {
        Settings.smoothing = Settings.Smoothing(rawValue: sender.tag) ?? .weak
        sender.menu?.items.forEach { $0.state = $0 == sender ? .on : .off }
    }

    @objc private func toggleSnap(_ sender: NSMenuItem) {
        Settings.snapWhenStill.toggle()
        sender.state = Settings.snapWhenStill ? .on : .off
    }

    @objc private func toggleRoll(_ sender: NSMenuItem) {
        Settings.trackRoll.toggle()
        sender.state = Settings.trackRoll ? .on : .off
    }

    @objc private func toggleMain(_ sender: NSMenuItem) {
        Settings.virtualIsMain.toggle()
        sender.state = Settings.virtualIsMain ? .on : .off
        configureAttempts["arrange"] = nil
        setUpGlasses()
    }

    private func fail(_ message: String) {
        Log.write("エラー: \(message)")
        let alert = NSAlert()
        alert.messageText = "AirUltrawide"
        alert.informativeText = message
        alert.runModal()
    }
}

/// CAMetalLayer を持つビュー。ピクセル等倍になるよう drawableSize を合わせる
final class MetalView: NSView {
    let metalLayer = CAMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override func layout() {
        super.layout()
        updateDrawableSize(scale: window?.backingScaleFactor ?? 1)
    }

    func updateDrawableSize(scale: CGFloat) {
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}
