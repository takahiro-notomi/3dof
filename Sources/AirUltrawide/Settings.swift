import Foundation

/// 設定。描画ループから毎フレーム読むため値はメモリに持ち、変更時だけ UserDefaults に保存する。
enum Settings {
    private static let d = UserDefaults.standard

    private static func load<T>(_ key: String, _ fallback: T) -> T { d.object(forKey: key) as? T ?? fallback }

    /// 仮想画面の 1 ピクセルをグラスの何ピクセルで描くか（1.0 = ドット等倍）。小さいほど広く見える
    static var zoom: Float = load("zoom", 0.8) { didSet { d.set(zoom, forKey: "zoom") } }

    /// 首の傾き（ロール）に画面を追従させる
    static var trackRoll: Bool = load("trackRoll", true) { didSet { d.set(trackRoll, forKey: "trackRoll") } }

    /// 追従の滑らかさ（速度適応の強さ）
    enum Smoothing: Int, CaseIterable {
        case off, weak, medium, strong

        var title: String {
            switch self {
            case .off: "オフ（頭の動きをそのまま反映）"
            case .weak: "弱（標準）"
            case .medium: "中"
            case .strong: "強"
            }
        }

        /// この速度 [°/s] 以下の動きは無視し、上限以上はそのまま追従する
        var speedRange: (Float, Float) {
            switch self {
            case .off: (0, 0)
            case .weak: (0.3, 2.5)
            case .medium: (0.6, 4.0)
            case .strong: (1.0, 7.0)
            }
        }
    }

    static var smoothing = Smoothing(rawValue: load("smoothing", Smoothing.weak.rawValue)) ?? .weak {
        didSet { d.set(smoothing.rawValue, forKey: "smoothing") }
    }

    /// 画面が止まっているときは整数ピクセル位置に合わせ、補間なしで表示する
    static var snapWhenStill: Bool = load("snapWhenStill", true) { didSet { d.set(snapWhenStill, forKey: "snapWhenStill") } }

    /// 表示遅延を打ち消すための先読み時間 [ms]
    static var predictionMs: Float = load("predictionMs", 10) { didSet { d.set(predictionMs, forKey: "predictionMs") } }

    /// 仮想ウルトラワイドをメインディスプレイ（メニューバーのある画面）にする
    static var virtualIsMain: Bool = load("virtualIsMain", false) { didSet { d.set(virtualIsMain, forKey: "virtualIsMain") } }

    /// Air 2 の水平視野角 [度]（公称 46° 対角 → 水平約 40°）
    static var horizontalFOV: Float = load("horizontalFOV", 40.1) { didSet { d.set(horizontalFOV, forKey: "horizontalFOV") } }
}
